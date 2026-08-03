// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AlphaMarketCore} from "./AlphaMarketCore.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {IPositionOracle} from "./interfaces/IPositionOracle.sol";
import {MarketTypes} from "./types/MarketTypes.sol";
import {Pausable} from "./Pausable.sol";

/// @title DirectionalVault
/// @notice Borrow against a one-sided prediction position, so a holder who
///         believes in a single outcome can open a second position without
///         closing the first.
///
/// @dev WHY THIS EXISTS ALONGSIDE MarginVault
///      MarginVault lends against min(YES, NO), a floor proven by enumerating
///      the outcome space. It needs no oracle and no liquidation, and bad debt
///      is impossible. But it lends nothing to a directional holder, because a
///      one-sided position has a worst case of zero. That excludes exactly the
///      retail user the product is for.
///
///      This vault serves that user, and pays for it with every mechanism
///      MarginVault avoids: a price feed, a liquidation engine, and the
///      possibility of bad debt. Use MarginVault for hedged positions; it is
///      strictly safer and lends far more against the same tokens.
///
/// @dev THE DEADLINE IS THE LOAD-BEARING RULE
///      At resolution an outcome token jumps to 0 or 1 in a single block, so
///      liquidation cannot execute inside that move. Every loan therefore has a
///      hard deadline before resolution, after which liquidation opens
///      regardless of health. The engine is never exposed to the jump.
///
/// @dev WHERE LOSSES COME FROM
///      Not from markets resolving against the borrower: a rational borrower
///      repays whenever the position is worth more than the debt, and at 30%
///      LTV that is almost always. Losses come from a price gap, where the
///      price moves past the liquidation threshold with no trade in between.
///      That is bounded by a per-market debt cap and absorbed by the vault,
///      which then holds the position to resolution and may recover it.
contract DirectionalVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error BadParams();
    error MarketNotInitialized();
    error MarketResolvedAlready();
    error MarketNotResolved();
    error NoPrice(bytes32 id);
    error PastDeadline(uint64 deadline);
    error BeforeDeadline(uint64 deadline);
    error Undercollateralised(uint256 debt, uint256 limit);
    error PositionHealthy(uint256 healthBps);
    error NothingBorrowed();
    error RepayExceedsDebt(uint256 amount, uint256 debt);
    error MarketDebtCapped(uint256 requested, uint256 available);
    error FacilityExhausted();
    error InsufficientLiquidity();
    error SeizeExceedsPledge();
    error NothingPledged();

    struct Position {
        uint256 yesAmount;
        uint256 noAmount;
        uint256 principal;
        uint256 interestOwed;
        uint64 accrualFrom;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 private constant ONE = 1e6;

    IERC20 public immutable collateral;
    AlphaMarketCore public immutable core;
    MarketRegistry public immutable registry;
    IPositionOracle public oracle;

    uint16 public ltvBps;
    uint16 public liqThresholdBps;
    uint16 public liqBonusBps;
    uint16 public closeFactorBps;
    uint256 public rateBps;
    uint256 public facilityCap;

    /// @notice Seconds before resolution at which a loan must be repaid.
    uint64 public deadlineBuffer;

    /// @notice Maximum debt secured by any single market, so one market cannot
    ///         sink the vault when its price gaps.
    uint256 public maxDebtPerMarket;

    uint256 public totalPrincipal;
    uint256 public accruedRevenue;
    uint256 public badDebt;
    uint256 public recovered;

    mapping(bytes32 => mapping(address => Position)) private _positions;
    mapping(bytes32 => uint256) public marketDebt;
    mapping(bytes32 => uint256) public absorbedYes;
    mapping(bytes32 => uint256) public absorbedNo;

    event OracleSet(address oracle);
    event ParamsSet(uint16 ltvBps, uint16 liqThresholdBps, uint16 liqBonusBps, uint16 closeFactorBps);
    event RiskSet(uint256 rateBps, uint256 facilityCap, uint64 deadlineBuffer, uint256 maxDebtPerMarket);
    event Funded(uint256 amount);
    event Defunded(uint256 amount);
    event Pledged(bytes32 indexed id, address indexed user, uint256 yesAmount, uint256 noAmount);
    event Unpledged(bytes32 indexed id, address indexed user, uint256 yesAmount, uint256 noAmount);
    event Borrowed(bytes32 indexed id, address indexed user, uint256 amount, uint256 principal);
    event Repaid(bytes32 indexed id, address indexed user, uint256 amount, uint256 principal);
    event Liquidated(
        bytes32 indexed id, address indexed user, address indexed liquidator,
        uint256 repaid, uint256 seizedYes, uint256 seizedNo, bool byDeadline
    );
    event Absorbed(bytes32 indexed id, address indexed user, uint256 writtenOff, uint256 yes, uint256 no);
    event Swept(bytes32 indexed id, uint256 payout, uint256 badDebtRemaining);
    event SettledAfterResolution(bytes32 indexed id, address indexed user, uint256 payout, uint256 debt);

    constructor(address core_, address oracle_) Ownable(msg.sender) {
        if (core_ == address(0) || oracle_ == address(0)) revert ZeroAddress();
        core = AlphaMarketCore(core_);
        collateral = IERC20(address(AlphaMarketCore(core_).collateral()));
        registry = MarketRegistry(address(AlphaMarketCore(core_).registry()));
        oracle = IPositionOracle(oracle_);

        ltvBps = 3000;
        liqThresholdBps = 5000;
        liqBonusBps = 800;
        closeFactorBps = 5000;
        rateBps = 1500;
        facilityCap = 100_000e6;
        deadlineBuffer = 1 hours;
        maxDebtPerMarket = 5_000e6;

        emit OracleSet(oracle_);
        emit ParamsSet(ltvBps, liqThresholdBps, liqBonusBps, closeFactorBps);
        emit RiskSet(rateBps, facilityCap, deadlineBuffer, maxDebtPerMarket);
    }

    // ----------------------------------------------------------------- admin

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPositionOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function setParams(uint16 ltv_, uint16 liq_, uint16 bonus_, uint16 close_) external onlyOwner {
        if (ltv_ == 0 || ltv_ >= liq_ || liq_ >= BPS) revert BadParams();
        if (bonus_ > 3000 || close_ == 0 || close_ > BPS) revert BadParams();
        ltvBps = ltv_;
        liqThresholdBps = liq_;
        liqBonusBps = bonus_;
        closeFactorBps = close_;
        emit ParamsSet(ltv_, liq_, bonus_, close_);
    }

    function setRisk(uint256 rate_, uint256 cap_, uint64 buffer_, uint256 perMarket_)
        external
        onlyOwner
    {
        if (buffer_ == 0) revert BadParams();
        rateBps = rate_;
        facilityCap = cap_;
        deadlineBuffer = buffer_;
        maxDebtPerMarket = perMarket_;
        emit RiskSet(rate_, cap_, buffer_, perMarket_);
    }

    function fund(uint256 amount) external onlyOwner {
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(amount);
    }

    function defund(uint256 amount) external onlyOwner {
        collateral.safeTransfer(msg.sender, amount);
        accruedRevenue = amount >= accruedRevenue ? 0 : accruedRevenue - amount;
        emit Defunded(amount);
    }

    // ------------------------------------------------------------- positions

    function pledge(bytes32 id, uint256 yesAmount, uint256 noAmount) external nonReentrant whenEntryOpen {
        if (yesAmount == 0 && noAmount == 0) revert ZeroAmount();
        if (registry.isResolved(id)) revert MarketResolvedAlready();
        (address y, address n) = core.tokensOf(id);
        if (y == address(0)) revert MarketNotInitialized();

        Position storage p = _positions[id][msg.sender];
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

    function unpledge(bytes32 id, uint256 yesAmount, uint256 noAmount) external nonReentrant {
        Position storage p = _positions[id][msg.sender];
        if (yesAmount > p.yesAmount || noAmount > p.noAmount) revert SeizeExceedsPledge();
        p.yesAmount -= yesAmount;
        p.noAmount -= noAmount;

        _capitalise(id, p);
        if (p.principal > 0) {
            uint256 limit = borrowLimit(id, msg.sender);
            if (p.principal > limit) revert Undercollateralised(p.principal, limit);
        }
        (address y, address n) = core.tokensOf(id);
        if (yesAmount > 0) IERC20(y).safeTransfer(msg.sender, yesAmount);
        if (noAmount > 0) IERC20(n).safeTransfer(msg.sender, noAmount);
        emit Unpledged(id, msg.sender, yesAmount, noAmount);
    }

    // -------------------------------------------------------------- borrowing

    function borrow(bytes32 id, uint256 amount) external nonReentrant whenEntryOpen {
        if (amount == 0) revert ZeroAmount();
        if (registry.isResolved(id)) revert MarketResolvedAlready();
        uint64 dl = deadlineOf(id);
        if (block.timestamp >= dl) revert PastDeadline(dl);

        Position storage p = _positions[id][msg.sender];
        _capitalise(id, p);
        p.principal += amount;

        uint256 limit = borrowLimit(id, msg.sender);
        if (p.principal > limit) revert Undercollateralised(p.principal, limit);

        marketDebt[id] += amount;
        if (marketDebt[id] > maxDebtPerMarket) {
            revert MarketDebtCapped(amount, maxDebtPerMarket - (marketDebt[id] - amount));
        }
        totalPrincipal += amount;
        if (totalPrincipal > facilityCap) revert FacilityExhausted();
        if (amount > collateral.balanceOf(address(this))) revert InsufficientLiquidity();

        collateral.safeTransfer(msg.sender, amount);
        emit Borrowed(id, msg.sender, amount, p.principal);
    }

    function repay(bytes32 id, uint256 amount) external nonReentrant {
        _repayFor(id, msg.sender, msg.sender, amount);
    }

    // ------------------------------------------------------------ liquidation

    /// @notice Repay part of an unhealthy or overdue loan and seize collateral
    ///         at a discount. Permissionless.
    /// @dev Two independent triggers. Health is the ordinary one. The deadline
    ///      is the structural one: past it, liquidation opens no matter how
    ///      healthy the position looks, because resolution is imminent and the
    ///      price is about to jump to 0 or 1.
    function liquidate(bytes32 id, address user, uint256 repayAmount)
        external
        nonReentrant
    {
        Position storage p = _positions[id][user];
        _capitalise(id, p);
        if (p.principal == 0) revert NothingBorrowed();

        uint64 dl = deadlineOf(id);
        bool overdue = block.timestamp >= dl;
        // Health is only consulted before the deadline. Past it the trigger is
        // time, and reading a price that may be stale would revert exactly when
        // liquidation matters most.
        if (!overdue) {
            uint256 hb = healthBps(id, user);
            if (hb >= BPS) revert PositionHealthy(hb);
        }

        uint256 maxRepay = overdue ? p.principal : (p.principal * closeFactorBps) / BPS;
        if (repayAmount > maxRepay) repayAmount = maxRepay;
        if (repayAmount == 0) revert ZeroAmount();

        uint256 seizeValue = (repayAmount * (BPS + liqBonusBps)) / BPS;
        (uint256 sy, uint256 sn, uint256 usedValue) = _seizeFor(id, p, seizeValue);
        if (usedValue < seizeValue) {
            // not enough collateral to pay the full bonus; scale the repayment
            repayAmount = (usedValue * BPS) / (BPS + liqBonusBps);
            if (repayAmount == 0) revert ZeroAmount();
        }

        _repayFor(id, msg.sender, user, repayAmount);
        p.yesAmount -= sy;
        p.noAmount -= sn;

        (address y, address n) = core.tokensOf(id);
        if (sy > 0) IERC20(y).safeTransfer(msg.sender, sy);
        if (sn > 0) IERC20(n).safeTransfer(msg.sender, sn);
        emit Liquidated(id, user, msg.sender, repayAmount, sy, sn, overdue);
    }

    /// @notice Vault takes an overdue position nobody liquidated, writing the
    ///         debt off and holding the tokens to resolution.
    /// @dev This is the buyer-of-last-resort path. It is not charity: at a price
    ///      of 0.30 a written-off loan of 180 buys a position with an expected
    ///      redemption of 300. The write-off is recorded as bad debt and the
    ///      recovery is credited back by sweepAbsorbed.
    function absorb(bytes32 id, address user) external onlyOwner nonReentrant {
        uint64 dl = deadlineOf(id);
        if (block.timestamp < dl) revert BeforeDeadline(dl);

        Position storage p = _positions[id][user];
        _capitalise(id, p);
        uint256 debt = p.principal;
        if (debt == 0) revert NothingBorrowed();
        if (p.yesAmount == 0 && p.noAmount == 0) revert NothingPledged();

        uint256 sy = p.yesAmount;
        uint256 sn = p.noAmount;
        p.yesAmount = 0;
        p.noAmount = 0;
        p.principal = 0;
        p.interestOwed = 0;

        absorbedYes[id] += sy;
        absorbedNo[id] += sn;
        badDebt += debt;
        totalPrincipal = totalPrincipal >= debt ? totalPrincipal - debt : 0;
        marketDebt[id] = marketDebt[id] >= debt ? marketDebt[id] - debt : 0;

        emit Absorbed(id, user, debt, sy, sn);
    }

    /// @notice Redeem absorbed positions once the market has resolved.
    function sweepAbsorbed(bytes32 id) external nonReentrant {
        if (!registry.isResolved(id)) revert MarketNotResolved();
        uint256 sy = absorbedYes[id];
        uint256 sn = absorbedNo[id];
        if (sy == 0 && sn == 0) revert NothingPledged();
        absorbedYes[id] = 0;
        absorbedNo[id] = 0;

        MarketTypes.Outcome o = registry.outcomeOf(id);
        uint256 expected = o == MarketTypes.Outcome.Yes
            ? sy
            : (o == MarketTypes.Outcome.No ? sn : (sy + sn) / 2);

        uint256 payout;
        if (expected > 0) {
            uint256 before = collateral.balanceOf(address(this));
            core.redeem(id, sy, sn);
            payout = collateral.balanceOf(address(this)) - before;
        }
        recovered += payout;
        badDebt = badDebt > payout ? badDebt - payout : 0;
        emit Swept(id, payout, badDebt);
    }

    /// @notice Catch-all: a market resolved while a loan was still open. Redeem
    ///         the pledge, clear the debt, return the surplus.
    /// @dev The deadline should prevent this, but a missed liquidation must not
    ///      strand a user's collateral forever.
    function settleResolved(bytes32 id, address user) external nonReentrant {
        if (!registry.isResolved(id)) revert MarketNotResolved();
        Position storage p = _positions[id][user];
        if (p.yesAmount == 0 && p.noAmount == 0) revert NothingPledged();

        _capitalise(id, p);
        uint256 debt = p.principal;
        uint256 sy = p.yesAmount;
        uint256 sn = p.noAmount;
        p.yesAmount = 0;
        p.noAmount = 0;
        p.principal = 0;
        accruedRevenue += p.interestOwed;
        p.interestOwed = 0;
        totalPrincipal = totalPrincipal >= debt ? totalPrincipal - debt : 0;
        marketDebt[id] = marketDebt[id] >= debt ? marketDebt[id] - debt : 0;

        MarketTypes.Outcome o = registry.outcomeOf(id);
        uint256 expected = o == MarketTypes.Outcome.Yes
            ? sy
            : (o == MarketTypes.Outcome.No ? sn : (sy + sn) / 2);

        uint256 payout;
        if (expected > 0) {
            uint256 before = collateral.balanceOf(address(this));
            core.redeem(id, sy, sn);
            payout = collateral.balanceOf(address(this)) - before;
        } else {
            (address y, address n) = core.tokensOf(id);
            if (sy > 0) IERC20(y).safeTransfer(user, sy);
            if (sn > 0) IERC20(n).safeTransfer(user, sn);
        }

        if (payout >= debt) {
            uint256 surplus = payout - debt;
            if (surplus > 0) collateral.safeTransfer(user, surplus);
        } else {
            badDebt += debt - payout;
        }
        emit SettledAfterResolution(id, user, payout, debt);
    }


    /// @inheritdoc Pausable
    function _pauseAdmin() internal view override returns (address) {
        return owner();
    }

    // ----------------------------------------------------------------- views

    function positionOf(bytes32 id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    /// @notice Deadline after which the loan is overdue: resolution minus buffer.
    function deadlineOf(bytes32 id) public view returns (uint64) {
        uint64 end = registry.getMarket(id).endTime;
        return end > deadlineBuffer ? end - deadlineBuffer : 0;
    }

    /// @notice Mark value of the pledged tokens, in collateral units.
    function positionValue(bytes32 id, address user) public view returns (uint256) {
        Position memory p = _positions[id][user];
        if (p.yesAmount == 0 && p.noAmount == 0) return 0;
        uint256 v;
        if (p.yesAmount > 0) {
            (uint256 py,) = oracle.priceOf(id, true);
            v += (p.yesAmount * py) / ONE;
        }
        if (p.noAmount > 0) {
            (uint256 pn,) = oracle.priceOf(id, false);
            v += (p.noAmount * pn) / ONE;
        }
        return v;
    }

    function borrowLimit(bytes32 id, address user) public view returns (uint256) {
        return (positionValue(id, user) * ltvBps) / BPS;
    }

    function liquidationLimit(bytes32 id, address user) public view returns (uint256) {
        return (positionValue(id, user) * liqThresholdBps) / BPS;
    }

    /// @notice Below 10000 the position is liquidatable on health grounds.
    function healthBps(bytes32 id, address user) public view returns (uint256) {
        uint256 debt = debtOf(id, user);
        if (debt == 0) return type(uint256).max;
        return (liquidationLimit(id, user) * BPS) / debt;
    }

    function debtOf(bytes32 id, address user) public view returns (uint256) {
        Position memory p = _positions[id][user];
        if (p.principal == 0) return 0;
        uint256 t = _accrualCutoff(id);
        if (t <= p.accrualFrom) return p.principal;
        return p.principal + (p.principal * rateBps * (t - p.accrualFrom)) / (YEAR * BPS);
    }

    function availableToBorrow(bytes32 id, address user) external view returns (uint256) {
        if (registry.isResolved(id)) return 0;
        if (block.timestamp >= deadlineOf(id)) return 0;
        uint256 limit = borrowLimit(id, user);
        uint256 debt = debtOf(id, user);
        if (debt >= limit) return 0;
        uint256 headroom = limit - debt;
        uint256 perMarket = maxDebtPerMarket > marketDebt[id]
            ? maxDebtPerMarket - marketDebt[id] : 0;
        uint256 facility = facilityCap > totalPrincipal ? facilityCap - totalPrincipal : 0;
        uint256 liquid = collateral.balanceOf(address(this));
        if (headroom > perMarket) headroom = perMarket;
        if (headroom > facility) headroom = facility;
        if (headroom > liquid) headroom = liquid;
        return headroom;
    }

    // -------------------------------------------------------------- internal

    /// @dev Interest stops at the deadline, so overdue debt cannot inflate while
    ///      liquidators work through the queue.
    function _accrualCutoff(bytes32 id) internal view returns (uint64) {
        uint64 dl = deadlineOf(id);
        return uint64(block.timestamp) < dl ? uint64(block.timestamp) : dl;
    }

    /// @dev Must use the same cutoff as debtOf, otherwise state and view
    ///      disagree once the deadline passes and the real debt silently
    ///      exceeds the quoted one.
    function _capitalise(bytes32 id, Position storage p) internal {
        if (p.principal != 0) {
            uint64 nowT = _accrualCutoff(id);
            if (nowT > p.accrualFrom) {
                uint256 i = (p.principal * rateBps * (nowT - p.accrualFrom)) / (YEAR * BPS);
                if (i != 0) {
                    p.principal += i;
                    p.interestOwed += i;
                    totalPrincipal += i;
                }
            }
        }
        p.accrualFrom = uint64(block.timestamp);
    }

    function _repayFor(bytes32 id, address payer, address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        Position storage p = _positions[id][user];
        if (p.principal == 0) revert NothingBorrowed();
        _capitalise(id, p);
        // uint256 max means whatever the debt is at execution time. Repaying a
        // figure read earlier always leaves dust, which strands the collateral.
        if (amount == type(uint256).max) amount = p.principal;
        if (amount > p.principal) revert RepayExceedsDebt(amount, p.principal);

        collateral.safeTransferFrom(payer, address(this), amount);
        uint256 payInterest = amount < p.interestOwed ? amount : p.interestOwed;
        p.interestOwed -= payInterest;
        accruedRevenue += payInterest;

        p.principal -= amount;
        totalPrincipal = totalPrincipal >= amount ? totalPrincipal - amount : 0;
        marketDebt[id] = marketDebt[id] >= amount ? marketDebt[id] - amount : 0;
        emit Repaid(id, user, amount, p.principal);
    }

    /// @dev Convert a target seize value into token amounts, YES first then NO.
    function _seizeFor(bytes32 id, Position storage p, uint256 targetValue)
        internal
        view
        returns (uint256 sy, uint256 sn, uint256 usedValue)
    {
        uint256 remaining = targetValue;
        if (p.yesAmount > 0 && remaining > 0) {
            (uint256 py,) = oracle.priceOf(id, true);
            if (py > 0) {
                uint256 want = (remaining * ONE) / py;
                sy = want > p.yesAmount ? p.yesAmount : want;
                uint256 v = (sy * py) / ONE;
                usedValue += v;
                remaining = remaining > v ? remaining - v : 0;
            }
        }
        if (p.noAmount > 0 && remaining > 0) {
            (uint256 pn,) = oracle.priceOf(id, false);
            if (pn > 0) {
                uint256 want = (remaining * ONE) / pn;
                sn = want > p.noAmount ? p.noAmount : want;
                uint256 v = (sn * pn) / ONE;
                usedValue += v;
            }
        }
    }
}
