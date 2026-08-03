// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

contract OrderBookTest is Test {
    MockUSDG usdg;
    MarketRegistry registry;
    AlphaMarketCore core;
    OrderBook book;

    address relayer = makeAddr("relayer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address matcher = makeAddr("matcher");
    address proposer = makeAddr("proposer");

    bytes32 constant MID = keccak256("book-market");
    uint256 constant BOND = 100e6;
    uint64 constant WINDOW = 2 hours;
    uint256 constant ONE = 1e6;
    // uint256 so arithmetic with 1e6-scale literals stays in uint256;
    // as uint16 the compiler tries to narrow 240e6 and overflows.
    uint256 constant FEE = 20;         // 0.2 percent

    uint64 expiry;
    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MarketRegistry(address(usdg), BOND, WINDOW, 0,
            makeAddr("arbiter"), 1 hours, 7 days);
        core = new AlphaMarketCore(address(usdg), address(registry));
        book = new OrderBook(address(core), uint16(FEE));
        registry.setRelayer(relayer, true);

        vm.prank(relayer);
        registry.registerMarket(MID, uint64(block.timestamp + 30 days), 0);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);
        expiry = uint64(block.timestamp + 7 days);

        address[5] memory who = [alice, bob, carol, matcher, proposer];
        for (uint256 i = 0; i < who.length; i++) {
            usdg.mint(who[i], 1_000_000e6);
            vm.startPrank(who[i]);
            usdg.approve(address(core), type(uint256).max);
            usdg.approve(address(book), type(uint256).max);
            usdg.approve(address(registry), type(uint256).max);
            yes.approve(address(book), type(uint256).max);
            no.approve(address(book), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------- placement

    function test_PlaceBuy_EscrowsCollateralRoundedUp() public {
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        assertEq(before - usdg.balanceOf(alice), 600e6, "1000 at 0.60");
        OrderBook.Order memory o = book.getOrder(id);
        assertEq(o.escrow, 600e6);
        assertEq(o.filled, 0);
        assertTrue(book.isOpen(id));
    }

    function test_PlaceSell_EscrowsTokens() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);
        assertEq(yes.balanceOf(alice), 0, "tokens moved into escrow");
        assertEq(yes.balanceOf(address(book)), 1_000e6);
        assertEq(book.getOrder(id).escrow, 1_000e6);
    }

    function test_Place_RejectsBadInput() public {
        vm.startPrank(alice);
        vm.expectRevert();
        book.placeOrder(MID, OrderBook.Side.BuyYes, 0, 1_000e6, expiry);
        vm.expectRevert();
        book.placeOrder(MID, OrderBook.Side.BuyYes, 1_000_000, 1_000e6, expiry);
        vm.expectRevert();
        book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 0, expiry);
        vm.expectRevert();
        book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_Cancel_RefundsEscrow() public {
        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        book.cancelOrder(id);
        vm.stopPrank();
        assertEq(usdg.balanceOf(alice), before, "fully refunded");
        assertFalse(book.isOpen(id));
    }

    /// @notice Trapping maker funds because trading stopped would be its own
    ///         failure, so cancellation survives a halt.
    function test_Cancel_WorksEvenWhenMarketHalted() public {
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(relayer);
        registry.halt(MID, "source resolving");

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        book.cancelOrder(id);
        assertEq(usdg.balanceOf(alice) - before, 600e6);
    }

    function test_Cancel_OnlyMaker() public {
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        vm.expectRevert(OrderBook.NotMaker.selector);
        book.cancelOrder(id);
    }

    // ------------------------------------------------------------------ fill

    function test_Fill_SellOrder_TakerPaysCash() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);

        uint256 aliceBefore = usdg.balanceOf(alice);
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        book.fill(id, 400e6);

        assertEq(yes.balanceOf(bob), 400e6, "taker received tokens");
        assertEq(usdg.balanceOf(alice) - aliceBefore, 240e6, "maker paid 400 at 0.60");
        // taker pays the leg plus the fee
        assertEq(bobBefore - usdg.balanceOf(bob), 240e6 + (240e6 * FEE) / 10_000);
        assertEq(book.feesAccrued(), (240e6 * FEE) / 10_000);
        assertEq(book.remainingOf(id), 600e6);
    }

    function test_Fill_BuyOrder_TakerDeliversTokens() public {
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        _split(bob, 1_000e6);

        uint256 bobBefore = usdg.balanceOf(bob);
        vm.prank(bob);
        book.fill(id, 500e6);

        assertEq(yes.balanceOf(alice), 500e6, "maker received tokens");
        uint256 leg = 300e6;
        uint256 fee = (leg * FEE) / 10_000;
        assertEq(usdg.balanceOf(bob) - bobBefore, leg - fee, "taker received cash minus fee");
        assertEq(book.getOrder(id).escrow, 600e6 - leg);
    }

    function test_Fill_RejectsSelfTrade() public {
        _split(alice, 1_000e6);
        vm.startPrank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);
        vm.expectRevert(OrderBook.SelfTrade.selector);
        book.fill(id, 100e6);
        vm.stopPrank();
    }

    function test_Fill_RejectsOverfill() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        vm.expectRevert();
        book.fill(id, 1_001e6);
    }

    function test_Fill_RejectsExpired() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);
        vm.warp(expiry + 1);
        vm.prank(bob);
        vm.expectRevert();
        book.fill(id, 100e6);
    }

    /// @notice Trading against a market whose answer is already being decided
    ///         upstream is the exact leak the architecture exists to close.
    function test_Fill_BlockedWhenHalted() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);
        vm.prank(relayer);
        registry.halt(MID, "source resolving");
        vm.prank(bob);
        vm.expectRevert();
        book.fill(id, 100e6);
    }

    // ------------------------------------------------------------- cold start

    /// @notice THE POINT OF THE WHOLE CONTRACT.
    ///         Two participants who hold nothing but cash trade with each other
    ///         in a market where not a single outcome token exists yet.
    function test_MatchMint_ColdStart() public {
        assertEq(yes.totalSupply(), 0, "no tokens exist");
        assertEq(no.totalSupply(), 0);

        vm.prank(alice);
        uint256 buyYes = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 buyNo = book.placeOrder(MID, OrderBook.Side.BuyNo, 450_000, 1_000e6, expiry);

        uint256 matcherBefore = usdg.balanceOf(matcher);
        vm.prank(matcher);
        book.matchMint(buyYes, buyNo, 1_000e6);

        assertEq(yes.balanceOf(alice), 1_000e6, "YES buyer holds YES");
        assertEq(no.balanceOf(bob), 1_000e6, "NO buyer holds NO");
        assertEq(yes.totalSupply(), 1_000e6, "tokens created from nothing but cash");
        assertEq(usdg.balanceOf(address(core)), 1_000e6, "core backs them fully");
        // 0.60 + 0.45 = 1.05, so 0.05 per unit pays the matcher
        assertEq(usdg.balanceOf(matcher) - matcherBefore, 50e6, "surplus pays for matching");
    }

    function test_MatchMint_ExactPar_NoSurplus() public {
        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.BuyNo, 400_000, 1_000e6, expiry);

        uint256 before = usdg.balanceOf(matcher);
        vm.prank(matcher);
        book.matchMint(a, b, 1_000e6);
        assertEq(usdg.balanceOf(matcher), before, "nothing left over at par");
        assertEq(yes.balanceOf(alice), 1_000e6);
        assertEq(no.balanceOf(bob), 1_000e6);
    }

    function test_MatchMint_RejectsPricesBelowPar() public {
        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.BuyYes, 500_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.BuyNo, 400_000, 1_000e6, expiry);
        vm.prank(matcher);
        vm.expectRevert();
        book.matchMint(a, b, 1_000e6);
    }

    function test_MatchMint_RejectsWrongSides() public {
        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.BuyYes, 450_000, 1_000e6, expiry);
        vm.prank(matcher);
        vm.expectRevert(OrderBook.WrongSide.selector);
        book.matchMint(a, b, 1_000e6);
    }

    function test_MatchMint_PartialLeavesBothOpen() public {
        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.BuyNo, 450_000, 800e6, expiry);

        vm.prank(matcher);
        book.matchMint(a, b, 300e6);
        assertEq(book.remainingOf(a), 700e6);
        assertEq(book.remainingOf(b), 500e6);
        assertTrue(book.isOpen(a));
        assertTrue(book.isOpen(b));
    }

    // ----------------------------------------------------------------- merge

    function test_MatchMerge_TwoSellersExitTogether() public {
        _split(alice, 1_000e6);
        _split(bob, 1_000e6);
        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.SellYes, 550_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.SellNo, 400_000, 1_000e6, expiry);

        uint256 aBefore = usdg.balanceOf(alice);
        uint256 bBefore = usdg.balanceOf(bob);
        uint256 mBefore = usdg.balanceOf(matcher);

        vm.prank(matcher);
        book.matchMerge(a, b, 1_000e6);

        assertEq(usdg.balanceOf(alice) - aBefore, 550e6);
        assertEq(usdg.balanceOf(bob) - bBefore, 400e6);
        assertEq(usdg.balanceOf(matcher) - mBefore, 50e6, "surplus pays the matcher");
        assertEq(yes.totalSupply(), 1_000e6, "only the merged pair was burned");
    }

    function test_MatchMerge_RejectsPricesAbovePar() public {
        _split(alice, 1_000e6);
        _split(bob, 1_000e6);
        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.SellYes, 700_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.SellNo, 400_000, 1_000e6, expiry);
        vm.prank(matcher);
        vm.expectRevert();
        book.matchMerge(a, b, 1_000e6);
    }

    // ----------------------------------------------------------------- cross

    /// @notice A bid and an ask on the same outcome used to sit next to each
    ///         other forever, because both are makers and fill needs a taker.
    function test_MatchCross_ClearsCrossingSameSide() public {
        _split(bob, 1_000e6);
        vm.prank(alice);
        uint256 buyId = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 sellId = book.placeOrder(MID, OrderBook.Side.SellYes, 550_000, 1_000e6, expiry);

        uint256 bobBefore = usdg.balanceOf(bob);
        uint256 mBefore = usdg.balanceOf(matcher);
        vm.prank(matcher);
        book.matchCross(buyId, sellId, 1_000e6);

        assertEq(yes.balanceOf(alice), 1_000e6, "buyer received the tokens");
        assertEq(usdg.balanceOf(bob) - bobBefore, 550e6, "seller received the ask");
        assertEq(usdg.balanceOf(matcher) - mBefore, 50e6, "the spread pays the matcher");
        assertEq(book.remainingOf(buyId), 0);
        assertEq(book.remainingOf(sellId), 0);
    }

    function test_MatchCross_NoSide() public {
        _split(bob, 1_000e6);
        vm.prank(alice);
        uint256 buyId = book.placeOrder(MID, OrderBook.Side.BuyNo, 400_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 sellId = book.placeOrder(MID, OrderBook.Side.SellNo, 350_000, 1_000e6, expiry);
        vm.prank(matcher);
        book.matchCross(buyId, sellId, 1_000e6);
        assertEq(no.balanceOf(alice), 1_000e6, "NO side crosses too");
    }

    function test_MatchCross_RejectsBidBelowAsk() public {
        _split(bob, 1_000e6);
        vm.prank(alice);
        uint256 buyId = book.placeOrder(MID, OrderBook.Side.BuyYes, 500_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 sellId = book.placeOrder(MID, OrderBook.Side.SellYes, 550_000, 1_000e6, expiry);
        vm.prank(matcher);
        vm.expectRevert();
        book.matchCross(buyId, sellId, 1_000e6);
    }

    function test_MatchCross_RejectsMismatchedOutcomes() public {
        _split(bob, 1_000e6);
        vm.prank(alice);
        uint256 buyId = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 sellId = book.placeOrder(MID, OrderBook.Side.SellNo, 300_000, 1_000e6, expiry);
        vm.prank(matcher);
        vm.expectRevert(OrderBook.WrongSide.selector);
        book.matchCross(buyId, sellId, 1_000e6);
    }

    function test_MatchCross_PartialLeavesBothOpen() public {
        _split(bob, 1_000e6);
        vm.prank(alice);
        uint256 buyId = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        uint256 sellId = book.placeOrder(MID, OrderBook.Side.SellYes, 550_000, 600e6, expiry);
        vm.prank(matcher);
        book.matchCross(buyId, sellId, 400e6);
        assertEq(book.remainingOf(buyId), 600e6);
        assertEq(book.remainingOf(sellId), 200e6);
        assertTrue(book.isOpen(buyId));
        assertTrue(book.isOpen(sellId));
    }

    /// @notice Solvency must survive the new path too: whatever the prices, the
    ///         book never pays out more than it holds.
    function testFuzz_CrossStaysSolvent(uint64 bidRaw, uint64 askRaw, uint96 amtRaw) public {
        uint64 ask = uint64(bound(askRaw, 1, ONE - 1));
        uint64 bid = uint64(bound(bidRaw, ask, ONE - 1));
        uint128 amount = uint128(bound(amtRaw, 1, 100_000e6));

        _split(bob, amount);
        vm.prank(alice);
        uint256 buyId = book.placeOrder(MID, OrderBook.Side.BuyYes, bid, amount, expiry);
        vm.prank(bob);
        uint256 sellId = book.placeOrder(MID, OrderBook.Side.SellYes, ask, amount, expiry);

        vm.prank(matcher);
        book.matchCross(buyId, sellId, amount);

        assertEq(yes.balanceOf(alice), amount, "buyer got exactly what was matched");
        _assertSolvent(buyId, sellId);
    }

    // ------------------------------------------------------------------ fees

    function test_Fee_CappedInCode() public {
        vm.expectRevert(OrderBook.FeeTooHigh.selector);
        book.setFee(201);
        book.setFee(200);
        assertEq(book.feeBps(), 200);
    }

    function test_Fee_WithdrawableByOwnerOnly() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);
        vm.prank(bob);
        book.fill(id, 1_000e6);

        uint256 fees = book.feesAccrued();
        assertGt(fees, 0);
        vm.prank(bob);
        vm.expectRevert();
        book.withdrawFees(fees);
        uint256 before = usdg.balanceOf(address(this));
        book.withdrawFees(fees);
        assertEq(usdg.balanceOf(address(this)) - before, fees);
        assertEq(book.feesAccrued(), 0);
    }

    // ------------------------------------------------------------- invariant

    /// @notice The property that matters: whatever sequence of orders, fills
    ///         and matches occurs, the book always holds at least the
    ///         collateral that open buy orders and accrued fees can claim, and
    ///         at least the tokens that open sell orders can claim.
    function testFuzz_BookStaysSolvent(
        uint64 pY, uint64 pN, uint96 amtRaw, uint8 action, uint8 fillPct
    ) public {
        uint64 priceY = uint64(bound(pY, 1, ONE - 1));
        uint64 priceN = uint64(bound(pN, 1, ONE - 1));
        uint128 amount = uint128(bound(amtRaw, 1, 100_000e6));

        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.BuyYes, priceY, amount, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.BuyNo, priceN, amount, expiry);

        uint128 part = uint128((uint256(amount) * (uint256(fillPct) % 101)) / 100);
        if (action % 3 == 0 && part > 0 && uint256(priceY) + uint256(priceN) >= ONE) {
            vm.prank(matcher);
            book.matchMint(a, b, part);
        } else if (action % 3 == 1) {
            vm.prank(alice);
            book.cancelOrder(a);
        }

        _assertSolvent(a, b);
    }

    function testFuzz_MintNeverUnderfundsTheCore(uint64 pY, uint96 amtRaw) public {
        uint64 priceY = uint64(bound(pY, 1, ONE - 1));
        uint64 priceN = uint64(ONE - priceY);          // exactly at par
        uint128 amount = uint128(bound(amtRaw, 1, 100_000e6));

        vm.prank(alice);
        uint256 a = book.placeOrder(MID, OrderBook.Side.BuyYes, priceY, amount, expiry);
        vm.prank(bob);
        uint256 b = book.placeOrder(MID, OrderBook.Side.BuyNo, priceN, amount, expiry);

        vm.prank(matcher);
        book.matchMint(a, b, amount);

        // one unit of collateral must sit behind every minted pair
        assertEq(usdg.balanceOf(address(core)), amount, "core fully backs the mint");
        assertEq(yes.totalSupply(), amount);
        assertEq(no.totalSupply(), amount);
        _assertSolvent(a, b);
    }

    // --------------------------------------------------------------- helpers

    function _assertSolvent(uint256 a, uint256 b) internal view {
        uint256 owed = book.feesAccrued();
        uint256 tokensOwedYes;
        uint256 tokensOwedNo;
        uint256[2] memory ids = [a, b];
        for (uint256 i = 0; i < 2; i++) {
            OrderBook.Order memory o = book.getOrder(ids[i]);
            if (o.cancelled) continue;
            if (o.side == OrderBook.Side.BuyYes || o.side == OrderBook.Side.BuyNo) {
                owed += o.escrow;
            } else if (o.side == OrderBook.Side.SellYes) {
                tokensOwedYes += o.escrow;
            } else {
                tokensOwedNo += o.escrow;
            }
        }
        assertGe(usdg.balanceOf(address(book)), owed, "SOLVENCY: collateral covers claims");
        assertGe(yes.balanceOf(address(book)), tokensOwedYes, "SOLVENCY: YES covers claims");
        assertGe(no.balanceOf(address(book)), tokensOwedNo, "SOLVENCY: NO covers claims");
    }

    function _split(address who, uint256 amount) internal {
        vm.prank(who);
        core.split(MID, amount);
    }
}
