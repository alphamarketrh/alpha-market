// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

contract MarginVaultTest is Test {
    MockUSDG usdg;
    MarketRegistry registry;
    AlphaMarketCore core;
    MarginVault vault;

    address relayer = makeAddr("relayer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address proposer = makeAddr("proposer");

    bytes32 constant MID = keccak256("cond-1");
    uint256 constant BOND = 100e6;
    uint64 constant WINDOW = 2 hours;
    uint256 constant HAIRCUT = 500;      // 5%
    uint256 constant RATE = 1500;        // 15% APR
    uint256 constant CAP = 1_000_000e6;

    uint64 endTime;
    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MarketRegistry(address(usdg), BOND, WINDOW, 25_000, makeAddr("arbiter"), 1 hours, 7 days);
        core = new AlphaMarketCore(address(usdg), address(registry));
        vault = new MarginVault(address(core), HAIRCUT, RATE, CAP);
        registry.setRelayer(relayer, true);

        endTime = uint64(block.timestamp + 90 days);
        vm.prank(relayer);
        registry.registerMarket(MID, endTime, 50_000);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);

        address[4] memory who = [alice, bob, proposer, address(this)];
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
        vault.fund(500_000e6);
    }

    // ------------------------------------------------------------ the floor

    function test_Floor_IsMinOfBothSides() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        vault.pledge(MID, 1_000e6, 600e6);
        assertEq(vault.floorOf(MID, alice), 600e6, "floor = min(Y,N)");
    }

    function test_DirectionalOnly_HasZeroBorrowPower() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        vault.pledge(MID, 1_000e6, 0);
        assertEq(vault.floorOf(MID, alice), 0);
        assertEq(vault.availableToBorrow(MID, alice), 0, "one-sided lends nothing");
    }

    function test_Borrow_UpToFloorMinusHaircutAndInterest() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);

        uint256 avail = vault.availableToBorrow(MID, alice);
        // limit is 95% of floor; headroom is reduced further to reserve all
        // interest that can accrue between now and market end
        assertLt(avail, 950e6, "headroom reserves future interest");
        assertGt(avail, 800e6);

        // regression: borrowing the full advertised amount must not revert
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        vault.borrow(MID, avail);
        assertEq(usdg.balanceOf(alice) - before, avail);
        assertEq(vault.availableToBorrow(MID, alice), 0, "headroom exhausted");
    }

    function test_Borrow_RevertsAboveFloor() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vm.prank(alice);
        vm.expectRevert();
        vault.borrow(MID, 960e6);
    }

    function test_Unpledge_RevertsIfItBreaksTheFloor() public {
        _split(alice, 1_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vault.borrow(MID, 500e6);
        vm.expectRevert();
        vault.unpledge(MID, 0, 600e6);   // would drop floor to 400
        vault.unpledge(MID, 0, 300e6);   // floor 700, still fine
        vm.stopPrank();
        assertEq(vault.floorOf(MID, alice), 700e6);
    }

    // ------------------------------------------------------------- interest

    function test_Interest_AccruesIntoState() public {
        _split(alice, 1_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vault.borrow(MID, 500e6);
        vm.stopPrank();

        assertEq(vault.debtOf(MID, alice), 500e6, "no time passed");
        vm.warp(block.timestamp + 365 days / 2);

        uint256 d = vault.debtOf(MID, alice);
        assertGt(d, 500e6, "interest accrues");

        // borrowing 0 is rejected, so use repay(1) to force capitalisation
        vm.prank(alice);
        vault.repay(MID, 1);
        MarginVault.Position memory p = vault.positionOf(MID, alice);
        assertGt(p.principal, 500e6 - 1, "interest folded into state");
        assertGt(p.interestOwed, 0, "interest tracked for revenue");
    }

    function test_Interest_StopsAtMarketEnd() public {
        _split(alice, 1_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vault.borrow(MID, 500e6);
        vm.stopPrank();

        vm.warp(endTime);
        uint256 atEnd = vault.debtOf(MID, alice);
        vm.warp(endTime + 3650 days);
        assertEq(vault.debtOf(MID, alice), atEnd, "debt is bounded");
    }

    function test_Repay_PaysInterestFirstThenPrincipal() public {
        _split(alice, 1_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vault.borrow(MID, 500e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days / 2);
        uint256 debt = vault.debtOf(MID, alice);

        vm.prank(alice);
        vault.repay(MID, debt);
        assertEq(vault.debtOf(MID, alice), 0, "cleared exactly");
        assertGt(vault.accruedRevenue(), 0, "lender earned interest");
    }

    function test_Repay_MaxClearsDebtExactly() public {
        _split(alice, 1_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 1_000e6, 1_000e6);
        vault.borrow(MID, 500e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        uint256 quoted = vault.debtOf(MID, alice);
        vm.warp(block.timestamp + 1 hours);

        vm.startPrank(alice);
        vault.repay(MID, quoted);
        assertGt(vault.debtOf(MID, alice), 0, "stale quote leaves dust");
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "max clears it");
        vault.unpledge(MID, 1_000e6, 1_000e6);
        vm.stopPrank();
        assertEq(vault.floorOf(MID, alice), 0, "collateral released");
    }

    // ------------------------------------------------------------ settlement

    function test_Settle_YesWins_DebtCovered() public {
        _pledgeAndBorrow(alice, 1_000e6, 1_000e6, 800e6);
        _resolve(MarketTypes.Outcome.Yes);

        // interest accrues across the challenge window, so net against real debt
        uint256 debt = vault.debtOf(MID, alice);
        assertGt(debt, 800e6, "window interest accrued");

        uint256 before = usdg.balanceOf(alice);
        vault.settle(MID, alice);
        uint256 got = usdg.balanceOf(alice) - before;

        assertEq(got, 1_000e6 - debt, "surplus returned, debt netted");
        assertEq(vault.debtOf(MID, alice), 0);
    }

    function test_Settle_NoWins_DebtCovered() public {
        _pledgeAndBorrow(alice, 1_000e6, 1_000e6, 800e6);
        _resolve(MarketTypes.Outcome.No);
        uint256 debt = vault.debtOf(MID, alice);
        uint256 before = usdg.balanceOf(alice);
        vault.settle(MID, alice);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6 - debt);
    }

    function test_Settle_Invalid_DebtCovered() public {
        _pledgeAndBorrow(alice, 1_000e6, 1_000e6, 800e6);
        _resolve(MarketTypes.Outcome.Invalid);
        uint256 debt = vault.debtOf(MID, alice);
        uint256 before = usdg.balanceOf(alice);
        vault.settle(MID, alice);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6 - debt);
    }

    /// @notice Regression: a one-sided pledge on the losing side redeems for
    ///         nothing. Without the guard the tokens are stranded forever.
    function test_Settle_LosingSideOnly_ReturnsTokensNotStranded() public {
        _split(alice, 1_000e6);
        vm.prank(alice);
        vault.pledge(MID, 0, 1_000e6);      // NO only
        _resolve(MarketTypes.Outcome.Yes);   // NO is worthless

        vault.settle(MID, alice);
        assertEq(no.balanceOf(alice), 1_000e6, "worthless tokens returned");
        assertEq(no.balanceOf(address(vault)), 0, "nothing stranded");
    }

    function test_Settle_IsPermissionless() public {
        _pledgeAndBorrow(alice, 1_000e6, 1_000e6, 800e6);
        _resolve(MarketTypes.Outcome.Yes);
        vm.prank(bob);
        vault.settle(MID, alice);
        assertEq(vault.debtOf(MID, alice), 0);
    }

    function test_Settle_RevertsBeforeResolution() public {
        _pledgeAndBorrow(alice, 1_000e6, 1_000e6, 500e6);
        vm.expectRevert(MarginVault.MarketNotResolved.selector);
        vault.settle(MID, alice);
    }

    // -------------------------------------------------------------- facility

    function test_FacilityCap_Enforced() public {
        vault.setParams(HAIRCUT, 0, 100e6);
        _split(alice, 10_000e6);
        vm.startPrank(alice);
        vault.pledge(MID, 10_000e6, 10_000e6);
        vm.expectRevert();
        vault.borrow(MID, 200e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- invariant

    /// @notice The whole design in one property: whatever the outcome, the
    ///         position always redeems for at least the debt. No oracle, no
    ///         liquidation, no bad debt.
    function testFuzz_SettlementAlwaysCoversDebt(
        uint96 yRaw,
        uint96 nRaw,
        uint16 borrowPct,
        uint32 elapsed,
        uint8 outcomeSeed
    ) public {
        uint256 y = uint256(yRaw) % 100_000e6 + 1e6;
        uint256 n = uint256(nRaw) % 100_000e6 + 1e6;

        _split(alice, y > n ? y : n);
        vm.prank(alice);
        vault.pledge(MID, y, n);

        uint256 avail = vault.availableToBorrow(MID, alice);
        uint256 amount = avail * (uint256(borrowPct) % 10_001) / 10_000;
        if (amount > 0) {
            vm.prank(alice);
            vault.borrow(MID, amount);
        }

        vm.warp(block.timestamp + (uint256(elapsed) % 200 days));

        MarketTypes.Outcome o = [
            MarketTypes.Outcome.Yes,
            MarketTypes.Outcome.No,
            MarketTypes.Outcome.Invalid
        ][outcomeSeed % 3];
        _resolve(o);

        uint256 debt = vault.debtOf(MID, alice);
        uint256 expected = o == MarketTypes.Outcome.Yes
            ? y
            : (o == MarketTypes.Outcome.No ? n : (y + n) / 2);

        assertGe(expected, debt, "SOLVENCY: redemption always covers debt");

        vault.settle(MID, alice);   // must never revert
        assertEq(vault.debtOf(MID, alice), 0);
    }

    // --------------------------------------------------------------- helpers

    function _split(address who, uint256 amount) internal {
        vm.prank(who);
        core.split(MID, amount);
    }

    function _pledgeAndBorrow(address who, uint256 y, uint256 n, uint256 amount) internal {
        _split(who, y > n ? y : n);
        vm.startPrank(who);
        vault.pledge(MID, y, n);
        vault.borrow(MID, amount);
        vm.stopPrank();
    }

    function _resolve(MarketTypes.Outcome o) internal {
        vm.prank(proposer);
        registry.proposeOutcome(MID, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);
    }
}
