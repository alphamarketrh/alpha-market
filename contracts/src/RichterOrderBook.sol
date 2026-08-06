// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RichterCore} from "./RichterCore.sol";
import {Pausable} from "./Pausable.sol";

/// @title RichterOrderBook
/// @notice On-chain limit order book for Richter positions, which settle to a
///         fraction of a cap rather than to a side.
///
/// @dev WHY A SEPARATE BOOK RATHER THAN A PARAMETER
///      OrderBook holds `AlphaMarketCore public immutable core`, a concrete type
///      baked into bytecode with no setter, so it can never reach a pair minted
///      by RichterCore. Everything else here is the same book: the same three
///      ways to match, the same escrow rules, the same rounding.
///
/// @dev THE ONE REAL DIFFERENCE
///      OrderBook asks the registry whether a market is tradeable. A Richter
///      market is not resolved through the registry at all: two Chainlink rounds
///      decide it and RichterCore freezes the fraction. So this book asks the
///      core instead, and stops accepting orders the moment a market settles.
///      That is the same intent, read from the place that actually knows.
///
/// @dev BIG AND CALM, NOT YES AND NO
///      The pair invariant is identical, BIG plus CALM is always one unit, which
///      is what makes minting and merging work. Only the names differ, and the
///      code below keeps the original ones because the arithmetic does not care.
///
/// @dev WHY A BINARY MARKET NEEDS THREE WAYS TO MATCH, NOT ONE
///      An ordinary exchange only matches a buyer against a seller. Here YES
///      and NO always sum to one unit of collateral, which creates two more:
///
///      MINT   buy YES at 0.60 + buy NO at 0.45. Both sides bring cash, the
///             book splits one unit of collateral and hands out one YES and
///             one NO. Neither party had to own a token first.
///      MERGE  sell YES at 0.55 + sell NO at 0.40. Both sides bring tokens,
///             the book merges them back into collateral and pays each.
///      FILL   the ordinary case, cash against token.
///
///      MINT is what lets a brand new market trade from nothing. Without it a
///      fresh market is dead: nobody holds tokens, so nobody can sell, so
///      nobody can buy. That is the cold start problem, and it is solved by
///      arithmetic rather than by incentives.
///
/// @dev EVERY ORDER IS FULLY FUNDED WHEN PLACED
///      A buy escrows collateral, a sell escrows tokens. An order that cannot
///      be honoured is a lie told to everyone reading the book, so the book
///      never holds one.
///
/// @dev ROUNDING ALWAYS FAVOURS THE CONTRACT
///      Escrow rounds up, payouts round down. Sub-unit remainders accumulate in
///      the maker balance and are refunded on cancellation, never lost and
///      never conjured. The invariant is that collateral held is always at
///      least what outstanding orders and minted tokens can claim.
///
/// @dev WHAT TRANSPARENCY COSTS, STATED PLAINLY
///      A public book means a stale quote is visible to everyone, so fast
///      participants will pick off slow ones. Expiries and cheap cancellation
///      limit the damage; they do not remove it. Robinhood Chain runs an
///      Arbitrum sequencer with no public mempool, so the classic mempool
///      sandwich does not apply, but a latency race still does.
contract RichterOrderBook is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error BadPrice(uint64 price);
    error BadExpiry();
    error MarketNotTradeable(bytes32 id);
    error MarketNotInitialized(bytes32 id);
    error UnknownOrder(uint256 id);
    error NotMaker();
    error OrderInactive(uint256 id);
    error OrderExpired(uint256 id);
    error SelfTrade();
    error AmountExceedsRemaining(uint256 id, uint128 want, uint128 have);
    error WrongSide();
    error DifferentMarkets();
    error PricesDoNotCross(uint64 a, uint64 b);
    error FeeTooHigh();
    error InsufficientEscrow();

    /// @dev BuyYes and BuyNo escrow collateral. SellYes and SellNo escrow tokens.
    enum Side { BuyYes, SellYes, BuyNo, SellNo }

    struct Order {
        address maker;
        bytes32 marketId;
        Side side;
        uint64 price;        // 1 .. ONE-1, in millionths of one collateral unit
        uint64 expiry;
        uint128 amount;      // total outcome tokens the order is for
        uint128 filled;
        uint128 escrow;      // remaining escrowed, collateral for buys, tokens for sells
        bool cancelled;
    }

    uint256 public constant ONE = 1e6;

    IERC20 public immutable collateral;
    RichterCore public immutable core;

    /// @notice Taker fee in basis points, charged on the collateral leg.
    uint16 public feeBps;

    /// @notice Accrued fees, withdrawable by the owner.
    uint256 public feesAccrued;

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) private _orders;
    mapping(bytes32 => uint256[]) private _marketOrders;

    event OrderPlaced(
        uint256 indexed orderId, bytes32 indexed marketId, address indexed maker,
        Side side, uint64 price, uint128 amount, uint64 expiry
    );
    event OrderCancelled(uint256 indexed orderId, uint128 refunded);
    event OrderFilled(
        uint256 indexed orderId, address indexed taker, uint128 amount, uint256 collateralLeg
    );
    event Minted(
        uint256 indexed buyYesId, uint256 indexed buyNoId, address indexed matcher,
        uint128 amount, uint256 surplus
    );
    event Merged(
        uint256 indexed sellYesId, uint256 indexed sellNoId, address indexed matcher,
        uint128 amount, uint256 surplus
    );
    event Crossed(
        uint256 indexed buyId, uint256 indexed sellId, address indexed matcher,
        uint128 amount, uint256 surplus
    );
    event FeeSet(uint16 feeBps);
    event FeesWithdrawn(uint256 amount);

    constructor(address core_, uint16 feeBps_) Ownable(msg.sender) {
        if (core_ == address(0)) revert ZeroAddress();
        if (feeBps_ > 200) revert FeeTooHigh();
        core = RichterCore(core_);
        collateral = IERC20(address(RichterCore(core_).collateral()));
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    // ----------------------------------------------------------------- admin

    /// @dev Capped at 2 percent in code, not merely by policy.
    function setFee(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > 200) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    function withdrawFees(uint256 amount) external onlyOwner {
        if (amount > feesAccrued) revert ZeroAmount();
        feesAccrued -= amount;
        collateral.safeTransfer(msg.sender, amount);
        emit FeesWithdrawn(amount);
    }

    // ------------------------------------------------------------- placement

    /// @notice Place a fully funded limit order.
    /// @param price millionths of one collateral unit, strictly between 0 and ONE
    function placeOrder(
        bytes32 marketId, Side side, uint64 price, uint128 amount, uint64 expiry
    ) external nonReentrant whenEntryOpen returns (uint256 orderId) {
        if (amount == 0) revert ZeroAmount();
        if (price == 0 || price >= ONE) revert BadPrice(price);
        if (expiry <= block.timestamp) revert BadExpiry();
        // A settled market has a frozen fraction, so an order placed after it
        // would be a bet on a number already known. The core is asked rather
        // than a registry, because the registry never learns the result.
        if (core.isSettled(marketId)) revert MarketNotTradeable(marketId);
        (address y, address n) = core.tokensOf(marketId);
        if (y == address(0)) revert MarketNotInitialized(marketId);

        uint128 escrow;
        if (side == Side.BuyYes || side == Side.BuyNo) {
            // Escrow rounds up so a sequence of partial fills can never exhaust it.
            escrow = uint128(_ceilCost(amount, price));
            collateral.safeTransferFrom(msg.sender, address(this), escrow);
        } else {
            escrow = amount;
            address tok = (side == Side.SellYes) ? y : n;
            IERC20(tok).safeTransferFrom(msg.sender, address(this), amount);
        }

        orderId = nextOrderId++;
        _orders[orderId] = Order({
            maker: msg.sender, marketId: marketId, side: side, price: price,
            expiry: expiry, amount: amount, filled: 0, escrow: escrow, cancelled: false
        });
        _marketOrders[marketId].push(orderId);

        emit OrderPlaced(orderId, marketId, msg.sender, side, price, amount, expiry);
    }

    /// @notice Cancel and reclaim the unspent escrow.
    /// @dev Deliberately available even when the market is halted or resolved.
    ///      Trapping a maker funds because trading stopped would be its own
    ///      failure, and cancelling can never make the contract insolvent.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = _get(orderId);
        if (o.maker != msg.sender) revert NotMaker();
        if (o.cancelled) revert OrderInactive(orderId);
        o.cancelled = true;

        uint128 refund = o.escrow;
        o.escrow = 0;
        if (refund > 0) {
            if (o.side == Side.BuyYes || o.side == Side.BuyNo) {
                collateral.safeTransfer(o.maker, refund);
            } else {
                (address y, address n) = core.tokensOf(o.marketId);
                IERC20(o.side == Side.SellYes ? y : n).safeTransfer(o.maker, refund);
            }
        }
        emit OrderCancelled(orderId, refund);
    }

    // ------------------------------------------------------------------ fill

    /// @notice Take the other side of a resting order. Cash against token.
    /// @dev The taker names the order, so gas is bounded and no hidden priority
    ///      exists. There is no loop over a sorted book to grief.
    function fill(uint256 orderId, uint128 amount) external nonReentrant {
        Order storage o = _live(orderId);
        if (amount == 0) revert ZeroAmount();
        uint128 remaining = o.amount - o.filled;
        if (amount > remaining) revert AmountExceedsRemaining(orderId, amount, remaining);
        if (o.maker == msg.sender) revert SelfTrade();

        uint256 leg = _cost(amount, o.price);
        (address y, address n) = core.tokensOf(o.marketId);
        o.filled += amount;

        if (o.side == Side.BuyYes || o.side == Side.BuyNo) {
            // Maker wants tokens and has escrowed cash. Taker delivers tokens.
            address tok = (o.side == Side.BuyYes) ? y : n;
            o.escrow -= uint128(leg);
            IERC20(tok).safeTransferFrom(msg.sender, o.maker, amount);
            uint256 fee = (leg * feeBps) / 10_000;
            feesAccrued += fee;
            collateral.safeTransfer(msg.sender, leg - fee);
        } else {
            // Maker wants cash and has escrowed tokens. Taker delivers cash.
            address tok = (o.side == Side.SellYes) ? y : n;
            o.escrow -= amount;
            uint256 fee = (leg * feeBps) / 10_000;
            collateral.safeTransferFrom(msg.sender, address(this), leg + fee);
            feesAccrued += fee;
            collateral.safeTransfer(o.maker, leg);
            IERC20(tok).safeTransfer(msg.sender, amount);
        }
        emit OrderFilled(orderId, msg.sender, amount, leg);
    }

    // ----------------------------------------------------------------- match

    /// @notice Match two buy orders into freshly minted tokens.
    /// @dev This is what makes a new market tradeable from nothing. Both makers
    ///      bring cash; the book splits one unit of collateral per unit matched
    ///      and delivers one YES and one NO. Permissionless: anybody may match,
    ///      and the surplus between the two limit prices pays for the work.
    function matchMint(uint256 buyYesId, uint256 buyNoId, uint128 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        Order storage a = _live(buyYesId);
        Order storage b = _live(buyNoId);
        if (a.side != Side.BuyYes || b.side != Side.BuyNo) revert WrongSide();
        if (a.marketId != b.marketId) revert DifferentMarkets();
        if (a.maker == b.maker) revert SelfTrade();

        uint128 ra = a.amount - a.filled;
        uint128 rb = b.amount - b.filled;
        if (amount > ra) revert AmountExceedsRemaining(buyYesId, amount, ra);
        if (amount > rb) revert AmountExceedsRemaining(buyNoId, amount, rb);
        if (uint256(a.price) + uint256(b.price) < ONE) revert PricesDoNotCross(a.price, b.price);

        uint256 ca = _cost(amount, a.price);
        uint256 cb = _cost(amount, b.price);
        uint256 need = uint256(amount);
        // Both legs round down, so a pair whose prices sum to exactly par can
        // land a wei short. The shortfall is charged to the YES buyer, whose
        // escrow was rounded up on placement precisely to absorb this.
        if (ca + cb < need) ca += need - ca - cb;
        // An explicit check rather than an arithmetic panic. Reachable only by
        // pathological fill sequences on sub-unit amounts, but a named revert
        // tells a caller what happened.
        if (ca > a.escrow || cb > b.escrow) revert InsufficientEscrow();
        a.escrow -= uint128(ca);
        b.escrow -= uint128(cb);
        a.filled += amount;
        b.filled += amount;

        collateral.forceApprove(address(core), need);
        core.split(a.marketId, need);

        (address y, address n) = core.tokensOf(a.marketId);
        IERC20(y).safeTransfer(a.maker, amount);
        IERC20(n).safeTransfer(b.maker, amount);

        uint256 surplus = ca + cb - need;
        if (surplus > 0) collateral.safeTransfer(msg.sender, surplus);
        emit Minted(buyYesId, buyNoId, msg.sender, amount, surplus);
    }

    /// @notice Match two sell orders by merging their tokens back to collateral.
    function matchMerge(uint256 sellYesId, uint256 sellNoId, uint128 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        Order storage a = _live(sellYesId);
        Order storage b = _live(sellNoId);
        if (a.side != Side.SellYes || b.side != Side.SellNo) revert WrongSide();
        if (a.marketId != b.marketId) revert DifferentMarkets();
        if (a.maker == b.maker) revert SelfTrade();

        uint128 ra = a.amount - a.filled;
        uint128 rb = b.amount - b.filled;
        if (amount > ra) revert AmountExceedsRemaining(sellYesId, amount, ra);
        if (amount > rb) revert AmountExceedsRemaining(sellNoId, amount, rb);
        if (uint256(a.price) + uint256(b.price) > ONE) revert PricesDoNotCross(a.price, b.price);

        a.escrow -= amount;
        b.escrow -= amount;
        a.filled += amount;
        b.filled += amount;

        uint256 before = collateral.balanceOf(address(this));
        core.merge(a.marketId, uint256(amount));
        uint256 got = collateral.balanceOf(address(this)) - before;

        uint256 pa = _cost(amount, a.price);
        uint256 pb = _cost(amount, b.price);
        collateral.safeTransfer(a.maker, pa);
        collateral.safeTransfer(b.maker, pb);

        uint256 surplus = got - pa - pb;
        if (surplus > 0) collateral.safeTransfer(msg.sender, surplus);
        emit Merged(sellYesId, sellNoId, msg.sender, amount, surplus);
    }

    /// @notice Match a resting buy against a resting sell on the SAME outcome.
    /// @dev Without this, a bid of 0.60 for YES and an ask of 0.55 for YES sit
    ///      next to each other forever: both are makers, and fill() requires a
    ///      taker to bring the counter-asset. Clearing them off chain would mean
    ///      two fill() calls with working capital, and the two are not atomic,
    ///      so a third party can lift one leg in between.
    ///
    ///      Here both escrows are already inside this contract, so the swap is a
    ///      single atomic bookkeeping step. The buyer pays no more than the bid,
    ///      the seller receives no less than the ask, and the spread between the
    ///      two pays whoever did the matching. No capital is required.
    function matchCross(uint256 buyId, uint256 sellId, uint128 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        Order storage buy = _live(buyId);
        Order storage sell = _live(sellId);

        bool isYes;
        if (buy.side == Side.BuyYes && sell.side == Side.SellYes) isYes = true;
        else if (buy.side == Side.BuyNo && sell.side == Side.SellNo) isYes = false;
        else revert WrongSide();

        if (buy.marketId != sell.marketId) revert DifferentMarkets();
        if (buy.maker == sell.maker) revert SelfTrade();

        uint128 ra = buy.amount - buy.filled;
        uint128 rb = sell.amount - sell.filled;
        if (amount > ra) revert AmountExceedsRemaining(buyId, amount, ra);
        if (amount > rb) revert AmountExceedsRemaining(sellId, amount, rb);
        if (buy.price < sell.price) revert PricesDoNotCross(buy.price, sell.price);

        // Both legs floor, and the bid is at least the ask, so paid >= recv
        // always holds and the surplus can never underflow.
        uint256 paid = _cost(amount, buy.price);
        uint256 recv = _cost(amount, sell.price);
        if (paid > buy.escrow) revert InsufficientEscrow();

        buy.escrow -= uint128(paid);
        sell.escrow -= amount;
        buy.filled += amount;
        sell.filled += amount;

        (address y, address n) = core.tokensOf(buy.marketId);
        IERC20(isYes ? y : n).safeTransfer(buy.maker, amount);
        collateral.safeTransfer(sell.maker, recv);

        uint256 surplus = paid - recv;
        if (surplus > 0) collateral.safeTransfer(msg.sender, surplus);
        emit Crossed(buyId, sellId, msg.sender, amount, surplus);
    }


    /// @inheritdoc Pausable
    function _pauseAdmin() internal view override returns (address) {
        return owner();
    }

    // ----------------------------------------------------------------- views

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Every order id ever placed for a market, newest last.
    /// @dev Includes filled and cancelled orders. Callers page through this and
    ///      filter with isOpen; the contract never loops over it.
    function marketOrderIds(bytes32 marketId) external view returns (uint256[] memory) {
        return _marketOrders[marketId];
    }

    function marketOrderCount(bytes32 marketId) external view returns (uint256) {
        return _marketOrders[marketId].length;
    }

    function isOpen(uint256 orderId) public view returns (bool) {
        Order memory o = _orders[orderId];
        return o.maker != address(0)
            && !o.cancelled
            && o.filled < o.amount
            && block.timestamp <= o.expiry;
    }

    function remainingOf(uint256 orderId) external view returns (uint128) {
        Order memory o = _orders[orderId];
        return o.amount - o.filled;
    }

    /// @notice Collateral required to fill `amount` of an order, before fees.
    function costOf(uint256 orderId, uint128 amount) external view returns (uint256) {
        return _cost(amount, _orders[orderId].price);
    }

    // -------------------------------------------------------------- internal

    function _get(uint256 orderId) internal view returns (Order storage o) {
        o = _orders[orderId];
        if (o.maker == address(0)) revert UnknownOrder(orderId);
    }

    /// @dev A live order is one that can still trade right now. Halted markets
    ///      block trading because upstream has begun resolving, and continuing
    ///      to trade against a known answer is the leak the whole design avoids.
    function _live(uint256 orderId) internal view returns (Order storage o) {
        o = _get(orderId);
        if (o.cancelled || o.filled >= o.amount) revert OrderInactive(orderId);
        if (block.timestamp > o.expiry) revert OrderExpired(orderId);
        if (core.isSettled(o.marketId)) revert MarketNotTradeable(o.marketId);
    }

    /// @dev Payouts round down, so the contract can never be asked for more
    ///      than it holds.
    function _cost(uint128 amount, uint64 price) internal pure returns (uint256) {
        return (uint256(amount) * uint256(price)) / ONE;
    }

    /// @dev Escrow rounds up, so partial fills can never exhaust it early.
    function _ceilCost(uint128 amount, uint64 price) internal pure returns (uint256) {
        uint256 num = uint256(amount) * uint256(price);
        return (num + ONE - 1) / ONE;
    }
}
