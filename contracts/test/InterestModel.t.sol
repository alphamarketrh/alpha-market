// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {InterestModel} from "../src/InterestModel.sol";

/// @notice The rate curve. Every property here is one a borrower or a
///         depositor would notice immediately if it broke.
contract InterestModelTest is Test {
    InterestModel m;

    uint256 constant BPS = 10_000;
    uint256 constant BASE = 200;      // 2% when nothing is drawn
    uint256 constant SLOPE1 = 1300;   // 15% by the kink
    uint256 constant SLOPE2 = 4500;   // 60% when fully drawn
    uint256 constant KINK = 8000;     // the second slope starts at 80%

    address alice = makeAddr("alice");

    function setUp() public {
        m = new InterestModel(BASE, SLOPE1, SLOPE2, KINK);
    }

    // ------------------------------------------------------------ the curve

    function test_Curve_HitsItsStatedPoints() public view {
        assertEq(m.rateAt(0), 200, "2% at zero");
        assertEq(m.rateAt(KINK), 1500, "15% at the kink");
        assertEq(m.rateAt(BPS), 6000, "60% at full");
    }

    /// @notice A rate that could fall as more is borrowed would reward
    ///         draining the facility.
    function testFuzz_RateNeverFallsAsUtilisationRises(uint16 aRaw, uint16 bRaw) public view {
        uint256 a = bound(aRaw, 0, BPS);
        uint256 b = bound(bRaw, 0, BPS);
        if (a > b) (a, b) = (b, a);
        assertLe(m.rateAt(a), m.rateAt(b), "monotonic");
    }

    function test_SecondSlopeIsSteeper() public view {
        uint256 below = m.rateAt(KINK) - m.rateAt(KINK - 500);
        uint256 above = m.rateAt(KINK + 500) - m.rateAt(KINK);
        assertGt(above, below, "past the kink the cost climbs faster");
    }

    // ------------------------------------------------------- utilisation

    function test_Utilisation_HandlesAnEmptyFacility() public view {
        assertEq(m.utilisation(0, 0), 0, "no supply is zero, not a revert");
        assertEq(m.utilisation(100, 0), 0, "debt without supply does not divide by zero");
    }

    /// @notice Interest can push debt past the principal ever supplied. Without
    ///         a clamp the second slope would run off the end of its range.
    function test_Utilisation_ClampsAboveFull() public view {
        assertEq(m.utilisation(150, 100), BPS, "clamped to 100%");
        assertEq(m.rateAt(m.utilisation(150, 100)), 6000, "and the rate stays at the ceiling");
    }

    function testFuzz_UtilisationNeverExceedsFull(uint128 b, uint128 s) public view {
        assertLe(m.utilisation(b, s), BPS);
    }

    // -------------------------------------------------------- supply rate

    /// @notice The load-bearing property. If depositors could earn more than
    ///         borrowers pay, the facility drains itself.
    function testFuzz_SupplyRateNeverExceedsBorrowRate(uint16 uRaw, uint16 rRaw) public view {
        uint256 u = bound(uRaw, 0, BPS);
        uint256 reserve = bound(rRaw, 0, BPS - 1);
        uint256 supplied = 1_000_000e6;
        uint256 borrowed = (supplied * u) / BPS;
        assertLe(
            m.supplyRate(borrowed, supplied, reserve),
            m.borrowRate(borrowed, supplied),
            "depositors cannot out-earn borrowers"
        );
    }

    function test_SupplyRate_IsZeroWhenNothingIsLent() public view {
        assertEq(m.supplyRate(0, 1_000_000e6, 1000), 0, "idle supply earns nothing");
    }

    function test_SupplyRate_TakesTheReserveShare() public view {
        uint256 s = 1_000_000e6;
        uint256 b = (s * 8000) / BPS;
        uint256 none = m.supplyRate(b, s, 0);
        uint256 tenth = m.supplyRate(b, s, 1000);
        assertApproxEqAbs(tenth, (none * 9) / 10, 1, "a tenth is withheld");
    }

    function test_SupplyRate_ZeroWhenTheReserveTakesEverything() public view {
        assertEq(m.supplyRate(500, 1000, BPS), 0, "a full reserve leaves nothing");
    }

    // ------------------------------------------------------------- limits

    /// @notice An owner who could raise the rate without bound could make any
    ///         loan unrepayable, which is the same as seizing the collateral.
    function test_Ceiling_CannotBeExceeded() public {
        vm.expectRevert(InterestModel.BadParams.selector);
        m.setParams(10_000, 10_000, 10_000, KINK);

        m.setParams(5000, 5000, 10_000, KINK);
        assertEq(m.rateAt(BPS), m.MAX_RATE_BPS(), "exactly at the ceiling is allowed");
    }

    function test_Kink_CannotSitAtEitherExtreme() public {
        vm.expectRevert(InterestModel.BadParams.selector);
        m.setParams(BASE, SLOPE1, SLOPE2, 0);
        vm.expectRevert(InterestModel.BadParams.selector);
        m.setParams(BASE, SLOPE1, SLOPE2, BPS);
    }

    function test_OnlyOwnerCanChangeTheCurve() public {
        vm.prank(alice);
        vm.expectRevert(InterestModel.NotOwner.selector);
        m.setParams(BASE, SLOPE1, SLOPE2, KINK);

        vm.prank(alice);
        vm.expectRevert(InterestModel.NotOwner.selector);
        m.setOwner(alice);
    }

    function test_OwnerCanBeHandedOver() public {
        m.setOwner(alice);
        assertEq(m.owner(), alice);
        vm.prank(alice);
        m.setParams(100, 100, 100, 5000);
        assertEq(m.baseBps(), 100);
    }

    function test_Owner_CannotBeZero() public {
        vm.expectRevert(InterestModel.ZeroAddress.selector);
        m.setOwner(address(0));
    }

    /// @notice Whatever the parameters, the rate stays inside the ceiling.
    function testFuzz_RateStaysWithinTheCeiling(
        uint16 base_, uint16 s1, uint16 s2, uint16 kink_, uint16 u
    ) public {
        uint256 b = bound(base_, 0, 5000);
        uint256 x = bound(s1, 0, 5000);
        uint256 y = bound(s2, 0, 10_000);
        uint256 k = bound(kink_, 1, BPS - 1);
        vm.assume(b + x + y <= m.MAX_RATE_BPS());

        m.setParams(b, x, y, k);
        assertLe(m.rateAt(bound(u, 0, BPS)), m.MAX_RATE_BPS(), "never above the ceiling");
    }
}
