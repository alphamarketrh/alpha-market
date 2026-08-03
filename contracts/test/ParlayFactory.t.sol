// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {ParlayFactory} from "../src/ParlayFactory.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

contract ParlayFactoryTest is Test {
    MockUSDG usdg;
    MarketRegistry registry;
    AlphaMarketCore core;
    ParlayFactory factory;

    address relayer = makeAddr("relayer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address proposer = makeAddr("proposer");

    bytes32 constant A = keccak256("market-A");
    bytes32 constant B = keccak256("market-B");
    bytes32 constant C = keccak256("market-C");
    uint256 constant BOND = 100e6;
    uint64 constant WINDOW = 2 hours;

    uint8 constant YES = uint8(MarketTypes.Outcome.Yes);
    uint8 constant NO = uint8(MarketTypes.Outcome.No);

    bytes32 pid;
    OutcomeToken pYes;
    OutcomeToken pNo;

    function setUp() public {
        usdg = new MockUSDG();
        registry = new MarketRegistry(address(usdg), BOND, WINDOW, 25_000, makeAddr("arbiter"), 1 hours, 7 days);
        core = new AlphaMarketCore(address(usdg), address(registry));
        factory = new ParlayFactory(address(usdg), address(registry));
        registry.setRelayer(relayer, true);

        uint64 end = uint64(block.timestamp + 90 days);
        vm.startPrank(relayer);
        registry.registerMarket(A, end, 50_000);
        registry.registerMarket(B, end, 50_000);
        registry.registerMarket(C, end, 50_000);
        vm.stopPrank();

        address[3] memory who = [alice, bob, proposer];
        for (uint256 i = 0; i < who.length; i++) {
            usdg.mint(who[i], 1_000_000e6);
            vm.startPrank(who[i]);
            usdg.approve(address(factory), type(uint256).max);
            usdg.approve(address(registry), type(uint256).max);
            vm.stopPrank();
        }

        pid = _create2(A, YES, B, YES);
        (address y, address n) = factory.tokensOf(pid);
        pYes = OutcomeToken(y);
        pNo = OutcomeToken(n);
    }

    // ------------------------------------------------------------- creation

    function test_Create_IsDeterministicAndUnique() public {
        bytes32[] memory ids = new bytes32[](2);
        uint8[] memory req = new uint8[](2);
        ids[0] = A; ids[1] = B; req[0] = YES; req[1] = YES;
        assertEq(factory.parlayIdFor(ids, req), pid, "id is deterministic");
        vm.expectRevert(ParlayFactory.ParlayExists.selector);
        factory.createParlay(ids, req);
    }

    function test_Create_RevertsOnDuplicateLeg() public {
        bytes32[] memory ids = new bytes32[](2);
        uint8[] memory req = new uint8[](2);
        ids[0] = A; ids[1] = A; req[0] = YES; req[1] = YES;
        vm.expectRevert(ParlayFactory.DuplicateLeg.selector);
        factory.createParlay(ids, req);
    }

    function test_Create_RevertsOnSingleLeg() public {
        bytes32[] memory ids = new bytes32[](1);
        uint8[] memory req = new uint8[](1);
        ids[0] = A; req[0] = YES;
        vm.expectRevert(ParlayFactory.TooFewLegs.selector);
        factory.createParlay(ids, req);
    }

    /// @dev A leg already resolving upstream would let the creator mint a
    ///      combination whose answer is partly known.
    function test_Create_RevertsIfLegNotTradeable() public {
        vm.prank(relayer);
        registry.halt(C, "source resolving");
        bytes32[] memory ids = new bytes32[](2);
        uint8[] memory req = new uint8[](2);
        ids[0] = A; ids[1] = C; req[0] = YES; req[1] = YES;
        vm.expectRevert(abi.encodeWithSelector(ParlayFactory.LegNotActive.selector, C));
        factory.createParlay(ids, req);
    }

    // ------------------------------------------------------- split / merge

    function test_Split_MintsPair() public {
        vm.prank(alice);
        factory.split(pid, 300e6);
        assertEq(pYes.balanceOf(alice), 300e6);
        assertEq(pNo.balanceOf(alice), 300e6);
        assertEq(usdg.balanceOf(address(factory)), 300e6);
    }

    function test_Split_RevertsWhenALegHalts() public {
        vm.prank(relayer);
        registry.halt(B, "source resolving");
        vm.prank(alice);
        vm.expectRevert(ParlayFactory.NotTradeable.selector);
        factory.split(pid, 100e6);
    }

    function test_Merge_RoundTrips() public {
        uint256 before = usdg.balanceOf(alice);
        vm.startPrank(alice);
        factory.split(pid, 300e6);
        factory.merge(pid, 300e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(alice), before);
    }

    // ------------------------------------------------------------ resolution

    function test_Resolve_AllLegsLand_PaysYes() public {
        vm.prank(alice);
        factory.split(pid, 1_000e6);
        _resolve(A, MarketTypes.Outcome.Yes);
        _resolve(B, MarketTypes.Outcome.Yes);

        assertTrue(factory.isResolvable(pid));
        factory.resolve(pid);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        factory.redeem(pid, 1_000e6, 0);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6, "parlay pays in full");
    }

    /// @notice The defining property: one leg missing pays nothing, whereas
    ///         holding the legs separately would still have paid on the winner.
    function test_Resolve_OneLegFails_PaysNothing() public {
        vm.prank(alice);
        factory.split(pid, 1_000e6);
        _resolve(A, MarketTypes.Outcome.Yes);
        _resolve(B, MarketTypes.Outcome.No);
        factory.resolve(pid);

        vm.prank(alice);
        vm.expectRevert(ParlayFactory.NothingToRedeem.selector);
        factory.redeem(pid, 1_000e6, 0);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        factory.redeem(pid, 0, 1_000e6);
        assertEq(usdg.balanceOf(alice) - before, 1_000e6, "NO side takes it all");
    }

    function test_Resolve_RequiredNo_Works() public {
        bytes32 p2 = _create2(A, YES, C, NO);
        (address y,) = factory.tokensOf(p2);
        vm.prank(alice);
        factory.split(p2, 500e6);
        _resolve(A, MarketTypes.Outcome.Yes);
        _resolve(C, MarketTypes.Outcome.No);
        factory.resolve(p2);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        factory.redeem(p2, 500e6, 0);
        assertEq(usdg.balanceOf(alice) - before, 500e6);
        assertEq(OutcomeToken(y).balanceOf(alice), 0);
    }

    function test_Resolve_InvalidLeg_MakesParlayInvalid() public {
        vm.prank(alice);
        factory.split(pid, 1_000e6);
        _resolve(A, MarketTypes.Outcome.Yes);
        _resolve(B, MarketTypes.Outcome.Invalid);
        factory.resolve(pid);

        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        factory.redeem(pid, 1_000e6, 0);
        assertEq(usdg.balanceOf(alice) - before, 500e6, "half to each side");
    }

    function test_Resolve_RevertsWhileLegsPending() public {
        _resolve(A, MarketTypes.Outcome.Yes);
        assertFalse(factory.isResolvable(pid));
        vm.expectRevert(ParlayFactory.LegsPending.selector);
        factory.resolve(pid);
    }

    function test_Resolve_IsPermissionless() public {
        _resolve(A, MarketTypes.Outcome.Yes);
        _resolve(B, MarketTypes.Outcome.Yes);
        vm.prank(bob);
        factory.resolve(pid);
        (,,,, MarketTypes.Outcome o, bool r) = factory.getParlay(pid);
        assertTrue(r);
        assertEq(uint8(o), YES);
    }

    // ------------------------------------------------------------- invariant

    /// @notice Solvency: whatever the legs do, the factory holds enough to pay
    ///         every claim the outstanding supply can make.
    function testFuzz_ParlaySolvency(uint96 amtRaw, uint8 oa, uint8 ob) public {
        uint256 amount = uint256(amtRaw) % 500_000e6 + 1e6;
        vm.prank(alice);
        factory.split(pid, amount);

        MarketTypes.Outcome[3] memory opts = [
            MarketTypes.Outcome.Yes, MarketTypes.Outcome.No, MarketTypes.Outcome.Invalid
        ];
        _resolve(A, opts[oa % 3]);
        _resolve(B, opts[ob % 3]);
        factory.resolve(pid);

        (,,,, MarketTypes.Outcome o,) = factory.getParlay(pid);
        uint256 held = usdg.balanceOf(address(factory));
        uint256 claim = o == MarketTypes.Outcome.Invalid
            ? (pYes.totalSupply() + pNo.totalSupply()) / 2
            : pYes.totalSupply();
        assertGe(held, claim, "SOLVENCY: factory covers all claims");

        vm.prank(alice);
        factory.redeem(pid, amount, amount);
        assertGe(usdg.balanceOf(address(factory)), 0);
    }

    // --------------------------------------------------------------- helpers

    function _create2(bytes32 m1, uint8 r1, bytes32 m2, uint8 r2)
        internal
        returns (bytes32)
    {
        bytes32[] memory ids = new bytes32[](2);
        uint8[] memory req = new uint8[](2);
        ids[0] = m1; ids[1] = m2; req[0] = r1; req[1] = r2;
        return factory.createParlay(ids, req);
    }

    function _resolve(bytes32 id, MarketTypes.Outcome o) internal {
        if (registry.isResolved(id)) return;
        vm.prank(proposer);
        registry.proposeOutcome(id, o);
        vm.warp(block.timestamp + WINDOW + 1);
        registry.finalize(id);
    }
}
