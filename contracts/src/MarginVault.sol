// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AlphaMarketCore} from "./AlphaMarketCore.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {MarketTypes} from "./types/MarketTypes.sol";
import {Pausable} from "./Pausable.sol";

/// @title MarginVault
/// @notice Lends against hedged prediction positions using a proven worst-case
///         floor, so the loan is safe without any price oracle or liquidation.
///
/// @dev THE CORE ARGUMENT
///      A pledged position of Y YES and N NO redeems for:
///        Yes outcome     -> Y
///        No outcome      -> N
///        Invalid outcome -> (Y + N) / 2
///      Every one of those is at least min(Y, N). That is the floor, and it is
///      proven by enumeration rather than estimated from a price.
///
///      Cap debt below the floor and the vault can always repay itself out of
///      redemption proceeds. Consequences:
///        - no oracle, so no price-manipulation attack surface
///        - no liquidation, so no cascade and no keeper dependency
///        - bad debt is arithmetically impossible, not merely unlikely
///
///      The cost is honest: a purely directional holder has min(Y, N) = 0 and
///      therefore borrows nothing. Lending against one-sided exposure needs a
///      price feed and a liquidation engine, and is deliberately out of scope.
///
/// @dev INTEREST AND THE FLOOR
///      Interest would break the proof if debt could grow past the floor, so
///      borrowing power reserves headroom for all interest that can ever accrue.
///      Accrual stops at the market end time, which bounds total debt exactly.
contract MarginVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error MarketNotInitialized();
    error MarketResolvedAlready();
    error MarketNotResolved();
    error InsufficientFloor(uint256 maxDebtAtEnd, uint256 borrowLimit);
    error FacilityExhausted(uint256 requested, uint256 available);
    error NothingBorrowed();
    error PositionSettled();
    error RepayExceedsDebt(uint256 amount, uint256 debt);
    error BadParams();

    struct Position {
        uint256 yesAmount;   // YES pledged
        uint256 noAmount;    // NO pledged
        uint256 principal;   // total debt, including capitalised interest
        uint256 interestOwed; // portion of principal that is interest, for revenue split
        uint64 accrualFrom;  // timestamp interest last capitalised
        bool settled;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;

    IERC20 public immutable collateral;
    AlphaMarketCore public immutable core;
    MarketRegistry public immutable registry;

    /// @notice Safety margin below the proven floor, in basis points.
    uint256 public haircutBps;

    /// @notice Simple annual interest rate, in basis points.
    uint256 public rateBps;

    /// @notice Total debt outstanding across all users, including capitalised
    ///         interest. Compared against `facilityCap` on every borrow.
    uint256 public facilityCap;

    /// @notice Principal currently outstanding.
    uint256 public totalPrincipal;

    /// @notice Interest collected, withdrawable by the owner.
    uint256 public accruedRevenue;

    mapping(bytes32 => mapping(address => Position)) private _positions;

    event ParamsSet(uint256 haircutBps, uint256 rateBps, uint256 facilityCap);
    event Funded(uint256 amount);
    event Defunded(uint256 amount);
    event Pledged(bytes32 indexed id, address indexed user, uint256 yesAmount, uint256 noAmount);
    event Unpledged(bytes32 indexed id, address indexed user, uint256 yesAmount, uint256 noAmount);
    event Borrowed(bytes32 indexed id, address indexed user, uint256 amount, uint256 principal);
    event Repaid(bytes32 indexed id, address indexed user, uint256 amount, uint256 principal);
    event Settled(
        bytes32 indexed id, address indexed user, uint256 payout, uint256 debt, uint256 surplus
    );

    constructor(address core_, uint256 haircutBps_, uint256 rateBps_, uint256 facilityCap_)
        Ownable(msg.sender)
    {
        if (core_ == address(0)) revert ZeroAddress();
        if (haircutBps_ >= BPS) revert BadParams();
        core = AlphaMarketCore(core_);
        collateral = IERC20(address(AlphaMarketCore(core_).collateral()));
        registry = MarketRegistry(address(AlphaMarketCore(core_).registry()));
        haircutBps = haircutBps_;
        rateBps = rateBps_;
        facilityCap = facilityCap_;
        emit ParamsSet(haircutBps_, rateBps_, facilityCap_);
    }

    // ----------------------------------------------------------------- admin

    function setParams(uint256 haircutBps_, uint256 rateBps_, uint256 facilityCap_)
        external
        onlyOwner
    {
        if (haircutBps_ >= BPS) revert BadParams();
        haircutBps = haircutBps_;
        rateBps = rateBps_;
        facilityCap = facilityCap_;
        emit ParamsSet(haircutBps_, rateBps_, facilityCap_);
    }

    /// @notice Supply lending capital. Capped treasury facility, not a public pool.
    function fund(uint256 amount) external onlyOwner {
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(amount);
    }

    /// @notice Withdraw idle capital and collected interest.
    function defund(uint256 amount) external onlyOwner {
        collateral.safeTransfer(msg.sender, amount);
        if (amount >= accruedRevenue) accruedRevenue = 0;
        else accruedRevenue -= amount;
        emit Defunded(amount);
    }

    // ------------------------------------------------------------- positions

    /// @notice Pledge outcome tokens. Locked until repaid, so they cannot be
    ///         transferred away while backing a loan.
    function pledge(bytes32 id, uint256 yesAmount, uint256 noAmount) external nonReentrant whenEntryOpen {
        if (yesAmount == 0 && noAmount == 0) revert ZeroAmount();
        if (registry.isResolved(id)) revert MarketResolvedAlready();
        (address y, address n) = core.tokensOf(id);
        if (y == address(0)) revert MarketNotInitialized();

        Position storage p = _positions[id][msg.sender];
        if (p.settled) revert PositionSettled();

        if (yesAmount > 0) {
            IERC20(y).safeTransferFrom(msg.sender, address(this), yesAmount);
            p.yesAmount += yesAmount;
        }
        if (noAmount > 0) {
            IERC20(n).safeTransferFrom(msg.sender, address(this), noAmount);
            p.noAmount += noAmount;
        }
        emit Pledged(id, msg.sender, yesAmount, noAmount);
    }

    /// @notice Withdraw pledged tokens, provided the remaining floor still covers
    ///         the debt including all interest that can still accrue.
    function unpledge(bytes32 id, uint256 yesAmount, uint256 noAmount) external nonReentrant {
        Position storage p = _positions[id][msg.sender];
        if (yesAmount > p.yesAmount || noAmount > p.noAmount) revert ZeroAmount();

        p.yesAmount -= yesAmount;
        p.noAmount -= noAmount;

        uint256 maxDebt = _maxDebtAtEnd(id, p);
        uint256 limit = _borrowLimit(p);
        if (maxDebt > limit) revert InsufficientFloor(maxDebt, limit);

        (address y, address n) = core.tokensOf(id);
        if (yesAmount > 0) IERC20(y).safeTransfer(msg.sender, yesAmount);
        if (noAmount > 0) IERC20(n).safeTransfer(msg.sender, noAmount);
        emit Unpledged(id, msg.sender, yesAmount, noAmount);
    }

    // -------------------------------------------------------------- borrowing

    /// @notice Borrow against the proven floor of the pledged position.
    function borrow(bytes32 id, uint256 amount) external nonReentrant whenEntryOpen {
        if (amount == 0) revert ZeroAmount();
        if (registry.isResolved(id)) revert MarketResolvedAlready();

        Position storage p = _positions[id][msg.sender];
        if (p.settled) revert PositionSettled();

        _capitalise(id, p);
        p.principal += amount;

        uint256 maxDebt = _maxDebtAtEnd(id, p);
        uint256 limit = _borrowLimit(p);
        if (maxDebt > limit) revert InsufficientFloor(maxDebt, limit);

        totalPrincipal += amount;
        if (totalPrincipal > facilityCap) {
            revert FacilityExhausted(amount, facilityCap - (totalPrincipal - amount));
        }

        collateral.safeTransfer(msg.sender, amount);
        emit Borrowed(id, msg.sender, amount, p.principal);
    }

    /// @notice Repay debt. Interest is capitalised first, so repaying the full
    ///         `debtOf` value clears the position exactly.
    function repay(bytes32 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage p = _positions[id][msg.sender];
        if (p.principal == 0) revert NothingBorrowed();

        _capitalise(id, p);
        // Interest accrues between reading debtOf and this transaction landing,
        // so a caller who repays the value they just read always leaves a dust
        // residue and can never reach zero, which strands their collateral.
        // type(uint256).max means "whatever the debt is at execution time".
        if (amount == type(uint256).max) amount = p.principal;
        if (amount > p.principal) revert RepayExceedsDebt(amount, p.principal);

        collateral.safeTransferFrom(msg.sender, address(this), amount);

        // interest first, then principal
        uint256 payInterest = amount < p.interestOwed ? amount : p.interestOwed;
        p.interestOwed -= payInterest;
        accruedRevenue += payInterest;

        p.principal -= amount;
        totalPrincipal = totalPrincipal >= amount ? totalPrincipal - amount : 0;

        emit Repaid(id, msg.sender, amount, p.principal);
    }

    // -------------------------------------------------------------- settlement

    /// @notice Redeem a pledged position after resolution, repay the debt from
    ///         proceeds, and return the surplus. Permissionless: proceeds always
    ///         cover the debt, so anyone may trigger it.
    function settle(bytes32 id, address user) external nonReentrant {
        if (!registry.isResolved(id)) revert MarketNotResolved();
        Position storage p = _positions[id][user];
        if (p.settled) revert PositionSettled();
        if (p.yesAmount == 0 && p.noAmount == 0) revert ZeroAmount();

        _capitalise(id, p);
        uint256 debt = p.principal;
        uint256 y = p.yesAmount;
        uint256 n = p.noAmount;

        p.yesAmount = 0;
        p.noAmount = 0;
        p.principal = 0;
        accruedRevenue += p.interestOwed;
        p.interestOwed = 0;
        p.settled = true;
        totalPrincipal = totalPrincipal >= debt ? totalPrincipal - debt : 0;

        // A one-sided pledge on the losing side redeems for nothing, and
        // core.redeem reverts on a zero payout. Return the worthless tokens
        // instead, otherwise they are stranded in this contract forever.
        MarketTypes.Outcome o = registry.outcomeOf(id);
        uint256 expected = o == MarketTypes.Outcome.Yes
            ? y
            : (o == MarketTypes.Outcome.No ? n : (y + n) / 2);

        uint256 payout;
        if (expected > 0) {
            uint256 balBefore = collateral.balanceOf(address(this));
            core.redeem(id, y, n);
            payout = collateral.balanceOf(address(this)) - balBefore;
        } else {
            // debt <= floor <= expected == 0, so nothing is owed here
            (address ty, address tn) = core.tokensOf(id);
            if (y > 0) IERC20(ty).safeTransfer(user, y);
            if (n > 0) IERC20(tn).safeTransfer(user, n);
        }

        // proven: payout >= min(y, n) >= debt
        uint256 surplus = payout - debt;
        if (surplus > 0) collateral.safeTransfer(user, surplus);
        emit Settled(id, user, payout, debt, surplus);
    }


    /// @inheritdoc Pausable
    function _pauseAdmin() internal view override returns (address) {
        return owner();
    }

    // ----------------------------------------------------------------- views

    function positionOf(bytes32 id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    /// @notice Proven worst-case redemption value of the pledged position.
    function floorOf(bytes32 id, address user) external view returns (uint256) {
        Position memory p = _positions[id][user];
        return p.yesAmount < p.noAmount ? p.yesAmount : p.noAmount;
    }

    /// @notice Debt including interest accrued to now (capped at market end).
    function debtOf(bytes32 id, address user) external view returns (uint256) {
        Position memory p = _positions[id][user];
        return _accrued(id, p);
    }

    /// @notice Additional amount borrowable right now.
    /// @dev Must reserve every unit of interest the new debt can still accrue,
    ///      otherwise this view reports an amount that `borrow` then rejects.
    ///      Solving  P * (YEAR*BPS + rate*remaining) / (YEAR*BPS) <= limit
    ///      gives    P <= limit * YEAR*BPS / (YEAR*BPS + rate*remaining).
    ///      Both divisions truncate down, so the result is always safe.
    function availableToBorrow(bytes32 id, address user) external view returns (uint256) {
        Position memory p = _positions[id][user];
        if (p.settled) return 0;
        uint256 limit = _borrowLimit(p);
        if (limit == 0) return 0;

        uint256 principalNow = _accrued(id, p);
        uint64 endTime = registry.getMarket(id).endTime;
        uint64 nowT = uint64(block.timestamp);
        uint256 remaining = endTime > nowT ? endTime - nowT : 0;

        uint256 maxPrincipal = (limit * (YEAR * BPS)) / (YEAR * BPS + rateBps * remaining);
        if (maxPrincipal <= principalNow) return 0;
        uint256 headroom = maxPrincipal - principalNow;
        uint256 facility = facilityCap > totalPrincipal ? facilityCap - totalPrincipal : 0;
        uint256 liquid = collateral.balanceOf(address(this));
        if (headroom > facility) headroom = facility;
        if (headroom > liquid) headroom = liquid;
        return headroom;
    }

    // -------------------------------------------------------------- internal

    function _borrowLimit(Position memory p) internal view returns (uint256) {
        uint256 floor = p.yesAmount < p.noAmount ? p.yesAmount : p.noAmount;
        return floor * (BPS - haircutBps) / BPS;
    }

    /// @dev Interest stops accruing at the market end time, which bounds debt.
    function _accrualCutoff(bytes32 id) internal view returns (uint64) {
        uint64 endTime = registry.getMarket(id).endTime;
        return uint64(block.timestamp) < endTime ? uint64(block.timestamp) : endTime;
    }

    function _accrued(bytes32 id, Position memory p) internal view returns (uint256) {
        if (p.principal == 0) return 0;
        uint64 t = _accrualCutoff(id);
        if (t <= p.accrualFrom) return p.principal;
        uint256 elapsed = t - p.accrualFrom;
        return p.principal + (p.principal * rateBps * elapsed) / (YEAR * BPS);
    }

    /// @dev Worst case: all interest that can still accrue until market end.
    function _maxDebtAtEnd(bytes32 id, Position memory p) internal view returns (uint256) {
        if (p.principal == 0) return 0;
        uint64 endTime = registry.getMarket(id).endTime;
        if (endTime <= p.accrualFrom) return p.principal;
        uint256 elapsed = endTime - p.accrualFrom;
        return p.principal + (p.principal * rateBps * elapsed) / (YEAR * BPS);
    }

    /// @dev Folds accrued interest into principal so state matches `debtOf`.
    ///      Must be called before any read of `p.principal` used for accounting.
    function _capitalise(bytes32 id, Position storage p) internal {
        if (p.principal != 0) {
            uint64 t = _accrualCutoff(id);
            if (t > p.accrualFrom) {
                uint256 i = (p.principal * rateBps * (t - p.accrualFrom)) / (YEAR * BPS);
                if (i != 0) {
                    p.principal += i;
                    p.interestOwed += i;
                    totalPrincipal += i;
                }
            }
        }
        p.accrualFrom = uint64(block.timestamp);
    }
}
