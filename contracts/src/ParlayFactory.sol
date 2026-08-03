// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {MarketTypes} from "./types/MarketTypes.sol";

/// @title ParlayFactory
/// @notice Binary markets over boolean combinations of already-mirrored markets.
///         "A wins AND B wins" pays 1 only if every leg lands.
///
/// @dev WHY THIS IS CHEAP FOR US AND EXPENSIVE FOR EVERYONE ELSE
///      Resolution is a pure boolean function over outcomes the registry already
///      holds. No new oracle, no new data feed, no extra trust assumption. A
///      regulated venue must certify each combination in advance, which is why
///      Kalshi's combos are confined to predefined groups; here any combination
///      of mirrored markets can be created permissionlessly.
///
/// @dev WHAT A PARLAY IS NOT
///      Holding YES(A) and YES(B) separately pays out when only one lands. A
///      parlay pays nothing unless all legs land. Different instrument, and it
///      cannot be replicated by holding the legs.
///
/// @dev INVALID LEGS
///      If any leg resolves Invalid the combination is undetermined, so the
///      parlay resolves Invalid and pays 0.5 to each side. This matches how the
///      core handles an Invalid market and avoids inventing a leg-dropping rule
///      that would change the odds after the fact.
contract ParlayFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error TooFewLegs();
    error TooManyLegs();
    error LengthMismatch();
    error DuplicateLeg();
    error BadRequiredOutcome();
    error LegNotActive(bytes32 marketId);
    error ParlayExists();
    error UnknownParlay();
    error NotTradeable();
    error AlreadyResolved();
    error NotResolved();
    error LegsPending();
    error NothingToRedeem();

    uint256 public constant MAX_LEGS = 5;

    struct Parlay {
        bytes32[] marketIds;
        uint8[] required;        // MarketTypes.Outcome each leg must produce
        OutcomeToken yes;
        OutcomeToken no;
        MarketTypes.Outcome outcome;
        bool resolved;
        uint64 createdAt;
    }

    IERC20 public immutable collateral;
    uint8 public immutable collateralDecimals;
    MarketRegistry public immutable registry;

    mapping(bytes32 => Parlay) private _parlays;
    bytes32[] public parlayIds;

    event ParlayCreated(
        bytes32 indexed parlayId, bytes32[] marketIds, uint8[] required, address yes, address no
    );
    event Split(bytes32 indexed parlayId, address indexed account, uint256 amount);
    event Merge(bytes32 indexed parlayId, address indexed account, uint256 amount);
    event Resolved(bytes32 indexed parlayId, MarketTypes.Outcome outcome);
    event Redeem(
        bytes32 indexed parlayId, address indexed account,
        uint256 yesAmount, uint256 noAmount, uint256 payout
    );

    constructor(address collateral_, address registry_) {
        if (collateral_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        collateral = IERC20(collateral_);
        collateralDecimals = IERC20Metadata(collateral_).decimals();
        registry = MarketRegistry(registry_);
    }

    /// @notice Deterministic id, so the same combination cannot be listed twice.
    function parlayIdFor(bytes32[] calldata marketIds, uint8[] calldata required)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(marketIds, required));
    }

    /// @notice Create a combination market. Permissionless.
    /// @dev Every leg must still be tradeable. A leg that has already resolved,
    ///      or whose source is resolving upstream, would let the creator mint a
    ///      combination whose answer is partly known.
    function createParlay(bytes32[] calldata marketIds, uint8[] calldata required)
        external
        returns (bytes32 parlayId)
    {
        uint256 n = marketIds.length;
        if (n < 2) revert TooFewLegs();
        if (n > MAX_LEGS) revert TooManyLegs();
        if (required.length != n) revert LengthMismatch();

        for (uint256 i = 0; i < n; i++) {
            uint8 r = required[i];
            if (r != uint8(MarketTypes.Outcome.Yes) && r != uint8(MarketTypes.Outcome.No)) {
                revert BadRequiredOutcome();
            }
            if (!registry.isTradeable(marketIds[i])) revert LegNotActive(marketIds[i]);
            for (uint256 j = i + 1; j < n; j++) {
                if (marketIds[i] == marketIds[j]) revert DuplicateLeg();
            }
        }

        parlayId = parlayIdFor(marketIds, required);
        Parlay storage p = _parlays[parlayId];
        if (address(p.yes) != address(0)) revert ParlayExists();

        uint256 idx = parlayIds.length;
        string memory suffix = _toString(idx);
        OutcomeToken y = new OutcomeToken(
            string.concat("Alpha Parlay YES #", suffix),
            string.concat("pYES", suffix),
            collateralDecimals,
            address(this)
        );
        OutcomeToken nToken = new OutcomeToken(
            string.concat("Alpha Parlay NO #", suffix),
            string.concat("pNO", suffix),
            collateralDecimals,
            address(this)
        );

        p.marketIds = marketIds;
        p.required = required;
        p.yes = y;
        p.no = nToken;
        p.createdAt = uint64(block.timestamp);
        parlayIds.push(parlayId);

        emit ParlayCreated(parlayId, marketIds, required, address(y), address(nToken));
    }

    /// @notice Deposit collateral, receive equal PARLAY-YES and PARLAY-NO.
    /// @dev Requires every leg still tradeable, for the same reason as creation.
    function split(bytes32 parlayId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Parlay storage p = _get(parlayId);
        if (p.resolved) revert AlreadyResolved();
        uint256 n = p.marketIds.length;
        for (uint256 i = 0; i < n; i++) {
            if (!registry.isTradeable(p.marketIds[i])) revert NotTradeable();
        }
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        p.yes.mint(msg.sender, amount);
        p.no.mint(msg.sender, amount);
        emit Split(parlayId, msg.sender, amount);
    }

    /// @notice Burn a matched pair for collateral. Open until resolution, since
    ///         a hedged pair is worth exactly one unit whatever happens.
    function merge(bytes32 parlayId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Parlay storage p = _get(parlayId);
        if (p.resolved) revert AlreadyResolved();
        p.yes.burn(msg.sender, amount);
        p.no.burn(msg.sender, amount);
        collateral.safeTransfer(msg.sender, amount);
        emit Merge(parlayId, msg.sender, amount);
    }

    /// @notice Resolve once every leg is final. Permissionless: the result is a
    ///         deterministic function of registry state, so anyone may trigger it
    ///         and nobody can influence the answer.
    function resolve(bytes32 parlayId) external {
        Parlay storage p = _get(parlayId);
        if (p.resolved) revert AlreadyResolved();

        uint256 n = p.marketIds.length;
        bool allMatch = true;
        for (uint256 i = 0; i < n; i++) {
            bytes32 mid = p.marketIds[i];
            if (!registry.isResolved(mid)) revert LegsPending();
            MarketTypes.Outcome o = registry.outcomeOf(mid);
            if (o == MarketTypes.Outcome.Invalid) {
                p.outcome = MarketTypes.Outcome.Invalid;
                p.resolved = true;
                emit Resolved(parlayId, MarketTypes.Outcome.Invalid);
                return;
            }
            if (uint8(o) != p.required[i]) allMatch = false;
        }

        p.outcome = allMatch ? MarketTypes.Outcome.Yes : MarketTypes.Outcome.No;
        p.resolved = true;
        emit Resolved(parlayId, p.outcome);
    }

    /// @notice Redeem after resolution.
    function redeem(bytes32 parlayId, uint256 yesAmount, uint256 noAmount)
        external
        nonReentrant
    {
        if (yesAmount == 0 && noAmount == 0) revert ZeroAmount();
        Parlay storage p = _get(parlayId);
        if (!p.resolved) revert NotResolved();

        uint256 payout;
        if (p.outcome == MarketTypes.Outcome.Yes) payout = yesAmount;
        else if (p.outcome == MarketTypes.Outcome.No) payout = noAmount;
        else payout = (yesAmount + noAmount) / 2;

        if (yesAmount > 0) p.yes.burn(msg.sender, yesAmount);
        if (noAmount > 0) p.no.burn(msg.sender, noAmount);
        if (payout == 0) revert NothingToRedeem();

        collateral.safeTransfer(msg.sender, payout);
        emit Redeem(parlayId, msg.sender, yesAmount, noAmount, payout);
    }

    // ----------------------------------------------------------------- views

    function getParlay(bytes32 parlayId)
        external
        view
        returns (
            bytes32[] memory marketIds,
            uint8[] memory required,
            address yes,
            address no,
            MarketTypes.Outcome outcome,
            bool resolved
        )
    {
        Parlay storage p = _parlays[parlayId];
        return (p.marketIds, p.required, address(p.yes), address(p.no), p.outcome, p.resolved);
    }

    function tokensOf(bytes32 parlayId) external view returns (address yes, address no) {
        Parlay storage p = _parlays[parlayId];
        return (address(p.yes), address(p.no));
    }

    /// @notice True when every leg is final and `resolve` will succeed.
    function isResolvable(bytes32 parlayId) external view returns (bool) {
        Parlay storage p = _parlays[parlayId];
        if (address(p.yes) == address(0) || p.resolved) return false;
        uint256 n = p.marketIds.length;
        for (uint256 i = 0; i < n; i++) {
            if (!registry.isResolved(p.marketIds[i])) return false;
        }
        return true;
    }

    function parlayCount() external view returns (uint256) {
        return parlayIds.length;
    }

    // -------------------------------------------------------------- internal

    function _get(bytes32 parlayId) internal view returns (Parlay storage p) {
        p = _parlays[parlayId];
        if (address(p.yes) == address(0)) revert UnknownParlay();
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 d;
        uint256 t = v;
        while (t != 0) { d++; t /= 10; }
        bytes memory b = new bytes(d);
        while (v != 0) { b[--d] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
