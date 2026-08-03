// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestDollar} from "../src/TestDollar.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {DirectionalVault} from "../src/DirectionalVault.sol";
import {ParlayFactory} from "../src/ParlayFactory.sol";
import {MirrorPositionOracle} from "../src/MirrorPositionOracle.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

/// @title CrossContractInvariant
/// @notice Every other suite tests one contract in isolation. This one runs all
///         of them against a single core at once.
///
/// @dev WHY THIS MATTERS MORE THAN THE UNIT TESTS
///      AlphaMarketCore holds the collateral behind every outcome token, but
///      four separate contracts mint and burn those tokens: the order book
///      mints on a matched pair of buys, the vaults redeem on settlement, the
///      parlay factory holds its own collateral, and users split and merge
///      directly. Each path is individually correct. The question this suite
///      asks is whether they are still correct together.
///
///      THE INVARIANT: for every market, the collateral held by the core is at
///      least what the outstanding YES and NO supply can claim under the worst
///      terminal outcome. If that ever fails, somebody eventually cannot
///      redeem a winning token, which is the worst failure this system has.
contract CrossContractInvariantTest is Test {
    TestDollar usd;
    MarketRegistry registry;
    AlphaMarketCore core;
    OrderBook book;
    MarginVault mv;
    DirectionalVault dv;
    ParlayFactory parlay;
    MirrorPositionOracle oracle;

    address relayer = makeAddr("relayer");
    address arbiter = makeAddr("arbiter");
    address writer = makeAddr("writer");
    address proposer = makeAddr("proposer");
    address matcher = makeAddr("matcher");
    address keeper = makeAddr("keeper");

    address[4] users;

    bytes32 constant A = keccak256("cross-A");
    bytes32 constant B = keccak256("cross-B");
    bytes32[2] mids;

    uint256 constant BOND = 100e6;
    uint64 constant WINDOW = 2 hours;
    uint256 constant ONE = 1e6;
    uint64 expiry;

    function setUp() public {
        usd = new TestDollar(1_000_000e6, 0, type(uint128).max);
        registry = new MarketRegistry(address(usd), BOND, WINDOW, 0, arbiter, 1 hours, 7 days);
        core = new AlphaMarketCore(address(usd), address(registry));
        book = new OrderBook(address(core), 20);
        mv = new MarginVault(address(core), 500, 1500, 10_000_000e6);
        oracle = new MirrorPositionOracle(address(registry), 1 hours, 10_000);
        dv = new DirectionalVault(address(core), address(oracle));
        parlay = new ParlayFactory(address(usd), address(registry));

        registry.setRelayer(relayer, true);
        oracle.setWriter(writer, true);

        mids[0] = A;
        mids[1] = B;
        uint64 end = uint64(block.timestamp + 90 days);
        vm.startPrank(relayer);
        registry.registerMarket(A, end, 0);
        registry.registerMarket(B, end, 0);
        vm.stopPrank();
        core.initializeMarket(A);
        core.initializeMarket(B);

        vm.startPrank(writer);
        oracle.writePrice(A, 600_000);
        oracle.writePrice(B, 400_000);
        vm.stopPrank();

        expiry = uint64(block.timestamp + 30 days);

        users[0] = makeAddr("u0");
        users[1] = makeAddr("u1");
        users[2] = makeAddr("u2");
        users[3] = makeAddr("u3");

        address[8] memory all = [
            users[0], users[1], users[2], users[3],
            proposer, matcher, keeper, address(this)
        ];
        for (uint256 i = 0; i < all.length; i++) {
            vm.prank(all[i]);
            usd.claim();
            vm.startPrank(all[i]);
            usd.approve(address(core), type(uint256).max);
            usd.approve(address(book), type(uint256).max);
            usd.approve(address(registry), type(uint256).max);
            usd.approve(address(mv), type(uint256).max);
            usd.approve(address(dv), type(uint256).max);
            usd.approve(address(parlay), type(uint256).max);
            for (uint256 m = 0; m < 2; m++) {
                (address y, address n) = core.tokensOf(mids[m]);
                OutcomeToken(y).approve(address(book), type(uint256).max);
                OutcomeToken(n).approve(address(book), type(uint256).max);
                OutcomeToken(y).approve(address(mv), type(uint256).max);
                OutcomeToken(n).approve(address(mv), type(uint256).max);
                OutcomeToken(y).approve(address(dv), type(uint256).max);
                OutcomeToken(n).approve(address(dv), type(uint256).max);
            }
            vm.stopPrank();
        }

        usd.approve(address(mv), type(uint256).max);
        usd.approve(address(dv), type(uint256).max);
        mv.fund(200_000e6);
        dv.fund(200_000e6);
    }

    // ------------------------------------------------------------ the check

    /// @dev The core must always hold at least what outstanding tokens can
    ///      still claim. What that means changes at resolution, so the check
    ///      changes with it.
    ///
    ///      Before resolution every pair was minted together, so the two sides
    ///      must be equal and each pair can claim one whole unit.
    ///
    ///      After resolution only the winning side can claim. Redeeming burns
    ///      just that side, so the loser stays outstanding until its holder
    ///      bothers to burn it. That asymmetry is correct, not a defect: those
    ///      tokens are worth zero and can never draw on the core. An earlier
    ///      version of this helper asserted the sides stay equal forever and
    ///      failed here, which was the assertion being wrong rather than the
    ///      contracts.
    function _assertCoreSolvent(string memory where) internal view {
        uint256 owed;
        for (uint256 m = 0; m < 2; m++) {
            (address y, address n) = core.tokensOf(mids[m]);
            uint256 sy = OutcomeToken(y).totalSupply();
            uint256 sn = OutcomeToken(n).totalSupply();

            if (!registry.isResolved(mids[m])) {
                assertEq(sy, sn, string.concat(where, ": unresolved sides diverged"));
                owed += sy;
                continue;
            }

            MarketTypes.Outcome o = registry.outcomeOf(mids[m]);
            if (o == MarketTypes.Outcome.Yes) owed += sy;
            else if (o == MarketTypes.Outcome.No) owed += sn;
            else owed += (sy + sn) / 2;
        }
        assertGe(usd.balanceOf(address(core)), owed,
            string.concat(where, ": CORE INSOLVENT"));
    }

    /// @dev A losing token must be worth exactly nothing. If redeeming one ever
    ///      pays out, the core is being drained by tokens with no claim.
    function _assertLosersWorthless(bytes32 id, string memory where) internal {
        if (!registry.isResolved(id)) return;
        MarketTypes.Outcome o = registry.outcomeOf(id);
        if (o == MarketTypes.Outcome.Invalid) return;

        (address y, address n) = core.tokensOf(id);
        address loser = o == MarketTypes.Outcome.Yes ? n : y;
        uint256 held = OutcomeToken(loser).balanceOf(users[1]);
        if (held == 0) return;

        uint256 before = usd.balanceOf(users[1]);
        vm.prank(users[1]);
        if (o == MarketTypes.Outcome.Yes) {
            try core.redeem(id, 0, held) { } catch { }
        } else {
            try core.redeem(id, held, 0) { } catch { }
        }
        assertEq(usd.balanceOf(users[1]), before,
            string.concat(where, ": a losing token paid out"));
    }

    /// @dev Nothing may be trapped in the book beyond what open orders and
    ///      collected fees can claim.
    function _assertBookSolvent(uint256[] memory ids, string memory where) internal view {
        uint256 owedCash = book.feesAccrued();
        for (uint256 i = 0; i < ids.length; i++) {
            OrderBook.Order memory o = book.getOrder(ids[i]);
            if (o.cancelled) continue;
            if (o.side == OrderBook.Side.BuyYes || o.side == OrderBook.Side.BuyNo) {
                owedCash += o.escrow;
            }
        }
        assertGe(usd.balanceOf(address(book)), owedCash,
            string.concat(where, ": BOOK INSOLVENT"));
    }

    // ------------------------------------------------- the combined scenario

    /// @notice All four mint/burn paths active on the same market at once.
    function test_AllPathsTogether_CoreStaysSolvent() public {
        _assertCoreSolvent("start");

        // path 1: a user splits directly
        vm.prank(users[0]);
        core.split(A, 5_000e6);
        _assertCoreSolvent("after direct split");

        // path 2: the book mints a pair from two buy orders
        vm.prank(users[1]);
        uint256 o1 = book.placeOrder(A, OrderBook.Side.BuyYes, 620_000, 3_000e6, expiry);
        vm.prank(users[2]);
        uint256 o2 = book.placeOrder(A, OrderBook.Side.BuyNo, 430_000, 3_000e6, expiry);
        vm.prank(matcher);
        book.matchMint(o1, o2, 3_000e6);
        _assertCoreSolvent("after book mint");

        // path 3: a hedged pledge borrows against the proven floor
        vm.startPrank(users[0]);
        mv.pledge(A, 2_000e6, 2_000e6);
        mv.borrow(A, 1_500e6);
        vm.stopPrank();
        _assertCoreSolvent("after margin borrow");

        // path 4: a one-sided pledge borrows against an oracle price
        vm.startPrank(users[1]);
        dv.pledge(A, 1_000e6, 0);
        dv.borrow(A, 150e6);
        vm.stopPrank();
        _assertCoreSolvent("after directional borrow");

        // path 5: a parlay holds its own collateral over the same markets
        bytes32[] memory legs = new bytes32[](2);
        uint8[] memory req = new uint8[](2);
        legs[0] = A; legs[1] = B;
        req[0] = uint8(MarketTypes.Outcome.Yes);
        req[1] = uint8(MarketTypes.Outcome.Yes);
        bytes32 pid = parlay.createParlay(legs, req);
        vm.prank(users[3]);
        parlay.split(pid, 1_000e6);
        _assertCoreSolvent("after parlay split");

        // path 6: the book merges a pair back out
        vm.prank(users[2]);
        uint256 o3 = book.placeOrder(A, OrderBook.Side.SellNo, 400_000, 1_000e6, expiry);
        vm.prank(users[0]);
        uint256 o4 = book.placeOrder(A, OrderBook.Side.SellYes, 550_000, 1_000e6, expiry);
        vm.prank(matcher);
        book.matchMerge(o4, o3, 1_000e6);
        _assertCoreSolvent("after book merge");

        uint256[] memory ids = new uint256[](4);
        ids[0] = o1; ids[1] = o2; ids[2] = o3; ids[3] = o4;
        _assertBookSolvent(ids, "after merge");

        // now resolve and let every holder redeem
        _resolve(A, MarketTypes.Outcome.Yes);
        _assertCoreSolvent("after resolution");

        mv.settle(A, users[0]);
        _assertCoreSolvent("after margin settle");
        dv.settleResolved(A, users[1]);
        _assertCoreSolvent("after directional settle");

        (address y,) = core.tokensOf(A);
        for (uint256 i = 0; i < 4; i++) {
            uint256 bal = OutcomeToken(y).balanceOf(users[i]);
            if (bal > 0) {
                vm.prank(users[i]);
                core.redeem(A, bal, 0);
                _assertCoreSolvent("after a user redeem");
            }
        }
    }

    /// @notice The same combination under fuzzed sizes and orderings.
    function testFuzz_CoreSolventUnderMixedActivity(
        uint96 splitRaw, uint96 bookRaw, uint64 pYraw, uint8 seed
    ) public {
        uint256 splitAmt = bound(splitRaw, 1e6, 50_000e6);
        uint256 bookAmt = bound(bookRaw, 1e6, 50_000e6);
        uint64 pY = uint64(bound(pYraw, 100_000, 900_000));
        uint64 pN = uint64(ONE - pY + 20_000);          // crosses by 0.02

        vm.prank(users[0]);
        core.split(A, splitAmt);

        vm.prank(users[1]);
        uint256 o1 = book.placeOrder(A, OrderBook.Side.BuyYes, pY, uint128(bookAmt), expiry);
        vm.prank(users[2]);
        uint256 o2 = book.placeOrder(A, OrderBook.Side.BuyNo, pN, uint128(bookAmt), expiry);
        vm.prank(matcher);
        book.matchMint(o1, o2, uint128(bookAmt));
        _assertCoreSolvent("after fuzzed mint");

        if (seed % 2 == 0) {
            uint256 half = splitAmt / 2;
            if (half > 0) {
                vm.startPrank(users[0]);
                mv.pledge(A, half, half);
                uint256 avail = mv.availableToBorrow(A, users[0]);
                if (avail > 0) mv.borrow(A, avail);
                vm.stopPrank();
            }
        }
        _assertCoreSolvent("after fuzzed borrow");

        MarketTypes.Outcome o = seed % 3 == 0
            ? MarketTypes.Outcome.Yes
            : (seed % 3 == 1 ? MarketTypes.Outcome.No : MarketTypes.Outcome.Invalid);
        _resolve(A, o);
        _assertCoreSolvent("after fuzzed resolution");
        _assertLosersWorthless(A, "fuzzed resolution");
        _assertCoreSolvent("after fuzzed loser redeem");
    }

    /// @notice The book must never mint a pair the core cannot back, whatever
    ///         the two limit prices are.
    function testFuzz_BookMintAlwaysFullyBacked(uint64 pYraw, uint96 amtRaw) public {
        uint64 pY = uint64(bound(pYraw, 1, ONE - 1));
        uint64 pN = uint64(ONE - pY);                    // exactly at par
        uint128 amt = uint128(bound(amtRaw, 1, 100_000e6));

        uint256 backingBefore = usd.balanceOf(address(core));
        vm.prank(users[1]);
        uint256 o1 = book.placeOrder(A, OrderBook.Side.BuyYes, pY, amt, expiry);
        vm.prank(users[2]);
        uint256 o2 = book.placeOrder(A, OrderBook.Side.BuyNo, pN, amt, expiry);
        vm.prank(matcher);
        book.matchMint(o1, o2, amt);

        assertEq(usd.balanceOf(address(core)) - backingBefore, amt,
            "one whole unit must back every minted pair");
        _assertCoreSolvent("after par mint");
    }

    /// @notice Two vaults holding pledges on the same market must not interfere.
    function test_BothVaultsOnOneMarket_SettleIndependently() public {
        vm.prank(users[0]);
        core.split(A, 4_000e6);
        vm.prank(users[1]);
        core.split(A, 4_000e6);

        vm.startPrank(users[0]);
        mv.pledge(A, 4_000e6, 4_000e6);
        mv.borrow(A, 3_000e6);
        vm.stopPrank();

        vm.startPrank(users[1]);
        dv.pledge(A, 4_000e6, 0);
        dv.borrow(A, 500e6);
        vm.stopPrank();
        _assertCoreSolvent("both vaults loaded");

        _resolve(A, MarketTypes.Outcome.Yes);

        mv.settle(A, users[0]);
        _assertCoreSolvent("margin settled first");
        dv.settleResolved(A, users[1]);
        _assertCoreSolvent("directional settled second");

        assertEq(mv.debtOf(A, users[0]), 0);
        assertEq(dv.debtOf(A, users[1]), 0);

        // the NO tokens user1 kept are now worthless and must stay that way
        _assertLosersWorthless(A, "both vaults settled");
        _assertCoreSolvent("after attempting a loser redeem");
    }

    /// @notice A parlay resolving must not disturb the legs it was built on.
    function test_ParlayDoesNotTouchLegCollateral() public {
        vm.prank(users[0]);
        core.split(A, 3_000e6);

        bytes32[] memory legs = new bytes32[](2);
        uint8[] memory req = new uint8[](2);
        legs[0] = A; legs[1] = B;
        req[0] = uint8(MarketTypes.Outcome.Yes);
        req[1] = uint8(MarketTypes.Outcome.No);
        bytes32 pid = parlay.createParlay(legs, req);

        vm.prank(users[3]);
        parlay.split(pid, 2_000e6);

        uint256 coreBefore = usd.balanceOf(address(core));
        _resolve(A, MarketTypes.Outcome.Yes);
        _resolve(B, MarketTypes.Outcome.No);
        parlay.resolve(pid);

        assertEq(usd.balanceOf(address(core)), coreBefore,
            "parlay settlement must not draw on core collateral");
        _assertCoreSolvent("after parlay resolve");

        (address py,) = parlay.tokensOf(pid);
        uint256 bal = OutcomeToken(py).balanceOf(users[3]);
        uint256 before = usd.balanceOf(users[3]);
        vm.prank(users[3]);
        parlay.redeem(pid, bal, 0);
        assertEq(usd.balanceOf(users[3]) - before, 2_000e6, "parlay pays from its own escrow");
        _assertCoreSolvent("after parlay redeem");
    }

    // --------------------------------------------------------------- helpers

    function _resolve(bytes32 id, MarketTypes.Outcome o) internal {
        if (registry.isResolved(id)) return;
        vm.prank(proposer);
        registry.proposeOutcome(id, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(id);
    }
}
