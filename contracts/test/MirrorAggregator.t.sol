// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MirrorAggregator} from "../src/testing/MirrorAggregator.sol";
import {ChainlinkRounds, IAggregatorV3} from "../src/ChainlinkRounds.sol";
import {RichterPositionOracle} from "../src/RichterPositionOracle.sol";
import {RichterMarketFactory} from "../src/RichterMarketFactory.sol";
import {RichterCore} from "../src/RichterCore.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/**
 * The testnet aggregator must be walkable by exactly the code that walks a real
 * Chainlink feed. If ChainlinkRounds needs a special case for it, then testing
 * against it proves nothing about mainnet.
 */
contract MirrorAggregatorTest is Test {
    MirrorAggregator internal agg;
    uint64 constant T0 = 1_785_000_000;

    function setUp() public {
        agg = new MirrorAggregator("Mirror TSLA / USD", 8, address(this));
    }

    function _fill(uint64 count, uint64 spacing) internal {
        for (uint64 i = 0; i < count; i++) {
            agg.push(int256(uint256(100_00000000 + i)), T0 + i * spacing);
        }
    }

    // -- shape ---------------------------------------------------------------

    function test_looksLikeAChainlinkProxy() public {
        _fill(3, 3600);
        assertEq(agg.decimals(), 8);
        assertEq(agg.description(), "Mirror TSLA / USD");
        (uint80 rid, int256 a,, uint256 t,) = agg.latestRoundData();
        (uint16 phase, uint64 n) = ChainlinkRounds.decodeRoundId(rid);
        assertEq(phase, 1);
        assertEq(n, 3);
        assertEq(a, 100_00000002);
        assertEq(t, T0 + 2 * 3600);
    }

    function test_emptyRevertsRatherThanReturningZero() public {
        vm.expectRevert(MirrorAggregator.NoData.selector);
        agg.latestRoundData();
    }

    function test_anUnwrittenRoundReverts() public {
        _fill(2, 3600);
        uint80 far = ChainlinkRounds.encodeRoundId(1, 99);
        vm.expectRevert(abi.encodeWithSelector(MirrorAggregator.UnknownRound.selector, far));
        agg.getRoundData(far);
    }

    // -- the library walks it unchanged --------------------------------------

    function test_chainlinkRoundsWalksItLikeARealFeed() public {
        _fill(20, 3600);
        IAggregatorV3 f = IAggregatorV3(address(agg));

        // Ten hours back must land on the round before that instant, with the
        // next round strictly after it.
        uint256 target = T0 + 10 * 3600 + 60;
        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(f, target, 64);
        assertLe(r.updatedAt, target);

        (uint16 p, uint64 n) = ChainlinkRounds.decodeRoundId(r.id);
        (,,, uint256 nextTs,) = agg.getRoundData(ChainlinkRounds.encodeRoundId(p, n + 1));
        assertGt(nextTs, target, "the walk stopped one round too early");
    }

    function test_firstAtOrAfterCrossesByOne() public {
        _fill(20, 3600);
        IAggregatorV3 f = IAggregatorV3(address(agg));
        uint256 target = T0 + 10 * 3600 + 60;

        ChainlinkRounds.Round memory before = ChainlinkRounds.lastAtOrBefore(f, target, 64);
        ChainlinkRounds.Round memory after_ = ChainlinkRounds.firstAtOrAfter(f, target, 64);
        (, uint64 nb) = ChainlinkRounds.decodeRoundId(before.id);
        (, uint64 na) = ChainlinkRounds.decodeRoundId(after_.id);
        assertEq(na, nb + 1);
    }

    // -- the switches that a real feed cannot offer --------------------------

    function test_bumpPhaseRestartsTheCounter() public {
        _fill(5, 3600);
        agg.bumpPhase();
        agg.push(200_00000000, T0 + 100 * 3600);
        (uint80 rid,,,,) = agg.latestRoundData();
        (uint16 phase, uint64 n) = ChainlinkRounds.decodeRoundId(rid);
        assertEq(phase, 2, "a new phase, as Chainlink does on an aggregator swap");
        assertEq(n, 1, "the counter restarts");
    }

    function test_oldPhaseHistorySurvives() public {
        _fill(5, 3600);
        agg.bumpPhase();
        (, int256 a,,,) = agg.getRoundData(ChainlinkRounds.encodeRoundId(1, 3));
        assertEq(a, 100_00000002, "an earlier phase is still readable");
    }

    function test_pausedFlagMirrorsAStockToken() public {
        assertFalse(agg.oraclePaused());
        agg.setPaused(true);
        assertTrue(agg.oraclePaused());
    }

    // -- writing rules -------------------------------------------------------

    function test_stampsMustIncrease() public {
        agg.push(100_00000000, T0 + 3600);
        vm.expectRevert(
            abi.encodeWithSelector(MirrorAggregator.StampNotIncreasing.selector, T0 + 3600, T0 + 3600)
        );
        agg.push(100_00000000, T0 + 3600);
    }

    function test_aNonPositiveAnswerIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(MirrorAggregator.BadAnswer.selector, int256(0)));
        agg.push(0, T0);
    }

    function test_onlyAWriterMayPush() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MirrorAggregator.NotWriter.selector);
        agg.push(100_00000000, T0);
    }

    function test_aWriterMayPush() public {
        agg.setWriter(address(0xBEEF), true);
        vm.prank(address(0xBEEF));
        agg.push(100_00000000, T0);
        assertEq(agg.roundCount(), 1);
    }

    function test_seedFillsHistoryInOneCall() public {
        int256[] memory a = new int256[](3);
        uint64[] memory t = new uint64[](3);
        for (uint64 i = 0; i < 3; i++) {
            a[i] = 100_00000000 + int256(uint256(i));
            t[i] = T0 + i * 3600;
        }
        agg.seed(a, t);
        assertEq(agg.roundCount(), 3);
    }

    // -- end to end: a Richter market settles against it ---------------------

    function test_aRichterMarketSettlesAgainstIt() public {
        MockUSDG usd = new MockUSDG();
        MarketRegistry registry =
            new MarketRegistry(address(usd), 100e6, 120, 0, address(this), 86400, 604800);
        RichterPositionOracle oracle = new RichterPositionOracle(address(this));
        RichterCore core = new RichterCore(address(usd), address(oracle));
        RichterMarketFactory factory = new RichterMarketFactory(
            address(registry), address(oracle), address(this)
        );
        factory.addCore(address(core));
        oracle.setFactory(address(factory));
        registry.setRelayer(address(factory), true);

        uint64 close = T0 + 3600;
        uint64 open = close + 17 hours;

        agg.push(100_00000000, close - 600);
        agg.push(103_00000000, open + 30);          // up 3%

        factory.setTicker(address(agg), address(agg), 500, true);
        vm.warp(open + 3600);
        bytes32 id = factory.open(address(agg), close, open);

        assertEq(oracle.settlementFraction(id), 600_000, "3 of a 5 cap is 0.6");

        // And the switch forces the void path a real feed would never perform.
        agg.setPaused(true);
        assertEq(oracle.settlementFraction(id), 5e5, "paused pays half to each");
    }
}
