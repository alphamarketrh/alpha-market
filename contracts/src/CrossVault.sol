// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AlphaMarketCore} from "./AlphaMarketCore.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {IPositionOracle} from "./interfaces/IPositionOracle.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {Pausable} from "./Pausable.sol";
import {MarketTypes} from "./types/MarketTypes.sol";

/// @title CrossVault
/// @notice Borrow one asset against a prediction position denominated in
///         another. A YES-TSLA position secures an aUSD loan, so a holder
///         whose wealth is in equities can borrow dollars without selling
///         either the stock or the bet.
///
/// @dev ONE VAULT PER DIRECTION, ON PURPOSE
///      This contract is deployed once per (collateral core, debt asset) pair.
///      A single vault serving every combination would be tidier and would also
///      mean one bug, one bad price or one exhausted facility takes down every
///      pair at once. Separate instances keep a TSLA problem away from an AMD
///      loan, each with its own cap, its own funding and its own pause.
///
/// @dev TWO PRICES MOVE, SO THE HAIRCUT IS LARGER
///      Collateral value is the product of two independent prices: the odds of
///      the event and the value of the settlement asset. A thirty percent fall
///      in each leaves only forty nine percent of the value, so a joint move
///      compounds in a way a single-price vault never sees. LTV is therefore
///      15% against a 35% liquidation threshold: a fully drawn loan survives a
///      57% fall in combined value, roughly 35% on each price at once.
///      DirectionalVault, with one price, uses 30% and 50%.
///
/// @dev THE DEADLINE IS WHAT MAKES THIS SAFE AT ALL
///      At resolution an outcome token jumps to zero or one in a single block,
///      and no liquidator can act inside that move. Every loan therefore has a
///      hard deadline before resolution, after which liquidation opens whatever
///      the health reads, and interest stops accruing. Exposure is bounded by
///      the clock rather than by hope.
contract CrossVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error BadParams();
    error MarketNotInitialized();
    error MarketResolvedAlready();
    error MarketNotResolved();
    error PastDeadline(uint64 deadline);
    error BeforeDeadline(uint64 deadline);
    error Undercollateralised(uint256 debt, uint256 limit);
    error PositionHealthy(uint256 healthBps);
    error NothingBorrowed();
    error NothingPledged();
    error RepayExceedsDebt(uint256 amount, uint256 debt);
    error MarketDebtCapped(uint256 requested, uint256 available);
    error FacilityExhausted();
    error InsufficientLiquidity();
    error SeizeExceedsPledge();
    error InsufficientEscrow();

    struct Position {
        uint256 yesAmount;
        uint256 noAmount;
        uint256 principal;
        uint256 interestOwed;
        uint64 accrualFrom;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 private constant ODDS_ONE = 1e6;      // position oracle scale
    uint256 private constant PRICE_SCALE = 1e8;   // equity oracle scale

    /// @notice The core whose outcome tokens are accepted as collateral.
    AlphaMarketCore public immutable core;
    MarketRegistry public immutable registry;

    /// @notice The asset this vault lends. Different from the core collateral.
    IERC20 public immutable debtAsset;
    uint8 public immutable debtDecimals;

    /// @notice The settlement asset of the core, priced against the debt asset.
    address public immutable settlementToken;
    uint8 public immutable settlementDecimals;

    /// @notice Odds of each outcome, 0 to 1e6.
    IPositionOracle public positionOracle;

    /// @notice Price of the settlement asset, 8 decimals, quoted in USD.
    IPriceOracle public priceOracle;

    uint16 public ltvBps;
    uint16 public liqThresholdBps;
    uint16 public liqBonusBps;
    uint16 public closeFactorBps;
    uint256 public rateBps;
    uint256 public facilityCap;
    uint64 public deadlineBuffer;
    uint256 public maxDebtPerMarket;

    uint256 public totalPrincipal;
    uint256 public accruedRevenue;
    uint256 public badDebt;

    mapping(bytes32 => mapping(address => Position)) private _positions;
    mapping(bytes32 => uint256) public marketDebt;
    mapping(bytes32 => uint256) public absorbedYes;
    mapping(bytes32 => uint256) public absorbedNo;
    uint256 public recovered;

    event OraclesSet(address positionOracle, address priceOracle);
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

    constructor(
        address core_,
        address debtAsset_,
        uint8 debtDecimals_,
        uint8 settlementDecimals_,
        address positionOracle_,
        address priceOracle_
    ) Ownable(msg.sender) {
        if (core_ == address(0) || debtAsset_ == address(0)) revert ZeroAddress();
        if (positionOracle_ == address(0) || priceOracle_ == address(0)) revert ZeroAddress();

        core = AlphaMarketCore(core_);
        registry = MarketRegistry(address(AlphaMarketCore(core_).registry()));
        settlementToken = address(AlphaMarketCore(core_).collateral());
        if (settlementToken == debtAsset_) revert BadParams();

        debtAsset = IERC20(debtAsset_);
        // Decimals are supplied rather than read. Robinhood stock tokens are
        // beacon proxies that a local simulator cannot resolve, so any call to
        // them reverts before a deployment is broadcast.
        debtDecimals = debtDecimals_;
        settlementDecimals = settlementDecimals_;

        positionOracle = IPositionOracle(positionOracle_);
        priceOracle = IPriceOracle(priceOracle_);

        ltvBps = 1500;
        liqThresholdBps = 3500;
        liqBonusBps = 1000;
        closeFactorBps = 5000;
        rateBps = 1500;
        facilityCap = 0;
        deadlineBuffer = 1 hours;
        maxDebtPerMarket = 0;

        emit OraclesSet(positionOracle_, priceOracle_);
        emit ParamsSet(ltvBps, liqThresholdBps, liqBonusBps, closeFactorBps);
        emit RiskSet(rateBps, facilityCap, deadlineBuffer, maxDebtPerMarket);
    }

    /// @inheritdoc Pausable
    function _pauseAdmin() internal view override returns (address) {
        return owner();
    }

    // ----------------------------------------------------------------- admin

    function setOracles(address positionOracle_, address priceOracle_) external onlyOwner {
        if (positionOracle_ == address(0) || priceOracle_ == address(0)) revert ZeroAddress();
        positionOracle = IPositionOracle(positionOracle_);
        priceOracle = IPriceOracle(priceOracle_);
        emit OraclesSet(positionOracle_, priceOracle_);
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
        debtAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(amount);
    }

    function defund(uint256 amount) external onlyOwner {
        debtAsset.safeTransfer(msg.sender, amount);
        accruedRevenue = amount >= accruedRevenue ? 0 : accruedRevenue - amount;
        emit Defunded(amount);
    }

    // ------------------------------------------------------------- positions

    function pledge(bytes32 id, uint256 yesAmount, uint256 noAmount)
        external
        nonReentrant
        whenEntryOpen
    {
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
        if (amount > debtAsset.balanceOf(address(this))) revert InsufficientLiquidity();

        debtAsset.safeTransfer(msg.sender, amount);
        emit Borrowed(id, msg.sender, amount, p.principal);
    }

    function repay(bytes32 id, uint256 amount) external nonReentrant {
        _repayFor(id, msg.sender, msg.sender, amount);
    }

    // ------------------------------------------------------------ liquidation

    function liquidate(bytes32 id, address user, uint256 repayAmount) external nonReentrant {
        Position storage p = _positions[id][user];
        _capitalise(id, p);
        if (p.principal == 0) revert NothingBorrowed();

        uint64 dl = deadlineOf(id);
        bool overdue = block.timestamp >= dl;
        // Health is only consulted before the deadline. Past it the trigger is
        // time, and reading a price that may be stale would revert exactly when
        // closing the position matters most.
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

    /// @notice Redeem a pledge after resolution, clear the debt, return the rest.
    /// @dev The collateral redeems into the settlement asset, not the debt
    ///      asset, so the proceeds are handed to the user and the debt stays
    ///      outstanding rather than being silently netted at an unquoted rate.
    ///      Converting one for the other is a trade, and this contract does not
    ///      make trades on a user behalf.
    function settleResolved(bytes32 id, address user) external nonReentrant {
        if (!registry.isResolved(id)) revert MarketNotResolved();
        Position storage p = _positions[id][user];
        if (p.yesAmount == 0 && p.noAmount == 0) revert NothingPledged();

        _capitalise(id, p);
        uint256 sy = p.yesAmount;
        uint256 sn = p.noAmount;
        p.yesAmount = 0;
        p.noAmount = 0;

        MarketTypes.Outcome o = registry.outcomeOf(id);
        uint256 expected = o == MarketTypes.Outcome.Yes
            ? sy
            : (o == MarketTypes.Outcome.No ? sn : (sy + sn) / 2);

        uint256 payout;
        if (expected > 0) {
            uint256 before = IERC20(settlementToken).balanceOf(address(this));
            core.redeem(id, sy, sn);
            payout = IERC20(settlementToken).balanceOf(address(this)) - before;
            IERC20(settlementToken).safeTransfer(user, payout);
        } else {
            (address y, address n) = core.tokensOf(id);
            if (sy > 0) IERC20(y).safeTransfer(user, sy);
            if (sn > 0) IERC20(n).safeTransfer(user, sn);
        }
        emit SettledAfterResolution(id, user, payout, p.principal);
    }

    /// @notice Take an overdue position nobody liquidated, write the debt off
    ///         and hold the tokens to resolution.
    ///
    /// @dev THIS IS THE ONLY EXIT THAT NEEDS NO PRICE, AND THAT IS THE POINT.
    ///      liquidate() must value the collateral to decide how much to seize,
    ///      so a dead or stale equity feed makes it revert. Past the deadline
    ///      that would leave the position uncloseable exactly when resolution
    ///      is imminent. absorb touches no oracle at all: it hands the vault
    ///      the tokens and cancels the loan, and the outcome is settled later
    ///      by redemption rather than by a quote.
    ///
    ///      It is not charity. A position written off at a debt well below its
    ///      expected redemption is usually recovered in full by sweepAbsorbed.
    ///      The write-off is recorded as bad debt so the loss is visible until
    ///      it is actually recovered.
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
    /// @dev The proceeds arrive in the settlement asset, not the debt asset, so
    ///      they are held rather than netted against the write-off. Converting
    ///      them is a trade, and this contract does not trade. badDebt stays on
    ///      the books until the owner sells the proceeds and refunds the vault.
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
            uint256 before = IERC20(settlementToken).balanceOf(address(this));
            core.redeem(id, sy, sn);
            payout = IERC20(settlementToken).balanceOf(address(this)) - before;
        }
        recovered += payout;
        emit Swept(id, payout, badDebt);
    }

    // ----------------------------------------------------------------- views

    function positionOf(bytes32 id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    function deadlineOf(bytes32 id) public view returns (uint64) {
        uint64 end = registry.getMarket(id).endTime;
        return end > deadlineBuffer ? end - deadlineBuffer : 0;
    }

    /// @notice Collateral value in debt-asset units.
    /// @dev Two conversions in one: outcome tokens to settlement units by the
    ///      odds, then settlement units to debt units by the equity price. Both
    ///      round down, so the vault never overstates what it holds.
    function positionValue(bytes32 id, address user) public view returns (uint256) {
        Position memory p = _positions[id][user];
        if (p.yesAmount == 0 && p.noAmount == 0) return 0;

        uint256 inSettlement;
        if (p.yesAmount > 0) {
            (uint256 py,) = positionOracle.priceOf(id, true);
            inSettlement += (p.yesAmount * py) / ODDS_ONE;
        }
        if (p.noAmount > 0) {
            (uint256 pn,) = positionOracle.priceOf(id, false);
            inSettlement += (p.noAmount * pn) / ODDS_ONE;
        }
        if (inSettlement == 0) return 0;

        (uint256 px,) = priceOracle.getPrice(settlementToken);
        return (inSettlement * px * (10 ** debtDecimals))
            / (PRICE_SCALE * (10 ** settlementDecimals));
    }

    function borrowLimit(bytes32 id, address user) public view returns (uint256) {
        return (positionValue(id, user) * ltvBps) / BPS;
    }

    function liquidationLimit(bytes32 id, address user) public view returns (uint256) {
        return (positionValue(id, user) * liqThresholdBps) / BPS;
    }

    function healthBps(bytes32 id, address user) public view returns (uint256) {
        uint256 debt = debtOf(id, user);
        if (debt == 0) return type(uint256).max;
        return (liquidationLimit(id, user) * BPS) / debt;
    }

    function debtOf(bytes32 id, address user) public view returns (uint256) {
        Position memory p = _positions[id][user];
        if (p.principal == 0) return 0;
        uint64 t = _accrualCutoff(id);
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
        uint256 liquid = debtAsset.balanceOf(address(this));
        if (headroom > perMarket) headroom = perMarket;
        if (headroom > facility) headroom = facility;
        if (headroom > liquid) headroom = liquid;
        return headroom;
    }

    // -------------------------------------------------------------- internal

    function _accrualCutoff(bytes32 id) internal view returns (uint64) {
        uint64 dl = deadlineOf(id);
        return uint64(block.timestamp) < dl ? uint64(block.timestamp) : dl;
    }

    /// @dev Uses the same cutoff as debtOf, so stored and quoted debt agree.
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

        debtAsset.safeTransferFrom(payer, address(this), amount);
        uint256 payInterest = amount < p.interestOwed ? amount : p.interestOwed;
        p.interestOwed -= payInterest;
        accruedRevenue += payInterest;

        p.principal -= amount;
        totalPrincipal = totalPrincipal >= amount ? totalPrincipal - amount : 0;
        marketDebt[id] = marketDebt[id] >= amount ? marketDebt[id] - amount : 0;
        emit Repaid(id, user, amount, p.principal);
    }

    /// @dev Convert a seize value in debt units into outcome token amounts.
    ///
    ///      An earlier version priced ONE BASE UNIT of collateral and divided
    ///      by it. With an 18 decimal collateral and a 6 decimal debt asset
    ///      that unit price floors to zero, so the division reverted and no
    ///      liquidation could ever complete. Working from the value down to the
    ///      amount avoids the intermediate entirely and floors in the vault
    ///      favour: the seizure never exceeds the value it was asked for.
    function _seizeFor(bytes32 id, Position storage p, uint256 targetValue)
        internal
        view
        returns (uint256 sy, uint256 sn, uint256 usedValue)
    {
        (uint256 px,) = priceOracle.getPrice(settlementToken);
        if (px == 0) return (0, 0, 0);

        uint256 remaining = targetValue;
        if (p.yesAmount > 0 && remaining > 0) {
            (uint256 py,) = positionOracle.priceOf(id, true);
            uint256 want = _tokensForValue(remaining, py, px);
            sy = want > p.yesAmount ? p.yesAmount : want;
            uint256 v = _valueOfTokens(sy, py, px);
            usedValue += v;
            remaining = remaining > v ? remaining - v : 0;
        }
        if (p.noAmount > 0 && remaining > 0) {
            (uint256 pn,) = positionOracle.priceOf(id, false);
            uint256 want = _tokensForValue(remaining, pn, px);
            sn = want > p.noAmount ? p.noAmount : want;
            usedValue += _valueOfTokens(sn, pn, px);
        }
    }

    /// @dev How many collateral base units are worth `value` in debt units.
    function _tokensForValue(uint256 value, uint256 odds, uint256 equityPrice)
        internal
        view
        returns (uint256)
    {
        uint256 den = odds * equityPrice * (10 ** debtDecimals);
        if (den == 0) return 0;
        return (value * ODDS_ONE * PRICE_SCALE * (10 ** settlementDecimals)) / den;
    }

    /// @dev Debt-unit value of `amount` collateral base units.
    function _valueOfTokens(uint256 amount, uint256 odds, uint256 equityPrice)
        internal
        view
        returns (uint256)
    {
        return (amount * odds * equityPrice * (10 ** debtDecimals))
            / (ODDS_ONE * PRICE_SCALE * (10 ** settlementDecimals));
    }
}
