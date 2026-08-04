// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {LendingVault} from "../src/LendingVault.sol";
import {InterestModel} from "../src/InterestModel.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

/// @notice The vault that lends against a proven floor, now funded by anyone
///         and charging a rate that moves with utilisation.
contract LendingVaultTest is Test {
    MockUSDG usdg;
    MarketRegistry registry;
    AlphaMarketCore core;
    InterestModel model;
    LendingVault vault;

    address relayer = makeAddr("relayer");
    address proposer = makeAddr("proposer");
    address alice = makeAddr("alice");     // borrower
    address bob = makeAddr("bob");         // supplier
    address carol = makeAddr("carol");     // second supplier

    bytes32 constant MID = keccak256("lending-market");
    uint64 constant WINDOW = 2 hours;
    uint256 constant BPS = 10_000;
    uint64 endTime;

    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MarketRegistry(address(usdg), 100e6, WINDOW, 0,
            makeAddr("arbiter"), 1 hours, 7 days);
        core = new AlphaMarketCore(address(usdg), address(registry));
        // 2% base, 15% at the 80% kink, 30% ceiling. The ceiling is low on
        // purpose: this vault never liquidates, and every point of ceiling is
        // borrowing power taken from long dated markets.
        model = new InterestModel(200, 1300, 1500, 8000);
        // 30% ceiling: this vault never liquidates, so it never needs a
        // punitive rate, and every point of ceiling is borrowing power taken
        // from long dated markets.
        vault = new LendingVault(address(core), address(model), 3000, 500, 1000, 1_000_000e6);

        registry.setRelayer(relayer, true);
        endTime = uint64(block.timestamp + 90 days);
        vm.prank(relayer);
        registry.registerMarket(MID, endTime, 0);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);

        address[4] memory who = [alice, bob, carol, proposer];
        for (uint256 i = 0; i < who.length; i++) {
            usdg.mint(who[i], 1_000_000e6);
            vm.startPrank(who[i]);
            usdg.approve(address(core), type(uint256).max);
            usdg.approve(address(vault), type(uint256).max);
            usdg.approve(address(registry), type(uint256).max);
            yes.approve(address(vault), type(uint256).max);
            no.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ supplying

    function test_Deposit_MintsSharesOneToOneWhenEmpty() public {
        vm.prank(bob);
        vault.deposit(10_000e6);
        assertEq(vault.supplyShares(bob), 10_000e6);
        assertEq(vault.balanceOfSupplier(bob), 10_000e6);
    }

    function test_Withdraw_ReturnsWhatWasSupplied() public {
        vm.startPrank(bob);
        vault.deposit(10_000e6);
        uint256 before = usdg.balanceOf(bob);
        vault.withdraw(type(uint256).max);
        vm.stopPrank();
        assertEq(usdg.balanceOf(bob) - before, 10_000e6);
        assertEq(vault.supplyShares(bob), 0);
    }

    /// @notice Interest earned before a second supplier arrives belongs to the
    ///         first. Shares are what make that true without touching accounts.
    function test_Deposit_LateSupplierCannotClaimEarlierInterest() public {
        vm.prank(bob);
        vault.deposit(10_000e6);
        _borrow(5_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 bobBefore = vault.balanceOfSupplier(bob);
        assertGt(bobBefore, 10_000e6, "bob earned something");

        vm.prank(carol);
        vault.deposit(10_000e6);
        assertApproxEqAbs(vault.balanceOfSupplier(carol), 10_000e6, 2, "carol starts flat");
        assertApproxEqAbs(vault.balanceOfSupplier(bob), bobBefore, 2, "bob keeps his");
    }

    function test_Withdraw_BoundedByIdleLiquidity() public {
        vm.prank(bob);
        vault.deposit(10_000e6);
        _borrow(9_000e6);

        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(10_000e6);

        vm.prank(bob);
        vault.withdraw(500e6);   // what is still idle
    }

    // ------------------------------------------------------- the proven floor

    function test_Floor_IsTheSmallerSide() public {
        vm.startPrank(alice);
        core.split(MID, 1_000e6);
        no.transfer(address(0xdead), 400e6);
        vault.pledge(MID, 1_000e6, 600e6);
        vm.stopPrank();
        assertEq(vault.floorOf(MID, alice), 600e6, "min(1000, 600)");
    }

    function test_OneSidedPledgeLendsNothing() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        vm.startPrank(alice);
        core.split(MID, 1_000e6);
        vault.pledge(MID, 1_000e6, 0);
        vm.stopPrank();
        assertEq(vault.floorOf(MID, alice), 0);
        assertEq(vault.availableToBorrow(MID, alice), 0, "no floor, no loan");
    }

    /// @notice THE PROPERTY. Whatever the rate did, the redemption always
    ///         covers the debt, so settlement never leaves a hole.
    function test_Settlement_AlwaysCoversTheDebt() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        uint256 drawn = _borrow(0);

        // push utilisation to the ceiling and leave it there
        _borrowMore();
        vm.warp(block.timestamp + 89 days);

        _resolve(MarketTypes.Outcome.Yes);
        uint256 debt = vault.debtOf(MID, alice);
        assertGt(debt, drawn, "interest did accrue");

        uint256 before = usdg.balanceOf(alice);
        vault.settle(MID, alice);
        assertEq(vault.debtOf(MID, alice), 0, "debt cleared in full");
        assertGe(usdg.balanceOf(alice), before, "and the borrower got the rest");
    }

    /// @notice The same, whatever the outcome and whatever the tenor.
    function testFuzz_SettlementCoversDebt(uint8 outcomeRaw, uint32 waitRaw, uint96 sizeRaw) public {
        vm.prank(bob);
        vault.deposit(500_000e6);

        uint256 size = bound(sizeRaw, 100e6, 50_000e6);
        vm.startPrank(alice);
        core.split(MID, size);
        vault.pledge(MID, size, size);
        uint256 avail = vault.availableToBorrow(MID, alice);
        if (avail > 0) vault.borrow(MID, avail);
        vm.stopPrank();

        vm.warp(block.timestamp + bound(waitRaw, 1, 89 days));

        MarketTypes.Outcome o = outcomeRaw % 3 == 0
            ? MarketTypes.Outcome.Yes
            : (outcomeRaw % 3 == 1 ? MarketTypes.Outcome.No : MarketTypes.Outcome.Invalid);
        _resolve(o);

        uint256 debt = vault.debtOf(MID, alice);
        vault.settle(MID, alice);
        assertEq(vault.debtOf(MID, alice), 0, "settlement always clears it");
        assertGt(debt, 0, "there was a debt to clear");
    }

    /// @notice A position nobody settles must not outgrow its collateral.
    function test_NeglectedPosition_CannotOutgrowTheFloor() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        uint256 drawn = _borrow(0);
        uint256 floor = vault.floorOf(MID, alice);

        vm.warp(block.timestamp + 3650 days);   // ten years of nobody caring
        uint256 debt = vault.debtOf(MID, alice);
        assertLt(debt, floor, "still under the floor");
        assertGt(debt, drawn, "but interest did run up to the deadline");
    }

    function test_Interest_StopsAtTheDeadline() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        _borrow(0);

        vm.warp(vault.deadlineOf(MID));
        uint256 atDeadline = vault.debtOf(MID, alice);
        vm.warp(vault.deadlineOf(MID) + 365 days);
        assertEq(vault.debtOf(MID, alice), atDeadline, "frozen at the deadline");
    }

    // -------------------------------------------------------- the moving rate

    function test_Rate_RisesWithUtilisation() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        uint256 quiet = vault.borrowRate();

        _borrow(0);
        uint256 busy = vault.borrowRate();
        assertGt(busy, quiet, "drawing the facility makes it dearer");
    }

    /// @notice Interest is charged at the rate that applied in each window, not
    ///         whatever it happens to be when somebody looks.
    function test_Interest_UsesTheRateOfEachWindow() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        _borrow(1_000e6);

        vm.warp(block.timestamp + 30 days);
        uint256 quietGrowth = vault.debtOf(MID, alice) - 1_000e6;

        // drive utilisation up, then wait the same again
        vm.prank(carol);
        vault.deposit(1e6);
        _borrowMore();
        uint256 mid = vault.debtOf(MID, alice);
        vm.warp(block.timestamp + 30 days);
        uint256 busyGrowth = vault.debtOf(MID, alice) - mid;

        assertGt(busyGrowth, quietGrowth, "the busy window cost more");
    }

    function test_Reserve_TakesItsShareAndOnlyThat() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        _borrow(50_000e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        vault.repay(MID, type(uint256).max);

        uint256 reserve = vault.reserveBalance();
        uint256 toSuppliers = vault.totalSupplied() - 100_000e6;
        assertGt(reserve, 0, "the reserve took something");
        assertApproxEqRel(reserve, (reserve + toSuppliers) / 10, 0.02e18, "about a tenth");
    }

    // ---------------------------------------------------------------- limits

    function test_BorrowLimit_ReservesAtTheCeiling() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        vm.startPrank(alice);
        core.split(MID, 10_000e6);
        vault.pledge(MID, 10_000e6, 10_000e6);
        vm.stopPrank();

        uint256 stat = vault.staticLimit(MID, alice);
        uint256 lim = vault.borrowLimit(MID, alice);
        assertLt(lim, stat, "a long dated market reserves more interest");

        // The reservation is exactly the ceiling rate applied over the time
        // left, so the figure is derived rather than guessed at.
        uint256 remaining = vault.deadlineOf(MID) - block.timestamp;
        uint256 expected = (stat * 365 days * BPS)
            / (365 days * BPS + vault.rateCeilingBps() * remaining);
        assertEq(lim, expected, "reserves exactly the ceiling interest");
    }

    function test_Unpledge_UsesTheStaticLimit() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        _borrow(0);

        // The borrow limit shrinks as the deadline nears. Withdrawal must not,
        // or a healthy position would be locked out of its own collateral.
        vm.warp(block.timestamp + 80 days);
        vm.prank(alice);
        vault.unpledge(MID, 1e6, 1e6);
    }

    function test_Borrow_RefusedPastTheDeadline() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        vm.startPrank(alice);
        core.split(MID, 10_000e6);
        vault.pledge(MID, 10_000e6, 10_000e6);
        vm.stopPrank();

        vm.warp(vault.deadlineOf(MID) + 1);
        assertEq(vault.availableToBorrow(MID, alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.borrow(MID, 1e6);
    }

    function test_Repay_MaxClearsExactly() public {
        vm.prank(bob);
        vault.deposit(100_000e6);
        _borrow(0);
        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "no dust left behind");
    }

    // --------------------------------------------------------------- helpers

    function _borrow(uint256 want) internal returns (uint256) {
        vm.startPrank(alice);
        core.split(MID, 100_000e6);
        vault.pledge(MID, 100_000e6, 100_000e6);
        uint256 amount = want == 0 ? vault.availableToBorrow(MID, alice) : want;
        vault.borrow(MID, amount);
        vm.stopPrank();
        return amount;
    }

    function _borrowMore() internal {
        uint256 more = vault.availableToBorrow(MID, alice);
        if (more > 0) {
            vm.prank(alice);
            vault.borrow(MID, more);
        }
    }

    function _resolve(MarketTypes.Outcome o) internal {
        if (registry.isResolved(MID)) return;
        vm.prank(proposer);
        registry.proposeOutcome(MID, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);
    }
}
