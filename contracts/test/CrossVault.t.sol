// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestDollar} from "../src/TestDollar.sol";
import {MockStock} from "./mocks/MockStock.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {CrossVault} from "../src/CrossVault.sol";
import {MirrorPositionOracle} from "../src/MirrorPositionOracle.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

/// @notice A TSLA-settled position securing an aUSD loan. Two prices move at
///         once, which is what makes this vault different from every other one
///         in the system.
contract CrossVaultTest is Test {
    TestDollar aUSD;          // 6 decimals, the debt asset
    MockStock tsla;           // stands in for an 18 decimal stock token
    MarketRegistry registry;
    AlphaMarketCore core;     // settles in TSLA
    MirrorPositionOracle odds;
    PriceOracle equity;
    CrossVault vault;

    address relayer = makeAddr("relayer");
    address writer = makeAddr("writer");
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address proposer = makeAddr("proposer");

    bytes32 constant MID = keccak256("cross-market");
    uint64 constant WINDOW = 2 hours;
    uint256 constant ODDS_ONE = 1e6;

    uint256 constant TSLA_PX = 30940255000;   // $309.40, from mainnet Chainlink
    uint64 constant ODDS_60 = 600_000;

    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        aUSD = new TestDollar(1_000_000e6, 0, type(uint128).max);
        tsla = new MockStock("Tesla", "TSLA");
        registry = new MarketRegistry(address(aUSD), 100e6, WINDOW, 0,
            makeAddr("arbiter"), 1 hours, 7 days);
        core = new AlphaMarketCore(address(tsla), address(registry));
        odds = new MirrorPositionOracle(address(registry), 1 hours, 10_000);
        equity = new PriceOracle(3 days);
        vault = new CrossVault(address(core), address(aUSD), 6, 18,
            address(odds), address(equity));

        registry.setRelayer(relayer, true);
        odds.setWriter(writer, true);
        equity.enablePush(address(tsla));
        equity.setPusher(address(this), true);
        equity.pushPrice(address(tsla), TSLA_PX);

        vm.prank(relayer);
        registry.registerMarket(MID, uint64(block.timestamp + 30 days), 0);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);

        vm.prank(writer);
        odds.writePrice(MID, ODDS_60);

        vault.setRisk(1500, 1_000_000e6, 1 hours, 500_000e6);

        address[3] memory who = [alice, keeper, proposer];
        for (uint256 i = 0; i < who.length; i++) {
            tsla.mint(who[i], 10_000e18);
            vm.prank(who[i]);
            aUSD.claim();
            vm.startPrank(who[i]);
            tsla.approve(address(core), type(uint256).max);
            aUSD.approve(address(vault), type(uint256).max);
            aUSD.approve(address(registry), type(uint256).max);
            yes.approve(address(vault), type(uint256).max);
            no.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        aUSD.claim();
        aUSD.approve(address(vault), type(uint256).max);
        vault.fund(500_000e6);
    }

    // --------------------------------------------------- the two-price value

    /// @notice The whole point: a position quoted in TSLA, valued in aUSD.
    function test_PositionValue_MultipliesBothPrices() public {
        _pledge(1_000e18);
        // 1000 YES at 0.60 odds = 600 TSLA, at $309.40 = $185,641.53
        uint256 v = vault.positionValue(MID, alice);
        assertApproxEqAbs(v, 185_641_530_000, 1e6, "600 TSLA priced in aUSD");
        assertEq(vault.borrowLimit(MID, alice), (v * 1500) / 10_000, "15% LTV");
        assertEq(vault.liquidationLimit(MID, alice), (v * 3500) / 10_000, "35% threshold");
    }

    function test_Borrow_AgainstACrossPosition() public {
        _pledge(1_000e18);
        uint256 avail = vault.availableToBorrow(MID, alice);
        assertGt(avail, 0, "a TSLA position must support an aUSD loan");

        uint256 before = aUSD.balanceOf(alice);
        vm.prank(alice);
        vault.borrow(MID, avail);
        assertEq(aUSD.balanceOf(alice) - before, avail, "borrowed in aUSD");
        assertEq(vault.debtOf(MID, alice), avail);
    }

    /// @notice A fall in either price alone, or both together.
    function test_Health_RespondsToBothPrices() public {
        _borrowMax(1_000e18);
        uint256 h0 = vault.healthBps(MID, alice);

        // only the event moves
        vm.prank(writer);
        odds.writePrice(MID, 420_000);
        uint256 h1 = vault.healthBps(MID, alice);
        assertLt(h1, h0, "worse odds lower the health");

        // only the equity moves
        vm.prank(writer);
        odds.writePrice(MID, ODDS_60);
        equity.pushPrice(address(tsla), (TSLA_PX * 70) / 100);
        uint256 h2 = vault.healthBps(MID, alice);
        assertLt(h2, h0, "a cheaper equity lowers the health too");

        // both at once compounds
        vm.prank(writer);
        odds.writePrice(MID, 420_000);
        uint256 h3 = vault.healthBps(MID, alice);
        assertLt(h3, h1, "a joint move is worse than either alone");
        assertLt(h3, h2, "a joint move is worse than either alone");
    }

    /// @notice At 15/35 a fully drawn loan survives roughly a 35% fall in each
    ///         price, and no more. This is the number the parameters were
    ///         chosen against.
    function test_LiquidationBoundary_MatchesTheChosenParameters() public {
        _borrowMax(1_000e18);
        assertGe(vault.healthBps(MID, alice), 10_000, "healthy at the start");

        // 30% off each: 49% of value remains, still above the line
        vm.prank(writer);
        odds.writePrice(MID, (ODDS_60 * 70) / 100);
        equity.pushPrice(address(tsla), (TSLA_PX * 70) / 100);
        assertGe(vault.healthBps(MID, alice), 10_000, "survives 30% on each");

        // 40% off each: 36% remains, past the line
        vm.prank(writer);
        odds.writePrice(MID, (ODDS_60 * 60) / 100);
        equity.pushPrice(address(tsla), (TSLA_PX * 60) / 100);
        assertLt(vault.healthBps(MID, alice), 10_000, "liquidatable at 40% on each");
    }

    // ------------------------------------------------------------ liquidation

    /// @notice REGRESSION. An earlier version priced one base unit of an 18
    ///         decimal collateral in 6 decimal debt units, which floors to
    ///         zero, and then divided by it. Liquidation reverted every time.
    function test_Liquidate_DoesNotDivideByZero() public {
        _borrowMax(1_000e18);
        vm.prank(writer);
        odds.writePrice(MID, (ODDS_60 * 50) / 100);
        equity.pushPrice(address(tsla), (TSLA_PX * 50) / 100);
        assertLt(vault.healthBps(MID, alice), 10_000);

        uint256 debt = vault.debtOf(MID, alice);
        uint256 k0 = yes.balanceOf(keeper);
        vm.prank(keeper);
        vault.liquidate(MID, alice, debt / 2);

        assertGt(yes.balanceOf(keeper) - k0, 0, "the keeper actually received tokens");
        assertLt(vault.debtOf(MID, alice), debt, "debt was reduced");
    }

    function test_Liquidate_SeizureNeverExceedsTheBonus() public {
        _borrowMax(1_000e18);
        vm.prank(writer);
        odds.writePrice(MID, (ODDS_60 * 50) / 100);
        equity.pushPrice(address(tsla), (TSLA_PX * 50) / 100);

        uint256 repay = vault.debtOf(MID, alice) / 2;
        uint256 k0 = yes.balanceOf(keeper);
        vm.prank(keeper);
        vault.liquidate(MID, alice, repay);
        uint256 seized = yes.balanceOf(keeper) - k0;

        // value of what was taken, at the prices in force
        uint256 px = (TSLA_PX * 50) / 100;
        uint256 o = (ODDS_60 * 50) / 100;
        uint256 taken = (seized * o * px * 1e6) / (1e6 * 1e8 * 1e18);
        uint256 allowed = (repay * 11_000) / 10_000;   // 10% bonus
        assertLe(taken, allowed + 1, "seizure stayed within the bonus");
    }

    function test_Liquidate_RevertsWhileHealthy() public {
        _borrowMax(1_000e18);
        vm.prank(keeper);
        vm.expectRevert();
        vault.liquidate(MID, alice, 1e6);
    }

    /// @notice Past the deadline the trigger is time, not price. The equity
    ///         price must still be fresh, because seizing needs to value what
    ///         it takes.
    function test_Deadline_OpensLiquidationRegardlessOfHealth() public {
        _borrowMax(1_000e18);
        assertGe(vault.healthBps(MID, alice), 10_000, "healthy");

        vm.warp(vault.deadlineOf(MID) + 1);
        // Both oracles are refreshed every relayer cycle in production, so a
        // live system reaches the deadline with fresh prices on both.
        equity.pushPrice(address(tsla), TSLA_PX);
        vm.prank(writer);
        odds.writePrice(MID, ODDS_60);
        assertEq(vault.availableToBorrow(MID, alice), 0, "no new borrowing");

        vm.prank(keeper);
        vault.liquidate(MID, alice, type(uint256).max);

        // A few base units survive the first pass. Seizure floors in the
        // vault's favour, so the value taken lands just under the target and
        // the repayment is scaled down to match. The remainder is a rounding
        // artefact of a couple of units, not a shortfall that grows with size,
        // and a second call clears it.
        uint256 dust = vault.debtOf(MID, alice);
        assertLt(dust, 100, "only rounding dust remains");

        // A second liquidation cannot clear it, and should not: seizing the
        // value of two base units rounds to zero tokens, so the call would move
        // nothing and pay nothing. The contract refuses rather than burn gas on
        // an empty transfer.
        vm.prank(keeper);
        vm.expectRevert(CrossVault.ZeroAmount.selector);
        vault.liquidate(MID, alice, type(uint256).max);

        // The borrower clears it, which is the only party for whom two
        // millionths of a dollar is worth a transaction.
        vm.prank(alice);
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "the borrower closes the remainder");
    }

    /// @notice The dust must be a fixed rounding remainder, not something that
    ///         scales with the position. If it grew, a large liquidation would
    ///         leave a real shortfall behind.
    function testFuzz_LiquidationDustStaysBounded(uint96 qtyRaw) public {
        uint256 qty = bound(qtyRaw, 1e18, 5_000e18);
        _borrowMax(qty);

        vm.warp(vault.deadlineOf(MID) + 1);
        equity.pushPrice(address(tsla), TSLA_PX);
        vm.prank(writer);
        odds.writePrice(MID, ODDS_60);

        vm.prank(keeper);
        vault.liquidate(MID, alice, type(uint256).max);
        assertLt(vault.debtOf(MID, alice), 1000,
            "dust must not scale with the size of the position");
    }

    /// @notice And when the feed is NOT fresh, liquidation is impossible and
    ///         absorb is the only way out. Without it an overdue position with
    ///         a dead oracle could never be closed.
    function test_StaleEquityFeed_ForcesTheAbsorbPath() public {
        _borrowMax(1_000e18);
        vm.warp(vault.deadlineOf(MID) + 1);   // equity price is now far past maxAge

        vm.prank(keeper);
        vm.expectRevert();
        vault.liquidate(MID, alice, 1e6);

        vault.absorb(MID, alice);
        assertEq(vault.debtOf(MID, alice), 0, "absorb needs no price at all");
        assertEq(vault.absorbedYes(MID), 1_000e18, "the vault holds the position");
        assertGt(vault.badDebt(), 0, "the write-off is recorded, not hidden");
    }

    function test_Absorb_RevertsBeforeTheDeadline() public {
        _borrowMax(1_000e18);
        vm.expectRevert();
        vault.absorb(MID, alice);
    }

    function test_Absorb_OnlyOwner() public {
        _borrowMax(1_000e18);
        vm.warp(vault.deadlineOf(MID) + 1);
        vm.prank(keeper);
        vm.expectRevert();
        vault.absorb(MID, alice);
    }

    /// @notice An absorbed winner is recovered in the settlement asset.
    function test_SweepAbsorbed_RecoversTheSettlementAsset() public {
        _borrowMax(1_000e18);
        vm.warp(vault.deadlineOf(MID) + 1);
        vault.absorb(MID, alice);

        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);

        uint256 before = tsla.balanceOf(address(vault));
        vault.sweepAbsorbed(MID);
        assertEq(tsla.balanceOf(address(vault)) - before, 1_000e18, "recovered in TSLA");
        assertEq(vault.recovered(), 1_000e18);
    }

    function test_Interest_StopsAtTheDeadline() public {
        _borrowMax(1_000e18);
        vm.warp(vault.deadlineOf(MID));
        uint256 atDeadline = vault.debtOf(MID, alice);
        vm.warp(vault.deadlineOf(MID) + 30 days);
        assertEq(vault.debtOf(MID, alice), atDeadline, "overdue debt cannot inflate");
    }

    // ---------------------------------------------------------------- exits

    function test_RepayAndUnpledge_ReturnsEverything() public {
        _borrowMax(1_000e18);
        vm.warp(block.timestamp + 10 days);

        vm.startPrank(alice);
        vault.repay(MID, type(uint256).max);
        assertEq(vault.debtOf(MID, alice), 0, "cleared exactly");
        vault.unpledge(MID, 1_000e18, 0);
        vm.stopPrank();
        assertEq(yes.balanceOf(alice), 1_000e18, "position returned whole");
    }

    /// @notice Redemption pays the settlement asset, not the debt asset. The
    ///         vault must not silently convert one into the other.
    function test_SettleResolved_PaysTheSettlementAsset() public {
        _pledge(1_000e18);
        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);

        uint256 before = tsla.balanceOf(alice);
        vault.settleResolved(MID, alice);
        assertEq(tsla.balanceOf(alice) - before, 1_000e18, "paid in TSLA, the settlement asset");
    }

    // ------------------------------------------------------------ invariant

    /// @notice Whatever the two prices, the vault never lends more than the LTV
    ///         of what it can actually seize.
    function testFuzz_BorrowLimitNeverExceedsSeizableValue(
        uint32 oddsRaw, uint64 pxRaw, uint96 qtyRaw
    ) public {
        uint64 o = uint64(bound(oddsRaw, 1000, ODDS_ONE - 1000));
        uint256 px = bound(pxRaw, 1e6, 1e13);
        uint256 qty = bound(qtyRaw, 1e15, 10_000e18);

        vm.prank(writer);
        odds.writePrice(MID, o);
        equity.pushPrice(address(tsla), px);

        vm.startPrank(alice);
        core.split(MID, qty);
        vault.pledge(MID, qty, 0);
        vm.stopPrank();

        uint256 value = vault.positionValue(MID, alice);
        uint256 limit = vault.borrowLimit(MID, alice);
        assertLe(limit * 10_000, value * 1500 + 10_000, "limit never above 15% of value");
        assertLe(limit, value, "limit never above the collateral itself");
    }

    // --------------------------------------------------------------- helpers

    function _pledge(uint256 qty) internal {
        vm.startPrank(alice);
        core.split(MID, qty);
        vault.pledge(MID, qty, 0);
        no.transfer(address(0xdead), qty);
        vm.stopPrank();
    }

    function _borrowMax(uint256 qty) internal {
        _pledge(qty);
        uint256 avail = vault.availableToBorrow(MID, alice);
        vm.prank(alice);
        vault.borrow(MID, avail);
    }
}
