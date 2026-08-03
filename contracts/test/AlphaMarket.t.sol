// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

contract AlphaMarketTest is Test {
    MockUSDG usdg;
    MarketRegistry registry;
    AlphaMarketCore core;

    address owner = address(this);
    address relayer = makeAddr("relayer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address proposer = makeAddr("proposer");
    address disputer = makeAddr("disputer");
    address arbiter = makeAddr("arbiter");

    bytes32 constant MID = keccak256("polymarket-condition-1");
    uint256 constant BOND = 100e6;          // 100 USDG
    uint64 constant WINDOW = 2 hours;
    uint128 constant DEPTH_FLOOR = 25_000;  // whole USD
    uint64 constant RULING_DELAY = 1 hours;
    uint64 constant DISPUTE_TIMEOUT = 7 days;
    uint64 endTime;

    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MarketRegistry(address(usdg), BOND, WINDOW, DEPTH_FLOOR,
            arbiter, RULING_DELAY, DISPUTE_TIMEOUT);
        core = new AlphaMarketCore(address(usdg), address(registry));
        registry.setRelayer(relayer, true);

        endTime = uint64(block.timestamp + 30 days);
        vm.prank(relayer);
        registry.registerMarket(MID, endTime, 50_000);

        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y);
        no = OutcomeToken(n);

        for (uint256 i = 0; i < 5; i++) {
            address a = [alice, bob, proposer, disputer, owner][i];
            usdg.mint(a, 1_000_000e6);
            vm.prank(a);
            usdg.approve(address(core), type(uint256).max);
            vm.prank(a);
            usdg.approve(address(registry), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ mirroring

    function test_RegisterMarket_SetsActiveAndIndexes() public view {
        assertEq(uint8(registry.statusOf(MID)), uint8(MarketTypes.Status.Active));
        assertEq(registry.marketCount(), 1);
        assertTrue(registry.isTradeable(MID));
    }

    function test_RegisterMarket_RevertsBelowDepthFloor() public {
        bytes32 thin = keccak256("thin");
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(MarketRegistry.DepthBelowFloor.selector, uint128(100), DEPTH_FLOOR)
        );
        registry.registerMarket(thin, endTime, 100);
    }

    function test_RegisterMarket_RevertsForNonRelayer() public {
        vm.prank(alice);
        vm.expectRevert(MarketRegistry.NotRelayer.selector);
        registry.registerMarket(keccak256("x"), endTime, 50_000);
    }

    function test_UpdateDepth_AutoHaltsWhenBelowFloor() public {
        vm.prank(relayer);
        registry.updateDepth(MID, 1_000);
        assertEq(uint8(registry.statusOf(MID)), uint8(MarketTypes.Status.Halted));
        assertFalse(registry.isTradeable(MID));
    }

    // ------------------------------------------------------- split / merge

    function test_Split_MintsEqualYesAndNo() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        assertEq(yes.balanceOf(alice), 1_000e6);
        assertEq(no.balanceOf(alice), 1_000e6);
        assertEq(usdg.balanceOf(address(core)), 1_000e6);
    }

    function test_Split_RevertsWhenHalted() public {
        vm.prank(relayer);
        registry.halt(MID, "source proposal observed");
        vm.prank(alice);
        vm.expectRevert(AlphaMarketCore.MarketNotTradeable.selector);
        core.split(MID, 1_000e6);
    }

    /// @dev A hedged pair is worth exactly one unit whatever happens, so exit
    ///      must stay open even while trading is frozen.
    function test_Merge_OpenEvenWhenHalted() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.prank(relayer);
        registry.halt(MID, "source proposal observed");

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        core.merge(MID, 400e6);
        assertEq(usdg.balanceOf(alice) - before, 400e6);
        assertEq(yes.balanceOf(alice), 600e6);
    }

    function test_Merge_RevertsAfterResolution() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _resolve(MarketTypes.Outcome.Yes);
        vm.prank(alice);
        vm.expectRevert(AlphaMarketCore.MarketAlreadyResolved.selector);
        core.merge(MID, 100e6);
    }

    function test_OutcomeTokens_AreTransferable() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.prank(alice);
        yes.transfer(bob, 250e6);
        assertEq(yes.balanceOf(bob), 250e6);

        _resolve(MarketTypes.Outcome.Yes);
        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        core.redeem(MID, 250e6, 0);
        assertEq(usdg.balanceOf(bob) - before, 250e6, "payout follows the holder");
    }

    // ----------------------------------------------------------- redemption

    function test_Redeem_YesWins() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _resolve(MarketTypes.Outcome.Yes);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        core.redeem(MID, 1_000e6, 1_000e6);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6);
        assertEq(yes.balanceOf(alice), 0);
        assertEq(no.balanceOf(alice), 0);
    }

    function test_Redeem_NoWins() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _resolve(MarketTypes.Outcome.No);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        core.redeem(MID, 0, 1_000e6);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6);
    }

    function test_Redeem_InvalidPaysHalfEachSide() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _resolve(MarketTypes.Outcome.Invalid);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        core.redeem(MID, 1_000e6, 0);
        assertEq(usdg.balanceOf(alice) - before, 500e6);
    }

    function test_Redeem_RevertsBeforeResolution() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(AlphaMarketCore.MarketNotResolved.selector);
        core.redeem(MID, 1_000e6, 0);
    }

    // ---------------------------------------------------------- resolution

    function test_ProposeThenFinalize_RefundsBond() public {
        uint256 before = usdg.balanceOf(proposer);
        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        assertEq(usdg.balanceOf(proposer), before - BOND, "bond escrowed");

        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);

        assertEq(usdg.balanceOf(proposer), before, "bond refunded");
        assertTrue(registry.isResolved(MID));
        assertEq(uint8(registry.outcomeOf(MID)), uint8(MarketTypes.Outcome.Yes));
    }

    function test_Finalize_RevertsInsideWindow() public {
        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        vm.expectRevert(MarketRegistry.ChallengeWindowOpen.selector);
        registry.finalize(MID);
    }

    function test_Dispute_RevertsAfterWindow() public {
        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(disputer);
        vm.expectRevert(MarketRegistry.ChallengeWindowClosed.selector);
        registry.disputeOutcome(MID);
    }

    function test_Ruling_WinnerTakesBothBonds() public {
        uint256 dBefore = usdg.balanceOf(disputer);
        _dispute();

        vm.prank(arbiter);
        registry.proposeRuling(MID, MarketTypes.Outcome.No);
        vm.warp(block.timestamp + RULING_DELAY + 1);
        registry.executeRuling(MID);

        assertEq(usdg.balanceOf(disputer), dBefore + BOND, "won proposer bond");
        assertEq(uint8(registry.outcomeOf(MID)), uint8(MarketTypes.Outcome.No));
    }

    /// @notice A ruling is announced, not applied. The delay is what makes a
    ///         decision publicly checkable against the upstream source before
    ///         it takes effect.
    function test_Ruling_CannotExecuteBeforeDelay() public {
        _dispute();
        vm.prank(arbiter);
        registry.proposeRuling(MID, MarketTypes.Outcome.No);
        vm.expectRevert();
        registry.executeRuling(MID);

        vm.warp(block.timestamp + RULING_DELAY + 1);
        registry.executeRuling(MID);
        assertTrue(registry.isResolved(MID));
    }

    /// @notice Anyone may execute an announced ruling, so the arbiter cannot
    ///         quietly sit on a decision it has already made public.
    function test_Ruling_ExecuteIsPermissionless() public {
        _dispute();
        vm.prank(arbiter);
        registry.proposeRuling(MID, MarketTypes.Outcome.Yes);
        vm.warp(block.timestamp + RULING_DELAY + 1);
        vm.prank(alice);
        registry.executeRuling(MID);
        assertEq(uint8(registry.outcomeOf(MID)), uint8(MarketTypes.Outcome.Yes));
    }

    /// @notice Re-announcing resets the clock, so a corrected ruling faces a
    ///         fresh window instead of inheriting an almost expired one.
    function test_Ruling_ReannounceResetsTheClock() public {
        _dispute();
        vm.prank(arbiter);
        registry.proposeRuling(MID, MarketTypes.Outcome.No);
        vm.warp(block.timestamp + RULING_DELAY - 10);

        vm.prank(arbiter);
        registry.proposeRuling(MID, MarketTypes.Outcome.Yes);
        vm.expectRevert();
        registry.executeRuling(MID);
    }

    /// @notice An absent arbiter can no longer freeze funds forever. Without
    ///         this, redeem requires Resolved and a stalled dispute would strand
    ///         every directional holder permanently.
    function test_Timeout_UnblocksAStalledDispute() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _dispute();

        vm.expectRevert();
        registry.resolveByTimeout(MID);

        vm.warp(block.timestamp + DISPUTE_TIMEOUT + 1);
        vm.prank(alice);
        registry.resolveByTimeout(MID);

        assertEq(uint8(registry.outcomeOf(MID)), uint8(MarketTypes.Outcome.Invalid));
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        core.redeem(MID, 1_000e6, 0);
        assertEq(usdg.balanceOf(alice) - before, 500e6, "half to each side");
    }

    /// @notice The strongest protection, and it needs no arbiter at all: a
    ///         matched pair is worth exactly one unit whatever is decided, so
    ///         merge stays open right through a dispute.
    function test_Merge_StaysOpenDuringDispute() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        _dispute();
        assertEq(uint8(registry.statusOf(MID)), uint8(MarketTypes.Status.Disputed));

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        core.merge(MID, 1_000e6);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6, "full exit, arbiter irrelevant");
    }

    /// @notice Separation of powers: the owner appoints the arbiter but may
    ///         not rule, so draining the protocol needs two compromises.
    function test_Ruling_OnlyArbiterNotOwner() public {
        _dispute();

        vm.prank(alice);
        vm.expectRevert(MarketRegistry.NotArbiter.selector);
        registry.proposeRuling(MID, MarketTypes.Outcome.No);

        // this contract is the owner, and is still refused
        vm.expectRevert(MarketRegistry.NotArbiter.selector);
        registry.proposeRuling(MID, MarketTypes.Outcome.No);

        vm.prank(arbiter);
        registry.proposeRuling(MID, MarketTypes.Outcome.No);
    }

    function _dispute() internal {
        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        vm.prank(disputer);
        registry.disputeOutcome(MID);
    }

    // -------------------------------------------------------- access control

    function test_OutcomeToken_MintOnlyCore() public {
        vm.prank(alice);
        vm.expectRevert(OutcomeToken.OnlyCore.selector);
        yes.mint(alice, 1e6);
    }

    function test_OutcomeToken_DecimalsMatchCollateral() public view {
        assertEq(yes.decimals(), usdg.decimals());
        assertEq(no.decimals(), usdg.decimals());
    }

    // ------------------------------------------------------------- invariant

    /// @notice Core solvency property: collateral held always covers what the
    ///         outstanding supply can claim, in every terminal state.
    function testFuzz_CollateralCoversObligations(uint96 a, uint96 b, uint8 outcomeSeed) public {
        uint256 amtA = uint256(a) % 500_000e6 + 1e6;
        uint256 amtB = uint256(b) % 500_000e6 + 1e6;

        vm.prank(alice);
        core.split(MID, amtA);
        vm.prank(bob);
        core.split(MID, amtB);

        uint256 held = usdg.balanceOf(address(core));
        assertEq(held, amtA + amtB, "1 in => 1 YES + 1 NO");
        assertEq(yes.totalSupply(), no.totalSupply(), "sides always balanced");

        MarketTypes.Outcome o = [
            MarketTypes.Outcome.Yes,
            MarketTypes.Outcome.No,
            MarketTypes.Outcome.Invalid
        ][outcomeSeed % 3];
        _resolve(o);

        uint256 claim = (o == MarketTypes.Outcome.Invalid)
            ? (yes.totalSupply() + no.totalSupply()) / 2
            : yes.totalSupply();

        assertGe(held, claim, "SOLVENCY: collateral covers all claims");
    }

    function testFuzz_SplitThenMerge_RoundTrips(uint96 amt) public {
        uint256 amount = uint256(amt) % 500_000e6 + 1e6;
        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        core.split(MID, amount);
        core.merge(MID, amount);
        vm.stopPrank();
        assertEq(usdg.balanceOf(alice), before, "no value created or destroyed");
    }

    // --------------------------------------------------------------- helpers

    function _resolve(MarketTypes.Outcome o) internal {
        vm.prank(proposer);
        registry.proposeOutcome(MID, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(MID);
    }
}
