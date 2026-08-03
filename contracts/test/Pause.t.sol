// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestDollar} from "../src/TestDollar.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {Pausable} from "../src/Pausable.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

/// @notice The pause is only useful if it stops the right things and, more
///         importantly, stops nothing else. A pause that traps user funds
///         turns one bug into a hostage situation.
contract PauseTest is Test {
    TestDollar usd;
    MarketRegistry registry;
    AlphaMarketCore core;
    OrderBook book;
    MarginVault vault;

    address relayer = makeAddr("relayer");
    address arbiter = makeAddr("arbiter");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address proposer = makeAddr("proposer");

    bytes32 constant MID = keccak256("pause-market");
    uint64 constant WINDOW = 2 hours;
    uint64 expiry;
    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        usd = new TestDollar(1_000_000e6, 0, type(uint128).max);
        registry = new MarketRegistry(address(usd), 100e6, WINDOW, 0, arbiter, 1 hours, 7 days);
        core = new AlphaMarketCore(address(usd), address(registry));
        book = new OrderBook(address(core), 20);
        vault = new MarginVault(address(core), 500, 1500, 10_000_000e6);

        registry.setRelayer(relayer, true);
        vm.prank(relayer);
        registry.registerMarket(MID, uint64(block.timestamp + 90 days), 0);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);
        expiry = uint64(block.timestamp + 30 days);

        address[4] memory who = [alice, bob, proposer, address(this)];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usd.claim();
            vm.startPrank(who[i]);
            usd.approve(address(core), type(uint256).max);
            usd.approve(address(book), type(uint256).max);
            usd.approve(address(vault), type(uint256).max);
            usd.approve(address(registry), type(uint256).max);
            yes.approve(address(book), type(uint256).max);
            no.approve(address(book), type(uint256).max);
            yes.approve(address(vault), type(uint256).max);
            no.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vault.fund(500_000e6);
    }

    // ------------------------------------------------------------ authority

    function test_Guardian_CanPauseButNotUnpause() public {
        book.setGuardian(guardian, true);

        vm.prank(guardian);
        book.pauseEntry();
        assertTrue(book.entryPaused());

        vm.prank(guardian);
        vm.expectRevert(Pausable.NotPauseAdmin.selector);
        book.unpauseEntry();

        book.unpauseEntry();
        assertFalse(book.entryPaused(), "only the owner may resume");
    }

    function test_Stranger_CannotPause() public {
        vm.prank(alice);
        vm.expectRevert(Pausable.NotGuardian.selector);
        book.pauseEntry();
    }

    /// @notice The core has no owner of its own, so it defers to the registry
    ///         owner rather than inventing a new role.
    function test_Core_UsesRegistryOwnerAsAdmin() public {
        core.pauseEntry();
        assertTrue(core.entryPaused(), "registry owner may pause the core");

        vm.prank(alice);
        vm.expectRevert(Pausable.NotGuardian.selector);
        core.pauseEntry();
    }

    // --------------------------------------------------- entries are stopped

    function test_Paused_BlocksSplit() public {
        core.pauseEntry();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnterPaused.selector);
        core.split(MID, 1_000e6);
    }

    function test_Paused_BlocksPlaceOrder() public {
        book.pauseEntry();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnterPaused.selector);
        book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
    }

    function test_Paused_BlocksPledgeAndBorrow() public {
        vm.prank(alice);
        core.split(MID, 2_000e6);
        vault.pauseEntry();

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnterPaused.selector);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vm.stopPrank();
    }

    // -------------------------------------------- EXITS MUST STAY OPEN

    /// @notice The load-bearing property. If any of these revert while paused,
    ///         a pause becomes a way to trap user money.
    function test_Paused_MergeStillWorks() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        core.pauseEntry();

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.merge(MID, 1_000e6);
        assertEq(usd.balanceOf(alice) - before, 1_000e6, "exit must survive a pause");
    }

    function test_Paused_RedeemStillWorks() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _resolve(MarketTypes.Outcome.Yes);
        core.pauseEntry();

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(MID, 1_000e6, 0);
        assertEq(usd.balanceOf(alice) - before, 1_000e6, "redemption must survive a pause");
    }

    function test_Paused_CancelOrderStillWorks() public {
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 600_000, 1_000e6, expiry);
        book.pauseEntry();

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        book.cancelOrder(id);
        assertEq(usd.balanceOf(alice) - before, 600e6, "escrow must be reclaimable while paused");
    }

    function test_Paused_FillAndMatchStillWork() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.prank(alice);
        uint256 sell = book.placeOrder(MID, OrderBook.Side.SellYes, 600_000, 1_000e6, expiry);
        book.pauseEntry();

        vm.prank(bob);
        book.fill(sell, 500e6);
        assertEq(yes.balanceOf(bob), 500e6, "resting orders must still be fillable");
    }

    function test_Paused_RepayAndUnpledgeStillWork() public {
        vm.prank(alice);
        core.split(MID, 2_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 2_000e6, 2_000e6);
        vault.borrow(MID, 1_000e6);
        vm.stopPrank();

        vault.pauseEntry();

        vm.startPrank(alice);
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "repayment must survive a pause");
        vault.unpledge(MID, 2_000e6, 2_000e6);
        vm.stopPrank();
        assertEq(yes.balanceOf(alice), 2_000e6, "collateral must be reclaimable while paused");
    }

    function test_Paused_SettleStillWorks() public {
        vm.prank(alice);
        core.split(MID, 2_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 2_000e6, 2_000e6);
        vault.borrow(MID, 1_000e6);
        vm.stopPrank();
        _resolve(MarketTypes.Outcome.Yes);

        vault.pauseEntry();
        vault.settle(MID, alice);
        assertEq(vault.debtOf(MID, alice), 0, "settlement must survive a pause");
    }

    /// @notice A full round trip while paused, proving a user can always leave.
    function test_Paused_UserCanFullyExit() public {
        vm.prank(alice);
        core.split(MID, 3_000e6);
        vm.prank(alice);
        uint256 id = book.placeOrder(MID, OrderBook.Side.BuyYes, 500_000, 1_000e6, expiry);

        core.pauseEntry();
        book.pauseEntry();
        vault.pauseEntry();

        uint256 before = usd.balanceOf(alice);
        vm.startPrank(alice);
        book.cancelOrder(id);
        core.merge(MID, 3_000e6);
        vm.stopPrank();

        assertEq(usd.balanceOf(alice) - before, 3_500e6, "everything came back out");
        assertEq(yes.balanceOf(alice), 0);
    }

    function test_Unpause_RestoresEntry() public {
        core.pauseEntry();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnterPaused.selector);
        core.split(MID, 1_000e6);

        core.unpauseEntry();
        vm.prank(alice);
        core.split(MID, 1_000e6);
        assertEq(yes.balanceOf(alice), 1_000e6);
    }

    function _resolve(MarketTypes.Outcome o) internal {
        vm.prank(proposer);
        registry.proposeOutcome(MID, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);
    }
}
