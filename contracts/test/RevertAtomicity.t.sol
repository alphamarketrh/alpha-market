// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestDollar} from "../src/TestDollar.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";

/// @notice redeem() burns before it checks the payout. A revert must undo the
///         burn, or a losing holder loses the token and receives nothing.
contract RevertAtomicityTest is Test {
    TestDollar usd;
    MarketRegistry registry;
    AlphaMarketCore core;
    address relayer = makeAddr("relayer");
    address alice = makeAddr("alice");
    address proposer = makeAddr("proposer");
    bytes32 constant MID = keccak256("atomicity");
    OutcomeToken yes;
    OutcomeToken no;

    function setUp() public {
        usd = new TestDollar(1_000_000e6, 0, type(uint128).max);
        registry = new MarketRegistry(address(usd), 100e6, 2 hours, 0,
            makeAddr("arbiter"), 1 hours, 7 days);
        core = new AlphaMarketCore(address(usd), address(registry));
        registry.setRelayer(relayer, true);
        vm.prank(relayer);
        registry.registerMarket(MID, uint64(block.timestamp + 30 days), 0);
        core.initializeMarket(MID);
        (address y, address n) = core.tokensOf(MID);
        yes = OutcomeToken(y); no = OutcomeToken(n);

        for (uint256 i = 0; i < 2; i++) {
            address w = i == 0 ? alice : proposer;
            vm.prank(w);
            usd.claim();
            vm.prank(w);
            usd.approve(address(core), type(uint256).max);
            vm.prank(w);
            usd.approve(address(registry), type(uint256).max);
        }
    }

    function test_LosingRedeem_RevertsWithoutBurningTheToken() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);

        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        vm.warp(block.timestamp + 2 hours + 1);
        registry.finalize(MID);

        uint256 noBefore = no.balanceOf(alice);
        uint256 cashBefore = usd.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(AlphaMarketCore.NothingToRedeem.selector);
        core.redeem(MID, 0, 1_000e6);

        assertEq(no.balanceOf(alice), noBefore, "the burn must be rolled back");
        assertEq(usd.balanceOf(alice), cashBefore, "no cash moved");
    }

    /// @notice And the winning side still redeems normally afterwards.
    function test_WinningRedeem_UnaffectedByTheFailedAttempt() public {
        vm.prank(alice);
        core.split(MID, 1_000e6);
        vm.prank(proposer);
        registry.proposeOutcome(MID, MarketTypes.Outcome.Yes);
        vm.warp(block.timestamp + 2 hours + 1);
        registry.finalize(MID);

        vm.prank(alice);
        vm.expectRevert(AlphaMarketCore.NothingToRedeem.selector);
        core.redeem(MID, 0, 1_000e6);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(MID, 1_000e6, 0);
        assertEq(usd.balanceOf(alice) - before, 1_000e6, "winner paid in full");
    }
}
