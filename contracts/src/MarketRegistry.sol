// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketTypes} from "./types/MarketTypes.sol";

/// @title MarketRegistry
/// @notice Mirrors Polymarket market metadata onto Robinhood Chain and carries
///         the bonded, optimistic resolution relay.
///
/// @dev HALT ON SOURCE PROPOSAL, NOT ON RELAY ARRIVAL
///      The interval between a resolution appearing upstream and the result
///      landing here is the largest information leak in a mirror architecture,
///      so trading freezes at the first sign, not at the answer.
///
/// @dev THE ARBITER IS THE MOST DANGEROUS ROLE IN THE SYSTEM, AND IS FENCED
///      A disputed market must be decided by somebody, and a decentralised
///      escalation layer needs a token, staking and slashing, which is a
///      separate protocol. Until that exists this contract keeps a human
///      arbiter, but confines the role four ways:
///
///      1. The arbiter is a distinct address from the owner. The owner sets
///         parameters and cannot rule; the arbiter rules and cannot touch
///         parameters or funds. Draining the protocol needs two compromises.
///      2. A ruling is announced, not applied. proposeRuling records it and
///         executeRuling applies it only after rulingDelay, so every decision
///         is publicly visible before it takes effect and can be checked
///         against the public upstream source.
///      3. Silence expires. If no ruling executes within disputeTimeout,
///         anyone may settle the market Invalid, paying half to each side.
///         An absent or captured arbiter can no longer freeze funds forever.
///      4. Holders of a matched pair are never exposed. Disputed is not
///         Resolved, so AlphaMarketCore.merge stays open throughout, and one
///         YES plus one NO always exits for exactly one unit whatever the
///         arbiter eventually decides.
///
///      What remains: a directional holder in a disputed market still depends
///      on the arbiter ruling honestly. That cannot be removed without a real
///      escalation layer, and is stated rather than hidden.
contract MarketRegistry is Ownable {
    using SafeERC20 for IERC20;

    error NotRelayer();
    error NotArbiter();
    error AlreadyRegistered();
    error UnknownMarket();
    error BadStatus();
    error DepthBelowFloor(uint128 depthUsd, uint128 floorUsd);
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error BadOutcome();
    error ZeroAddress();
    error NoPendingRuling();
    error RulingDelayNotElapsed(uint64 readyAt);
    error DisputeNotTimedOut(uint64 readyAt);
    error BadParams();

    struct Market {
        bytes32 conditionId;                 // Polymarket conditionId, also the local id
        uint64 endTime;                      // mirrored source resolution time
        uint64 registeredAt;
        uint128 depthUsd;                    // last measured source depth, whole USD
        MarketTypes.Status status;
        MarketTypes.Outcome outcome;         // final
        address proposer;
        uint64 proposedAt;
        MarketTypes.Outcome proposedOutcome;
        address disputer;
        uint64 disputedAt;
        MarketTypes.Outcome pendingRuling;   // announced but not yet applied
        uint64 rulingAt;                     // when the ruling was announced
    }

    /// @notice Token used for resolution bonds.
    IERC20 public immutable bondToken;

    /// @notice Bond required to propose or dispute an outcome.
    uint256 public bondAmount;

    /// @notice Seconds a proposal stays challengeable.
    uint64 public challengeWindow;

    /// @notice Minimum source depth, in whole USD, for a market to be mirrorable.
    uint128 public minDepthUsd;

    /// @notice Address permitted to rule on disputes. Never the owner.
    address public arbiter;

    /// @notice Seconds between announcing a ruling and being able to apply it.
    uint64 public rulingDelay;

    /// @notice Seconds after a dispute begins, past which anyone may settle the
    ///         market Invalid because no ruling was applied.
    uint64 public disputeTimeout;

    mapping(address => bool) public isRelayer;
    mapping(bytes32 => Market) private _markets;
    mapping(bytes32 => uint256) public indexOf;
    bytes32[] public marketIds;

    event RelayerSet(address indexed relayer, bool allowed);
    event ArbiterSet(address indexed arbiter);
    event ParamsSet(uint256 bondAmount, uint64 challengeWindow, uint128 minDepthUsd);
    event DisputeParamsSet(uint64 rulingDelay, uint64 disputeTimeout);
    event MarketRegistered(bytes32 indexed id, uint64 endTime, uint128 depthUsd, uint256 index);
    event DepthUpdated(bytes32 indexed id, uint128 depthUsd);
    event Halted(bytes32 indexed id, string reason);
    event Unhalted(bytes32 indexed id);
    event OutcomeProposed(bytes32 indexed id, address indexed proposer, MarketTypes.Outcome outcome);
    event OutcomeDisputed(bytes32 indexed id, address indexed disputer);
    event RulingAnnounced(bytes32 indexed id, MarketTypes.Outcome outcome, uint64 executableAt);
    event MarketResolved(bytes32 indexed id, MarketTypes.Outcome outcome);
    event ResolvedByTimeout(bytes32 indexed id);

    modifier onlyRelayer() {
        if (!isRelayer[msg.sender]) revert NotRelayer();
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert NotArbiter();
        _;
    }

    constructor(
        address bondToken_,
        uint256 bondAmount_,
        uint64 challengeWindow_,
        uint128 minDepthUsd_,
        address arbiter_,
        uint64 rulingDelay_,
        uint64 disputeTimeout_
    ) Ownable(msg.sender) {
        if (bondToken_ == address(0) || arbiter_ == address(0)) revert ZeroAddress();
        if (disputeTimeout_ <= rulingDelay_) revert BadParams();
        bondToken = IERC20(bondToken_);
        bondAmount = bondAmount_;
        challengeWindow = challengeWindow_;
        minDepthUsd = minDepthUsd_;
        arbiter = arbiter_;
        rulingDelay = rulingDelay_;
        disputeTimeout = disputeTimeout_;
        emit ParamsSet(bondAmount_, challengeWindow_, minDepthUsd_);
        emit ArbiterSet(arbiter_);
        emit DisputeParamsSet(rulingDelay_, disputeTimeout_);
    }

    // --------------------------------------------------------------- admin

    function setRelayer(address relayer, bool allowed) external onlyOwner {
        if (relayer == address(0)) revert ZeroAddress();
        isRelayer[relayer] = allowed;
        emit RelayerSet(relayer, allowed);
    }

    /// @notice Replace the arbiter. The owner may appoint, but never rule.
    function setArbiter(address arbiter_) external onlyOwner {
        if (arbiter_ == address(0)) revert ZeroAddress();
        arbiter = arbiter_;
        emit ArbiterSet(arbiter_);
    }

    function setParams(uint256 bondAmount_, uint64 challengeWindow_, uint128 minDepthUsd_)
        external
        onlyOwner
    {
        bondAmount = bondAmount_;
        challengeWindow = challengeWindow_;
        minDepthUsd = minDepthUsd_;
        emit ParamsSet(bondAmount_, challengeWindow_, minDepthUsd_);
    }

    function setDisputeParams(uint64 rulingDelay_, uint64 disputeTimeout_) external onlyOwner {
        if (disputeTimeout_ <= rulingDelay_) revert BadParams();
        rulingDelay = rulingDelay_;
        disputeTimeout = disputeTimeout_;
        emit DisputeParamsSet(rulingDelay_, disputeTimeout_);
    }

    // ------------------------------------------------------------- mirroring

    /// @notice Mirror a Polymarket market. Rejected if source depth is below floor.
    function registerMarket(bytes32 conditionId, uint64 endTime, uint128 depthUsd)
        external
        onlyRelayer
    {
        Market storage m = _markets[conditionId];
        if (m.status != MarketTypes.Status.None) revert AlreadyRegistered();
        if (depthUsd < minDepthUsd) revert DepthBelowFloor(depthUsd, minDepthUsd);

        m.conditionId = conditionId;
        m.endTime = endTime;
        m.registeredAt = uint64(block.timestamp);
        m.depthUsd = depthUsd;
        m.status = MarketTypes.Status.Active;

        indexOf[conditionId] = marketIds.length;
        marketIds.push(conditionId);

        emit MarketRegistered(conditionId, endTime, depthUsd, marketIds.length - 1);
    }

    /// @notice Refresh measured source depth. Falling below the floor halts trading.
    function updateDepth(bytes32 id, uint128 depthUsd) external onlyRelayer {
        Market storage m = _markets[id];
        if (m.status == MarketTypes.Status.None) revert UnknownMarket();
        m.depthUsd = depthUsd;
        emit DepthUpdated(id, depthUsd);

        if (depthUsd < minDepthUsd && m.status == MarketTypes.Status.Active) {
            m.status = MarketTypes.Status.Halted;
            emit Halted(id, "depth below floor");
        }
    }

    /// @notice Freeze split when a resolution proposal is observed upstream.
    function halt(bytes32 id, string calldata reason) external onlyRelayer {
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Active) revert BadStatus();
        m.status = MarketTypes.Status.Halted;
        emit Halted(id, reason);
    }

    function unhalt(bytes32 id) external onlyRelayer {
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Halted) revert BadStatus();
        if (m.depthUsd < minDepthUsd) revert DepthBelowFloor(m.depthUsd, minDepthUsd);
        m.status = MarketTypes.Status.Active;
        emit Unhalted(id);
    }

    // ------------------------------------------------------------ resolution

    /// @notice Post the mirrored outcome, backed by a bond. Permissionless.
    function proposeOutcome(bytes32 id, MarketTypes.Outcome outcome) external {
        if (outcome == MarketTypes.Outcome.Unresolved) revert BadOutcome();
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Active && m.status != MarketTypes.Status.Halted) {
            revert BadStatus();
        }
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        m.proposer = msg.sender;
        m.proposedAt = uint64(block.timestamp);
        m.proposedOutcome = outcome;
        m.status = MarketTypes.Status.Proposed;
        emit OutcomeProposed(id, msg.sender, outcome);
    }

    /// @notice Challenge a proposal inside the window. Escalates to the arbiter.
    function disputeOutcome(bytes32 id) external {
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Proposed) revert BadStatus();
        if (block.timestamp > m.proposedAt + challengeWindow) revert ChallengeWindowClosed();
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        m.disputer = msg.sender;
        m.disputedAt = uint64(block.timestamp);
        m.status = MarketTypes.Status.Disputed;
        emit OutcomeDisputed(id, msg.sender);
    }

    /// @notice Finalise an unchallenged proposal and refund the bond.
    function finalize(bytes32 id) external {
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Proposed) revert BadStatus();
        if (block.timestamp <= m.proposedAt + challengeWindow) revert ChallengeWindowOpen();
        m.outcome = m.proposedOutcome;
        m.status = MarketTypes.Status.Resolved;
        bondToken.safeTransfer(m.proposer, bondAmount);
        emit MarketResolved(id, m.outcome);
    }

    /// @notice Announce a ruling on a disputed market. Takes effect only after
    ///         rulingDelay, and only via executeRuling.
    /// @dev Announcing again resets the clock. A corrected ruling should face a
    ///      fresh window rather than inherit an almost-expired one.
    function proposeRuling(bytes32 id, MarketTypes.Outcome outcome) external onlyArbiter {
        if (outcome == MarketTypes.Outcome.Unresolved) revert BadOutcome();
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Disputed) revert BadStatus();
        m.pendingRuling = outcome;
        m.rulingAt = uint64(block.timestamp);
        emit RulingAnnounced(id, outcome, uint64(block.timestamp) + rulingDelay);
    }

    /// @notice Apply an announced ruling once the delay has elapsed.
    /// @dev Permissionless on purpose. The arbiter cannot quietly sit on a
    ///      ruling it has already made public.
    function executeRuling(bytes32 id) external {
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Disputed) revert BadStatus();
        if (m.pendingRuling == MarketTypes.Outcome.Unresolved) revert NoPendingRuling();
        uint64 readyAt = m.rulingAt + rulingDelay;
        if (block.timestamp < readyAt) revert RulingDelayNotElapsed(readyAt);

        MarketTypes.Outcome outcome = m.pendingRuling;
        m.outcome = outcome;
        m.status = MarketTypes.Status.Resolved;
        address winner = (outcome == m.proposedOutcome) ? m.proposer : m.disputer;
        bondToken.safeTransfer(winner, bondAmount * 2);
        emit MarketResolved(id, outcome);
    }

    /// @notice Settle a stalled dispute as Invalid, paying half to each side.
    /// @dev The escape hatch for an absent or captured arbiter. Without it a
    ///      market can sit in Disputed forever: redeem requires Resolved, so
    ///      every directional holder's collateral would be frozen permanently.
    ///      Both bonds are refunded, since nobody was shown to be right.
    function resolveByTimeout(bytes32 id) external {
        Market storage m = _markets[id];
        if (m.status != MarketTypes.Status.Disputed) revert BadStatus();
        uint64 readyAt = m.disputedAt + disputeTimeout;
        if (block.timestamp < readyAt) revert DisputeNotTimedOut(readyAt);

        m.outcome = MarketTypes.Outcome.Invalid;
        m.status = MarketTypes.Status.Resolved;
        bondToken.safeTransfer(m.proposer, bondAmount);
        bondToken.safeTransfer(m.disputer, bondAmount);
        emit ResolvedByTimeout(id);
        emit MarketResolved(id, MarketTypes.Outcome.Invalid);
    }

    // ----------------------------------------------------------------- views

    function getMarket(bytes32 id) external view returns (Market memory) {
        return _markets[id];
    }

    function statusOf(bytes32 id) external view returns (MarketTypes.Status) {
        return _markets[id].status;
    }

    function outcomeOf(bytes32 id) external view returns (MarketTypes.Outcome) {
        return _markets[id].outcome;
    }

    /// @notice True only when split should be permitted.
    function isTradeable(bytes32 id) external view returns (bool) {
        return _markets[id].status == MarketTypes.Status.Active;
    }

    function isResolved(bytes32 id) external view returns (bool) {
        return _markets[id].status == MarketTypes.Status.Resolved;
    }

    /// @notice When an announced ruling becomes executable. Zero if none.
    function rulingExecutableAt(bytes32 id) external view returns (uint64) {
        Market memory m = _markets[id];
        if (m.pendingRuling == MarketTypes.Outcome.Unresolved) return 0;
        return m.rulingAt + rulingDelay;
    }

    /// @notice When a stalled dispute may be settled Invalid by anyone.
    function timeoutAt(bytes32 id) external view returns (uint64) {
        Market memory m = _markets[id];
        if (m.status != MarketTypes.Status.Disputed) return 0;
        return m.disputedAt + disputeTimeout;
    }

    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }
}
