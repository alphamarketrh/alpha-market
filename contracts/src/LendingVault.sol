// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AlphaMarketCore} from "./AlphaMarketCore.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {InterestModel} from "./InterestModel.sol";
import {Pausable} from "./Pausable.sol";
import {MarketTypes} from "./types/MarketTypes.sol";

/// @title LendingVault
/// @notice Lends against a hedged prediction position, funded by anyone.
///
/// @dev THE FLOOR IS PROVEN, NOT PRICED
///      A binary market has three terminal states. Enumerate them for a holder
///      of Y yes shares and N no shares:
///
///        Yes      redeems Y
///        No       redeems N
///        Invalid  redeems (Y + N) / 2
///
///      Every row is at least min(Y, N). Cap the debt below that and the
///      position repays itself out of redemption proceeds whatever happens.
///      No price is read, no liquidation exists, and bad debt is arithmetic
///      rather than unlikely. Pledge one side alone and min is zero, so the
///      vault lends nothing, by design.
///
/// @dev WHY THE RATE MOVES, AND WHY ITS CEILING IS PART OF THE PROOF
///      A fixed rate cannot defend the last of the liquidity: a depositor who
///      wants out waits on a borrower with no reason to hurry. So the rate
///      follows utilisation.
///
///      That breaks the proof above unless the borrow limit reserves interest
///      at the highest rate the model can ever return, not the rate in force
///      when the loan is drawn. It does. That is also why this vault should be
///      given an interest model with a low ceiling: it carries no liquidation
///      risk and never needs a punitive rate, and every point of ceiling costs
///      borrowing power on long-dated markets. Measured against a ceiling of
///      30%, a ninety day market still lends at 88% of its floor; at 200% it
///      would lend 66%.
///
/// @dev INTEREST IS AN INDEX, NOT A STORED RATE
///      Charging a whole period at whatever rate happens to be current when
///      somebody looks is simply wrong. A global index grows with the rate
///      that applied at each moment, and a position records the index it last
///      saw. Interest still stops at the market deadline: a position nobody
///      settles must not grow past what its collateral can redeem. When one
///      window straddles that deadline the growth is apportioned by time
///      within the window, and then bounded by what the ceiling rate could
///      have produced over the same window, because the index compounds and
///      time-apportioning alone would overstate a long neglect.
contract LendingVault is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error BadParams();
    error MarketNotInitialized();
    error MarketResolvedAlready();
    error MarketNotResolved();
    error PastDeadline(uint64 deadline);
    error Undercollateralised(uint256 debt, uint256 limit);
    error NothingBorrowed();
    error NothingPledged();
    error RepayExceedsDebt(uint256 amount, uint256 debt);
    error MarketDebtCapped(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error WithdrawExceedsPledge();
    error AlreadySettled();

    struct Position {
        uint256 yesAmount;
        uint256 noAmount;
        uint256 principal;      // debt including capitalised interest
        uint256 interestOwed;   // the part of principal that is interest
        uint256 lastIndex;      // borrow index when interest was last folded in
        uint64 lastAccrual;     // and when
        bool settled;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant YEAR = 365 days;
    uint256 private constant RAY = 1e27;

    IERC20 public immutable asset;
    AlphaMarketCore public immutable core;
    MarketRegistry public immutable registry;

    /// @notice The highest rate this vault will ever charge, fixed at birth.
    /// @dev The proof that bad debt is impossible rests on reserving interest
    ///      at a known worst case. If that worst case could be raised later,
    ///      every loan drawn before the change would be under-reserved. So the
    ///      ceiling is immutable, and a model that would charge more is simply
    ///      clamped to it. Swapping the model can change the shape of the
    ///      curve, never its roof.
    uint256 public immutable rateCeilingBps;

    InterestModel public model;

    /// @notice Held back below the proven floor, in bps.
    uint256 public haircutBps;

    /// @notice Share of interest kept as reserve rather than paid to suppliers.
    uint256 public reserveBps;

    /// @notice Interest stops this long before a market resolves.
    uint64 public deadlineBuffer;

    /// @notice Ceiling on debt drawn against any single market.
    uint256 public maxDebtPerMarket;

    /// @notice Grows with accrued interest. Debt is measured against it.
    uint256 public borrowIndex;
    uint64 public lastAccrualAt;

    uint256 public totalPrincipal;
    uint256 public totalSupplied;
    uint256 public reserveBalance;

    mapping(bytes32 => mapping(address => Position)) private _positions;
    mapping(bytes32 => uint256) public marketDebt;
    mapping(address => uint256) public supplyShares;
    uint256 public totalShares;

    event ModelSet(address model);
    event ParamsSet(uint256 haircutBps, uint256 reserveBps, uint64 deadlineBuffer, uint256 maxDebtPerMarket);
    event Accrued(uint256 borrowIndex, uint256 interest, uint256 toReserve);
    event Deposited(address indexed who, uint256 amount, uint256 shares);
    event Withdrawn(address indexed who, uint256 amount, uint256 shares);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event Pledged(bytes32 indexed id, address indexed user, uint256 yesAmount, uint256 noAmount);
    event Unpledged(bytes32 indexed id, address indexed user, uint256 yesAmount, uint256 noAmount);
    event Borrowed(bytes32 indexed id, address indexed user, uint256 amount, uint256 principal);
    event Repaid(bytes32 indexed id, address indexed user, uint256 amount, uint256 principal);
    event Settled(bytes32 indexed id, address indexed user, uint256 payout, uint256 debtCleared);

    constructor(
        address core_,
        address model_,
        uint256 rateCeilingBps_,
        uint256 haircutBps_,
        uint256 reserveBps_,
        uint256 maxDebtPerMarket_
    ) Ownable(msg.sender) {
        if (core_ == address(0) || model_ == address(0)) revert ZeroAddress();
        if (haircutBps_ >= BPS || reserveBps_ >= BPS) revert BadParams();
        if (rateCeilingBps_ == 0 || rateCeilingBps_ > 20_000) revert BadParams();
        rateCeilingBps = rateCeilingBps_;

        core = AlphaMarketCore(core_);
        registry = MarketRegistry(address(AlphaMarketCore(core_).registry()));
        asset = IERC20(address(AlphaMarketCore(core_).collateral()));
        model = InterestModel(model_);

        haircutBps = haircutBps_;
        reserveBps = reserveBps_;
        deadlineBuffer = 1 hours;
        maxDebtPerMarket = maxDebtPerMarket_;

        borrowIndex = RAY;
        lastAccrualAt = uint64(block.timestamp);

        emit ModelSet(model_);
        emit ParamsSet(haircutBps_, reserveBps_, deadlineBuffer, maxDebtPerMarket_);
    }

    /// @inheritdoc Pausable
    function _pauseAdmin() internal view override returns (address) {
        return owner();
    }

    // ----------------------------------------------------------------- admin

    function setModel(address model_) external onlyOwner {
        if (model_ == address(0)) revert ZeroAddress();
        _accrue();
        model = InterestModel(model_);
        emit ModelSet(model_);
    }

    function setParams(
        uint256 haircutBps_,
        uint256 reserveBps_,
        uint64 deadlineBuffer_,
        uint256 maxDebtPerMarket_
    ) external onlyOwner {
        if (haircutBps_ >= BPS || reserveBps_ >= BPS || deadlineBuffer_ == 0) revert BadParams();
        _accrue();
        haircutBps = haircutBps_;
        reserveBps = reserveBps_;
        deadlineBuffer = deadlineBuffer_;
        maxDebtPerMarket = maxDebtPerMarket_;
        emit ParamsSet(haircutBps_, reserveBps_, deadlineBuffer_, maxDebtPerMarket_);
    }

    /// @notice Take the reserve. Never touches deposits or their interest.
    function withdrawReserve(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _accrue();
        if (amount > reserveBalance) revert InsufficientLiquidity(amount, reserveBalance);
        reserveBalance -= amount;
        asset.safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    // ------------------------------------------------------------- supplying

    /// @notice Supply the lending asset and earn the borrow rate, less reserve.
    /// @dev Shares rather than balances, so interest accrues to holders without
    ///      touching every account.
    function deposit(uint256 amount) external nonReentrant whenEntryOpen {
        if (amount == 0) revert ZeroAmount();
        _accrue();

        uint256 shares = totalShares == 0 || totalSupplied == 0
            ? amount
            : (amount * totalShares) / totalSupplied;
        if (shares == 0) revert ZeroAmount();

        asset.safeTransferFrom(msg.sender, address(this), amount);
        supplyShares[msg.sender] += shares;
        totalShares += shares;
        totalSupplied += amount;
        emit Deposited(msg.sender, amount, shares);
    }

    /// @notice Withdraw supplied funds and the interest they earned.
    /// @dev Bounded by idle liquidity. Money that is lent out cannot be
    ///      withdrawn until it is repaid, which is what the rising rate near
    ///      full utilisation is for.
    function withdraw(uint256 amount) external nonReentrant {
        _accrue();
        uint256 owed = balanceOfSupplier(msg.sender);
        if (amount == type(uint256).max) amount = owed;
        if (amount == 0) revert ZeroAmount();
        if (amount > owed) revert InsufficientLiquidity(amount, owed);

        uint256 idle = availableLiquidity();
        if (amount > idle) revert InsufficientLiquidity(amount, idle);

        // Round shares up so a withdrawal never leaves dust that lets the last
        // supplier claim more than they put in.
        uint256 shares = (amount * totalShares + totalSupplied - 1) / totalSupplied;
        if (shares > supplyShares[msg.sender]) shares = supplyShares[msg.sender];

        supplyShares[msg.sender] -= shares;
        totalShares -= shares;
        totalSupplied -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, shares);
    }

    // ------------------------------------------------------------- borrowing

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
        if (p.settled) revert AlreadySettled();
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

    /// @dev Withdrawal is judged against the static limit, not one that decays
    ///      with time. A limit that shrank as the deadline approached would
    ///      lock a perfectly healthy position out of its own collateral.
    function unpledge(bytes32 id, uint256 yesAmount, uint256 noAmount) external nonReentrant {
        Position storage p = _positions[id][msg.sender];
        if (yesAmount > p.yesAmount || noAmount > p.noAmount) revert WithdrawExceedsPledge();

        _accrue();
        _capitalise(id, p);

        p.yesAmount -= yesAmount;
        p.noAmount -= noAmount;
        if (p.principal > 0) {
            uint256 lim = staticLimit(id, msg.sender);
            if (p.principal > lim) revert Undercollateralised(p.principal, lim);
        }

        (address y, address n) = core.tokensOf(id);
        if (yesAmount > 0) IERC20(y).safeTransfer(msg.sender, yesAmount);
        if (noAmount > 0) IERC20(n).safeTransfer(msg.sender, noAmount);
        emit Unpledged(id, msg.sender, yesAmount, noAmount);
    }

    function borrow(bytes32 id, uint256 amount) external nonReentrant whenEntryOpen {
        if (amount == 0) revert ZeroAmount();
        if (registry.isResolved(id)) revert MarketResolvedAlready();
        uint64 dl = deadlineOf(id);
        if (block.timestamp >= dl) revert PastDeadline(dl);

        _accrue();
        Position storage p = _positions[id][msg.sender];
        if (p.settled) revert AlreadySettled();
        _capitalise(id, p);

        p.principal += amount;
        uint256 lim = borrowLimit(id, msg.sender);
        if (p.principal > lim) revert Undercollateralised(p.principal, lim);

        marketDebt[id] += amount;
        if (marketDebt[id] > maxDebtPerMarket) {
            revert MarketDebtCapped(amount, maxDebtPerMarket - (marketDebt[id] - amount));
        }
        totalPrincipal += amount;

        uint256 idle = availableLiquidity();
        if (amount > idle) revert InsufficientLiquidity(amount, idle);

        asset.safeTransfer(msg.sender, amount);
        emit Borrowed(id, msg.sender, amount, p.principal);
    }

    /// @dev uint256 max means whatever the debt is when this lands. Repaying a
    ///      figure read a moment earlier always leaves dust, and dust strands
    ///      the collateral behind it.
    function repay(bytes32 id, uint256 amount) external nonReentrant {
        _accrue();
        Position storage p = _positions[id][msg.sender];
        if (p.principal == 0) revert NothingBorrowed();
        _capitalise(id, p);

        if (amount == type(uint256).max) amount = p.principal;
        if (amount == 0) revert ZeroAmount();
        if (amount > p.principal) revert RepayExceedsDebt(amount, p.principal);

        asset.safeTransferFrom(msg.sender, address(this), amount);
        _bookRepayment(id, p, amount);
        emit Repaid(id, msg.sender, amount, p.principal);
    }

    /// @notice Redeem a settled position, clear the debt from the proceeds and
    ///         hand back the rest. Callable by anyone.
    /// @dev This is where the proof pays off: the redemption is at least the
    ///      floor, the debt was capped below the floor, so the proceeds always
    ///      cover it. There is no liquidation because there is nothing to
    ///      liquidate.
    function settle(bytes32 id, address user) external nonReentrant {
        if (!registry.isResolved(id)) revert MarketNotResolved();
        Position storage p = _positions[id][user];
        if (p.settled) revert AlreadySettled();
        if (p.yesAmount == 0 && p.noAmount == 0) revert NothingPledged();

        _accrue();
        _capitalise(id, p);

        uint256 sy = p.yesAmount;
        uint256 sn = p.noAmount;
        p.yesAmount = 0;
        p.noAmount = 0;
        p.settled = true;

        uint256 before = asset.balanceOf(address(this));
        core.redeem(id, sy, sn);
        uint256 payout = asset.balanceOf(address(this)) - before;

        uint256 debt = p.principal;
        uint256 cleared = payout < debt ? payout : debt;
        if (cleared > 0) _bookRepayment(id, p, cleared);

        uint256 back = payout - cleared;
        if (back > 0) asset.safeTransfer(user, back);
        emit Settled(id, user, back, cleared);
    }

    // ----------------------------------------------------------------- views

    function positionOf(bytes32 id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    /// @notice Worst-case redemption value of the pledge, proven by enumeration.
    function floorOf(bytes32 id, address user) public view returns (uint256) {
        Position memory p = _positions[id][user];
        return p.yesAmount < p.noAmount ? p.yesAmount : p.noAmount;
    }

    /// @notice The floor less the haircut. Used to judge withdrawals.
    function staticLimit(bytes32 id, address user) public view returns (uint256) {
        return (floorOf(id, user) * (BPS - haircutBps)) / BPS;
    }

    /// @notice What may be owed at any point in this loan life.
    /// @dev Reserves interest to the deadline at the model CEILING rate, not
    ///      the rate in force now. The rate can rise afterwards, and only a
    ///      reservation at the ceiling keeps the debt under the floor whatever
    ///      it does. This is the whole reason bad debt stays impossible.
    function borrowLimit(bytes32 id, address user) public view returns (uint256) {
        uint256 lim = staticLimit(id, user);
        if (lim == 0) return 0;
        uint64 dl = deadlineOf(id);
        if (block.timestamp >= dl) return 0;

        uint256 remaining = dl - block.timestamp;
        // Solving P * (YEAR*BPS + ceiling*remaining) / (YEAR*BPS) <= lim.
        return (lim * YEAR * BPS) / (YEAR * BPS + rateCeilingBps * remaining);
    }

    function debtOf(bytes32 id, address user) public view returns (uint256) {
        Position memory p = _positions[id][user];
        if (p.principal == 0) return 0;
        return p.principal + _pendingInterest(id, p, currentIndex());
    }

    function availableToBorrow(bytes32 id, address user) external view returns (uint256) {
        if (registry.isResolved(id)) return 0;
        if (block.timestamp >= deadlineOf(id)) return 0;
        uint256 lim = borrowLimit(id, user);
        uint256 debt = debtOf(id, user);
        if (debt >= lim) return 0;
        uint256 room = lim - debt;
        uint256 perMarket = maxDebtPerMarket > marketDebt[id] ? maxDebtPerMarket - marketDebt[id] : 0;
        if (room > perMarket) room = perMarket;
        uint256 idle = availableLiquidity();
        if (room > idle) room = idle;
        return room;
    }

    /// @notice What a supplier could take out right now, interest included.
    function balanceOfSupplier(address who) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (supplyShares[who] * suppliedWithInterest()) / totalShares;
    }

    /// @notice Total owed to suppliers, including interest not yet folded in.
    function suppliedWithInterest() public view returns (uint256) {
        (, uint256 toSuppliers, ) = _pendingAccrual();
        return totalSupplied + toSuppliers;
    }

    /// @notice Asset sitting here rather than lent out.
    function availableLiquidity() public view returns (uint256) {
        uint256 bal = asset.balanceOf(address(this));
        uint256 spoken = reserveBalance;
        return bal > spoken ? bal - spoken : 0;
    }

    function utilisation() public view returns (uint256) {
        return model.utilisation(totalPrincipal, totalSupplied);
    }

    function borrowRate() public view returns (uint256) {
        uint256 r = model.borrowRate(totalPrincipal, totalSupplied);
        return r > rateCeilingBps ? rateCeilingBps : r;
    }

    function supplyRate() external view returns (uint256) {
        return model.supplyRate(totalPrincipal, totalSupplied, reserveBps);
    }

    function deadlineOf(bytes32 id) public view returns (uint64) {
        uint64 end = registry.getMarket(id).endTime;
        return end > deadlineBuffer ? end - deadlineBuffer : 0;
    }

    /// @notice The borrow index including growth not yet written to storage.
    function currentIndex() public view returns (uint256) {
        (uint256 idx, , ) = _pendingAccrual();
        return idx;
    }

    // -------------------------------------------------------------- internal

    /// @dev The index and the interest it implies, without writing anything.
    function _pendingAccrual()
        internal
        view
        returns (uint256 idx, uint256 toSuppliers, uint256 toReserve)
    {
        idx = borrowIndex;
        uint64 nowT = uint64(block.timestamp);
        if (nowT <= lastAccrualAt || totalPrincipal == 0) return (idx, 0, 0);

        uint256 rate = model.borrowRate(totalPrincipal, totalSupplied);
        // Never charge above the roof the reservations were computed against.
        if (rate > rateCeilingBps) rate = rateCeilingBps;
        uint256 elapsed = nowT - lastAccrualAt;
        uint256 growth = (idx * rate * elapsed) / (YEAR * BPS);
        idx += growth;

        uint256 interest = (totalPrincipal * rate * elapsed) / (YEAR * BPS);
        toReserve = (interest * reserveBps) / BPS;
        toSuppliers = interest - toReserve;
    }

    /// @dev Advance the index. Every entry point calls this first, so the rate
    ///      applied to a window is the rate that was in force during it.
    function _accrue() internal {
        (uint256 idx, uint256 toSuppliers, uint256 toReserve) = _pendingAccrual();
        if (idx == borrowIndex && toSuppliers == 0 && toReserve == 0) {
            lastAccrualAt = uint64(block.timestamp);
            return;
        }
        borrowIndex = idx;
        totalSupplied += toSuppliers;
        reserveBalance += toReserve;
        totalPrincipal += toSuppliers + toReserve;
        lastAccrualAt = uint64(block.timestamp);
        emit Accrued(idx, toSuppliers + toReserve, toReserve);
    }

    /// @dev Interest a position owes but has not yet had folded into principal.
    ///
    ///      Growth stops at the market deadline. When the window since the last
    ///      touch straddles that deadline the growth is apportioned by time,
    ///      then bounded by what the ceiling rate could have produced over the
    ///      same window. The bound matters because the index compounds: a
    ///      position left alone through many deadlines would otherwise be
    ///      charged for growth that happened long after its own.
    function _pendingInterest(bytes32 id, Position memory p, uint256 idx)
        internal
        view
        returns (uint256)
    {
        if (p.principal == 0 || p.lastIndex == 0 || idx <= p.lastIndex) return 0;

        uint64 dl = deadlineOf(id);
        if (p.lastAccrual >= dl) return 0;

        uint256 full = (p.principal * (idx - p.lastIndex)) / p.lastIndex;
        uint64 nowT = uint64(block.timestamp);
        if (nowT > dl) {
            uint256 window = nowT - p.lastAccrual;
            if (window == 0) return 0;
            full = (full * (dl - p.lastAccrual)) / window;
        }

        uint256 cap = (p.principal * rateCeilingBps * (dl - p.lastAccrual))
            / (YEAR * BPS);
        return full < cap ? full : cap;
    }

    /// @dev Fold pending interest into principal so stored state matches debtOf.
    function _capitalise(bytes32 id, Position storage p) internal {
        uint256 idx = borrowIndex;
        if (p.lastIndex == 0) {
            p.lastIndex = idx;
            p.lastAccrual = uint64(block.timestamp);
            return;
        }
        uint256 owed = _pendingInterest(id, p, idx);
        if (owed > 0) {
            p.principal += owed;
            p.interestOwed += owed;
        }
        p.lastIndex = idx;
        p.lastAccrual = uint64(block.timestamp);
    }

    /// @dev Apply a repayment to principal and the facility totals.
    function _bookRepayment(bytes32 id, Position storage p, uint256 amount) internal {
        uint256 payInterest = amount < p.interestOwed ? amount : p.interestOwed;
        p.interestOwed -= payInterest;
        p.principal -= amount;
        totalPrincipal = totalPrincipal >= amount ? totalPrincipal - amount : 0;
        marketDebt[id] = marketDebt[id] >= amount ? marketDebt[id] - amount : 0;
    }
}
