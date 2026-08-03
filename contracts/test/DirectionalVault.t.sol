// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {MirrorPositionOracle} from "../src/MirrorPositionOracle.sol";
import {DirectionalVault} from "../src/DirectionalVault.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

/// @dev Numbers here follow the published mechanics diagram exactly, so a
///      change in behaviour shows up as a mismatch against the documentation.
contract DirectionalVaultTest is Test {
    MockUSDG usdg;
    MarketRegistry registry;
    AlphaMarketCore core;
    MirrorPositionOracle oracle;
    DirectionalVault vault;

    address relayer = makeAddr("relayer");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address proposer = makeAddr("proposer");
    address writer = makeAddr("writer");

    bytes32 constant MID = keccak256("directional-market");
    uint256 constant BOND = 100e6;
    uint64 constant WINDOW = 2 hours;
    uint256 constant ONE = 1e6;

    uint256 constant PX60 = 600_000;   // 0.60
    uint256 constant PX30 = 300_000;   // 0.30

    uint64 endTime;
    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MarketRegistry(address(usdg), BOND, WINDOW, 0, makeAddr("arbiter"), 1 hours, 7 days);
        core = new AlphaMarketCore(address(usdg), address(registry));
        // maxMoveBps wide open here; a dedicated test covers the guard
        oracle = new MirrorPositionOracle(address(registry), 1 hours, 10_000);
        vault = new DirectionalVault(address(core), address(oracle));

        registry.setRelayer(relayer, true);
        oracle.setWriter(writer, true);

        endTime = uint64(block.timestamp + 30 days);
        vm.prank(relayer);
        registry.registerMarket(MID, endTime, 50_000);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);

        _px(PX60);

        address[4] memory who = [alice, keeper, proposer, address(this)];
        for (uint256 i = 0; i < who.length; i++) {
            usdg.mint(who[i], 5_000_000e6);
            vm.startPrank(who[i]);
            usdg.approve(address(core), type(uint256).max);
            usdg.approve(address(registry), type(uint256).max);
            usdg.approve(address(vault), type(uint256).max);
            yes.approve(address(vault), type(uint256).max);
            no.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vault.fund(200_000e6);
    }

    // ------------------------------------------------------- the whole point

    /// @notice MarginVault lends nothing against a one-sided position. This
    ///         vault exists precisely to serve that user.
    function test_DirectionalPledge_HasBorrowPower() public {
        _pledge(1_000e6);
        assertEq(vault.positionValue(MID, alice), 600e6, "1000 YES at 0.60");
        assertEq(vault.borrowLimit(MID, alice), 180e6, "30% LTV");
        assertEq(vault.liquidationLimit(MID, alice), 300e6, "50% threshold");
        assertGt(vault.availableToBorrow(MID, alice), 0);
    }

    function test_Borrow_UpToLimit() public {
        _pledge(1_000e6);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        vault.borrow(MID, 180e6);
        assertEq(usdg.balanceOf(alice) - before, 180e6);
        assertEq(vault.debtOf(MID, alice), 180e6);
        assertEq(vault.healthBps(MID, alice), 16_666, "300/180");
    }

    function test_Borrow_RevertsAboveLimit() public {
        _pledge(1_000e6);
        vm.prank(alice);
        vm.expectRevert();
        vault.borrow(MID, 181e6);
    }

    // -------------------------------------------------- scenario A: repaid

    function test_ScenarioA_Repaid() public {
        _borrow(1_000e6, 180e6);
        vm.warp(block.timestamp + 25 days);

        uint256 debt = vault.debtOf(MID, alice);
        assertGt(debt, 180e6, "interest accrued");

        vm.startPrank(alice);
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "cleared exactly");
        vault.unpledge(MID, 1_000e6, 0);
        vm.stopPrank();

        assertEq(yes.balanceOf(alice), 1_000e6, "position returned whole");
        assertGt(vault.accruedRevenue(), 0, "protocol earned interest");
    }

    // ---------------------------------------------- scenario B: price falls

    function test_ScenarioB_PriceFall_Liquidation() public {
        _borrow(1_000e6, 180e6);
        _px(PX30);

        assertEq(vault.positionValue(MID, alice), 300e6);
        assertEq(vault.liquidationLimit(MID, alice), 150e6);
        assertLt(vault.healthBps(MID, alice), 10_000, "now liquidatable");

        uint256 k0 = yes.balanceOf(keeper);
        vm.prank(keeper);
        vault.liquidate(MID, alice, 90e6);
        uint256 seized = yes.balanceOf(keeper) - k0;

        // 90 USDG at 0.30 = 300 YES, plus 8% bonus = 324 YES
        assertEq(seized, 324e6, "seized with 8% bonus");
        assertApproxEqAbs(vault.debtOf(MID, alice), 90e6, 1e3, "half the debt closed");

        DirectionalVault.Position memory p = vault.positionOf(MID, alice);
        assertEq(p.yesAmount, 676e6, "user keeps the rest");
        assertGt(vault.healthBps(MID, alice), 10_000, "healthy again");
    }

    function test_Liquidate_RevertsWhileHealthy() public {
        _borrow(1_000e6, 180e6);
        vm.prank(keeper);
        vm.expectRevert();
        vault.liquidate(MID, alice, 50e6);
    }

    function test_Liquidate_CloseFactorCaps() public {
        _borrow(1_000e6, 180e6);
        _px(PX30);
        vm.prank(keeper);
        vault.liquidate(MID, alice, 180e6);
        assertApproxEqAbs(vault.debtOf(MID, alice), 90e6, 1e3, "only 50% closable");
    }

    // ------------------------------------------- scenario C: deadline hit

    /// @notice The structural trigger. At resolution the price jumps to 0 or 1
    ///         in one block, so the loan must be closed before that point
    ///         whether or not the position looks healthy.
    function test_ScenarioC_DeadlineOpensLiquidation() public {
        _borrow(1_000e6, 180e6);
        assertGt(vault.healthBps(MID, alice), 10_000, "healthy at 0.60");

        vm.warp(vault.deadlineOf(MID) + 1);
        _px(PX60);   // the relayer keeps prices fresh every cycle
        assertEq(vault.availableToBorrow(MID, alice), 0, "no new borrowing past deadline");

        // close factor is 100% past the deadline
        vm.prank(keeper);
        vault.liquidate(MID, alice, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "fully closed");
    }

    function test_Borrow_RevertsPastDeadline() public {
        _pledge(1_000e6);
        vm.warp(vault.deadlineOf(MID) + 1);
        vm.prank(alice);
        vm.expectRevert();
        vault.borrow(MID, 10e6);
    }

    function test_Interest_StopsAtDeadline() public {
        _borrow(1_000e6, 180e6);
        vm.warp(vault.deadlineOf(MID));
        uint256 atDeadline = vault.debtOf(MID, alice);
        vm.warp(vault.deadlineOf(MID) + 30 days);
        assertEq(vault.debtOf(MID, alice), atDeadline, "overdue debt cannot inflate");
    }

    // ------------------------------------------ scenario D: no liquidator

    function test_ScenarioD_AbsorbThenSweep_Wins() public {
        _borrow(1_000e6, 180e6);
        _px(PX30);
        vm.warp(vault.deadlineOf(MID) + 1);

        vault.absorb(MID, alice);
        assertEq(vault.debtOf(MID, alice), 0, "debt written off");
        assertGt(vault.badDebt(), 0, "recorded as bad debt, not hidden");
        assertEq(vault.absorbedYes(MID), 1_000e6, "vault holds the position");

        _resolve(MarketTypes.Outcome.Yes);
        vault.sweepAbsorbed(MID);

        assertEq(vault.recovered(), 1_000e6, "redeemed in full");
        assertEq(vault.badDebt(), 0, "recovery exceeded the write-off");
    }

    function test_ScenarioD_AbsorbThenSweep_Loses() public {
        _borrow(1_000e6, 180e6);
        _px(PX30);
        vm.warp(vault.deadlineOf(MID) + 1);
        vault.absorb(MID, alice);
        uint256 written = vault.badDebt();

        _resolve(MarketTypes.Outcome.No);
        vault.sweepAbsorbed(MID);

        assertEq(vault.recovered(), 0, "position was worthless");
        assertEq(vault.badDebt(), written, "loss stands, and is visible");
    }

    function test_Absorb_RevertsBeforeDeadline() public {
        _borrow(1_000e6, 180e6);
        vm.expectRevert();
        vault.absorb(MID, alice);
    }

    function test_Absorb_OnlyOwner() public {
        _borrow(1_000e6, 180e6);
        vm.warp(vault.deadlineOf(MID) + 1);
        vm.prank(keeper);
        vm.expectRevert();
        vault.absorb(MID, alice);
    }

    /// @notice A stale price at the deadline blocks liquidation, because
    ///         seizing needs a price. absorb() is the designed escape hatch and
    ///         deliberately needs no oracle at all.
    function test_StaleAtDeadline_ForcesAbsorbPath() public {
        _borrow(1_000e6, 180e6);
        vm.warp(vault.deadlineOf(MID) + 1);   // price is now far past maxAge

        vm.prank(keeper);
        vm.expectRevert();
        vault.liquidate(MID, alice, 10e6);

        vault.absorb(MID, alice);
        assertEq(vault.debtOf(MID, alice), 0, "absorb works without a price");
        assertEq(vault.absorbedYes(MID), 1_000e6);
    }

    /// @notice Regression: _capitalise once used block.timestamp while debtOf
    ///         used the deadline cutoff, so the stored debt silently outgrew
    ///         the quoted one after the deadline.
    function test_Interest_StateMatchesViewPastDeadline() public {
        _borrow(1_000e6, 180e6);
        vm.warp(vault.deadlineOf(MID) + 10 days);

        uint256 quoted = vault.debtOf(MID, alice);
        vm.prank(alice);
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "quoted debt cleared it exactly");

        DirectionalVault.Position memory p = vault.positionOf(MID, alice);
        assertEq(p.principal, 0, "no hidden residue");
        assertGt(quoted, 180e6);
    }

    // ------------------------------------------------------- safety net

    /// @notice A missed liquidation must not strand collateral forever.
    function test_SettleResolved_ReturnsSurplus() public {
        _borrow(1_000e6, 180e6);
        _resolve(MarketTypes.Outcome.Yes);

        uint256 debt = vault.debtOf(MID, alice);
        uint256 before = usdg.balanceOf(alice);
        vault.settleResolved(MID, alice);

        assertEq(usdg.balanceOf(alice) - before, 1_000e6 - debt, "surplus returned");
        assertEq(vault.debtOf(MID, alice), 0);
    }

    function test_SettleResolved_LosingSideRecordsBadDebt() public {
        _borrow(1_000e6, 180e6);
        _resolve(MarketTypes.Outcome.No);
        vault.settleResolved(MID, alice);
        assertGt(vault.badDebt(), 0, "unbacked residual is recorded");
        assertEq(yes.balanceOf(alice), 1_000e6,
            "worthless tokens go back to the user, not stranded in the vault");
    }

    // ----------------------------------------------------------- risk caps

    function test_MarketDebtCap_Enforced() public {
        vault.setRisk(1500, 100_000e6, 1 hours, 100e6);
        _pledge(1_000e6);
        vm.startPrank(alice);
        vault.borrow(MID, 100e6);
        vm.expectRevert();
        vault.borrow(MID, 1e6);
        vm.stopPrank();
    }

    function test_Unpledge_RevertsIfItBreaksTheLimit() public {
        _borrow(1_000e6, 180e6);
        vm.prank(alice);
        vm.expectRevert();
        vault.unpledge(MID, 500e6, 0);
    }

    // -------------------------------------------------------------- oracle

    function test_StaleOracle_FreezesBorrowAndLiquidation() public {
        _borrow(1_000e6, 100e6);
        vm.warp(block.timestamp + 2 hours);   // maxAge is 1 hour

        vm.prank(alice);
        vm.expectRevert();
        vault.borrow(MID, 1e6);

        vm.prank(keeper);
        vm.expectRevert();
        vault.liquidate(MID, alice, 10e6);
    }

    function test_StaleOracle_RepayStillWorks() public {
        _borrow(1_000e6, 100e6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "exit never depends on a price");
    }

    /// @notice One bad write must not be able to zero every position at once.
    function test_Oracle_MoveCapRejectsAJump() public {
        MirrorPositionOracle o = new MirrorPositionOracle(address(registry), 1 hours, 1_000);
        o.setWriter(writer, true);
        vm.startPrank(writer);
        o.writePrice(MID, PX60);
        vm.expectRevert();
        o.writePrice(MID, 10_000);   // 0.60 -> 0.01 in one step
        o.writePrice(MID, 550_000);  // a 5% step is fine
        vm.stopPrank();
    }

    function test_Oracle_DerivesNoFromYes() public view {
        (uint256 py,) = oracle.priceOf(MID, true);
        (uint256 pn,) = oracle.priceOf(MID, false);
        assertEq(py + pn, ONE, "the two sides can never disagree");
    }

    function test_Oracle_RejectsNonWriter() public {
        vm.prank(alice);
        vm.expectRevert(MirrorPositionOracle.NotWriter.selector);
        oracle.writePrice(MID, PX30);
    }

    // ------------------------------------------------------------ invariant

    /// @notice Health must track price monotonically, with the liquidation
    ///         boundary exactly where the parameters say it is.
    function testFuzz_HealthTracksPrice(uint32 pxRaw) public {
        uint256 px = uint256(pxRaw) % (ONE - 2) + 1;
        _borrow(1_000e6, 180e6);
        _px(px);

        uint256 value = (1_000e6 * px) / ONE;
        uint256 liqLimit = (value * 5000) / 10_000;
        uint256 debt = vault.debtOf(MID, alice);
        assertEq(vault.healthBps(MID, alice) < 10_000, liqLimit < debt);
    }

    // --------------------------------------------------------------- helpers

    function _px(uint256 p) internal {
        vm.prank(writer);
        oracle.writePrice(MID, p);
    }

    function _pledge(uint256 amount) internal {
        vm.startPrank(alice);
        core.split(MID, amount);
        vault.pledge(MID, amount, 0);
        no.transfer(address(0xdead), amount);   // keep only the YES side
        vm.stopPrank();
    }

    function _borrow(uint256 amount, uint256 debt) internal {
        _pledge(amount);
        vm.prank(alice);
        vault.borrow(MID, debt);
    }

    function _resolve(MarketTypes.Outcome o) internal {
        vm.prank(proposer);
        registry.proposeOutcome(MID, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);
    }
}
