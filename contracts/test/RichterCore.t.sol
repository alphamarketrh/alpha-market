// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {RichterCore} from "../src/RichterCore.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {IRichterOracle} from "../src/interfaces/IRichterOracle.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// An oracle whose answers the test sets directly, so the core can be exercised
/// against every fraction including the ones a live feed would rarely produce.
contract StubOracle is IRichterOracle {
    mapping(bytes32 => bool) public known;
    mapping(bytes32 => uint256) public frac;
    mapping(bytes32 => bool) public open;

    function set(bytes32 id, uint256 s) external {
        known[id] = true;
        frac[id] = s;
    }

    function setKnownButOpen(bytes32 id) external {
        known[id] = true;
        open[id] = true;
    }

    function isKnownMarket(bytes32 id) external view returns (bool) {
        return known[id];
    }

    function settlementFraction(bytes32 id) external view returns (uint256) {
        require(!open[id], "window open");
        return frac[id];
    }
}

contract RichterCoreTest is Test {
    RichterCore internal core;
    StubOracle internal oracle;
    MockUSDG internal usd;

    bytes32 constant ID = keccak256("market-1");
    uint256 constant ONE = 1e6;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        usd = new MockUSDG();
        oracle = new StubOracle();
        core = new RichterCore(address(usd), address(oracle));

        oracle.set(ID, 0);
        core.initializeMarket(ID);

        for (uint256 i = 0; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            usd.mint(who, 1_000_000e6);
            vm.prank(who);
            usd.approve(address(core), type(uint256).max);
        }
    }

    function _tokens(bytes32 id) internal view returns (OutcomeToken b, OutcomeToken c) {
        (address ba, address ca) = core.tokensOf(id);
        return (OutcomeToken(ba), OutcomeToken(ca));
    }

    // -- the pair invariant, which the whole lending layer rests on -----------

    function test_splitMintsOneOfEach() public {
        (OutcomeToken b, OutcomeToken c) = _tokens(ID);
        vm.prank(alice);
        core.split(ID, 1000e6);
        assertEq(b.balanceOf(alice), 1000e6);
        assertEq(c.balanceOf(alice), 1000e6);
        assertEq(usd.balanceOf(address(core)), 1000e6);
    }

    function test_mergeReturnsExactlyOneUnit() public {
        (OutcomeToken b, OutcomeToken c) = _tokens(ID);
        vm.startPrank(alice);
        core.split(ID, 1000e6);
        uint256 before = usd.balanceOf(alice);
        core.merge(ID, 400e6);
        vm.stopPrank();
        assertEq(usd.balanceOf(alice) - before, 400e6);
        assertEq(b.balanceOf(alice), 600e6);
        assertEq(c.balanceOf(alice), 600e6);
    }

    /// The floor LendingVault lends 95% against. A matched pair is worth one unit
    /// after settlement too, whatever the fraction turned out to be.
    function test_mergeStaysOpenAfterSettlement() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        oracle.set(ID, 370_000);
        core.settle(ID);

        vm.prank(alice);
        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.merge(ID, 1000e6);
        assertEq(usd.balanceOf(alice) - before, 1000e6, "a pair is one unit at any s");
    }

    function testFuzz_pairIsAlwaysWorthOneUnit(uint256 s, uint256 amount) public {
        s = bound(s, 0, ONE);
        amount = bound(amount, 1e6, 100_000e6);
        vm.prank(alice);
        core.split(ID, amount);
        oracle.set(ID, s);
        core.settle(ID);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(ID, amount, amount);
        // Two floors, so at most two base units of dust are left behind.
        uint256 paid = usd.balanceOf(alice) - before;
        assertLe(paid, amount, "cannot pay out more than was locked");
        assertGe(paid + 2, amount, "dust must be at most two base units");
    }

    // -- graded settlement ---------------------------------------------------

    function test_redeemPaysTheFraction() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        oracle.set(ID, 370_000);   // 0.37
        core.settle(ID);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(ID, 1000e6, 0);
        assertEq(usd.balanceOf(alice) - before, 370e6, "BIG pays s");
    }

    function test_redeemPaysTheComplement() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        oracle.set(ID, 370_000);
        core.settle(ID);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(ID, 0, 1000e6);
        assertEq(usd.balanceOf(alice) - before, 630e6, "CALM pays one minus s");
    }

    function test_theCeilingPaysBigInFull() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        oracle.set(ID, ONE);
        core.settle(ID);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(ID, 1000e6, 0);
        assertEq(usd.balanceOf(alice) - before, 1000e6);
    }

    function test_aVoidPaysHalfToEach() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        oracle.set(ID, 5e5);
        core.settle(ID);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(ID, 1000e6, 1000e6);
        assertEq(usd.balanceOf(alice) - before, 1000e6, "half plus half is one unit");
    }

    /// Solvency is the property that matters: two people splitting and redeeming
    /// separately must never together take out more than went in.
    function testFuzz_neverPaysOutMoreThanItHolds(uint256 s, uint256 a, uint256 b) public {
        s = bound(s, 0, ONE);
        a = bound(a, 1e6, 50_000e6);
        b = bound(b, 1e6, 50_000e6);

        vm.prank(alice);
        core.split(ID, a);
        vm.prank(bob);
        core.split(ID, b);
        uint256 locked = usd.balanceOf(address(core));
        assertEq(locked, a + b);

        oracle.set(ID, s);
        core.settle(ID);

        vm.prank(alice);
        core.redeem(ID, a, a);
        vm.prank(bob);
        core.redeem(ID, b, b);

        assertLe(usd.balanceOf(address(core)), 4, "at most one base unit of dust per floor");
    }

    // -- lifecycle -----------------------------------------------------------

    function test_settleFreezesTheFraction() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        oracle.set(ID, 370_000);
        core.settle(ID);

        // A later oracle change must not move a market that already settled.
        oracle.set(ID, ONE);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(ID, 1000e6, 0);
        assertEq(usd.balanceOf(alice) - before, 370e6, "the frozen fraction wins");
    }

    function test_settleIsPermissionless() public {
        oracle.set(ID, 250_000);
        vm.prank(bob);
        core.settle(ID);
        (uint256 s,) = core.settlementOf(ID);
        assertEq(s, 250_000);
    }

    function test_cannotSettleTwice() public {
        oracle.set(ID, 250_000);
        core.settle(ID);
        vm.expectRevert(RichterCore.MarketAlreadySettled.selector);
        core.settle(ID);
    }

    function test_cannotSplitAfterSettlement() public {
        oracle.set(ID, 250_000);
        core.settle(ID);
        vm.prank(alice);
        vm.expectRevert(RichterCore.MarketAlreadySettled.selector);
        core.split(ID, 1000e6);
    }

    function test_cannotRedeemBeforeSettlement() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        vm.prank(alice);
        vm.expectRevert(RichterCore.MarketNotSettled.selector);
        core.redeem(ID, 1000e6, 0);
    }

    function test_settleRevertsWhileTheWindowIsOpen() public {
        bytes32 id2 = keccak256("market-open");
        oracle.setKnownButOpen(id2);
        core.initializeMarket(id2);
        vm.expectRevert();
        core.settle(id2);
    }

    function test_unknownMarketCannotBeInitialized() public {
        vm.expectRevert(RichterCore.MarketNotInitialized.selector);
        core.initializeMarket(keccak256("never-created"));
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert(RichterCore.AlreadyInitialized.selector);
        core.initializeMarket(ID);
    }

    function test_aFractionAboveOneIsRefused() public {
        bytes32 id3 = keccak256("market-bad");
        oracle.set(id3, ONE + 1);
        core.initializeMarket(id3);
        vm.expectRevert(abi.encodeWithSelector(RichterCore.BadFraction.selector, ONE + 1));
        core.settle(id3);
    }

    function test_onlyTheCoreCanMint() public {
        (OutcomeToken b,) = _tokens(ID);
        vm.prank(alice);
        vm.expectRevert();
        b.mint(alice, 1e6);
    }

    function test_redeemingNothingReverts() public {
        oracle.set(ID, 0);
        core.settle(ID);
        vm.prank(alice);
        vm.expectRevert(RichterCore.ZeroAmount.selector);
        core.redeem(ID, 0, 0);
    }

    /// s of zero means BIG is worthless. Burning it alone must revert rather than
    /// silently destroying the tokens for nothing.
    function test_redeemingAWorthlessSideReverts() public {
        vm.prank(alice);
        core.split(ID, 1000e6);
        oracle.set(ID, 0);
        core.settle(ID);
        vm.prank(alice);
        vm.expectRevert(RichterCore.NothingToRedeem.selector);
        core.redeem(ID, 1000e6, 0);
    }
}
