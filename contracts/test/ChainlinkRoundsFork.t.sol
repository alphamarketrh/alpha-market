// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ChainlinkRounds, IAggregatorV3, IAggregatorProxy} from "../src/ChainlinkRounds.sol";
import {RoundsHarness} from "./RoundsHarness.sol";

/**
 * Reads the real Chainlink equity feeds on Robinhood Chain mainnet, chain 4663.
 *
 * Nothing here is mocked. Every number comes from a live aggregator over a fork,
 * which is the only way to prove that a backward walk through round history holds
 * against data that Chainlink actually published rather than data we invented.
 *
 * Run with:
 *   forge test --match-contract ChainlinkRoundsFork -vv
 *
 * The suite skips itself when RH_MAINNET_RPC is unset, so it never breaks a
 * normal forge test run on a machine with no mainnet access.
 */
contract ChainlinkRoundsForkTest is Test {
    using ChainlinkRounds for IAggregatorV3;

    // Read from the Chainlink feed directory and each confirmed live on chain.
    // Same four addresses the relayer already uses in relayer/src/equity.js.
    address constant FEED_TSLA = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant FEED_AMD = 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72;
    address constant FEED_AMZN = 0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C;
    address constant FEED_PLTR = 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c;

    uint256 constant MAX_STEPS = 512;

    bool internal forked;
    RoundsHarness internal harness;

    function setUp() public {
        // Only the fork profile sets evm_version to shanghai, and the live
        // aggregators use PUSH0, so any other profile would fail rather than
        // skip. The profile name is the gate. It also keeps a two minute run out
        // of the default suite.
        //
        // block.prevrandao cannot serve as the gate: it is still zero when setUp
        // begins, before createSelectFork has replaced the environment, so every
        // test would skip even under the right profile.
        try vm.envString("FOUNDRY_PROFILE") returns (string memory profile) {
            if (keccak256(bytes(profile)) != keccak256(bytes("fork"))) return;
        } catch {
            return;
        }
        try vm.envString("RH_MAINNET_RPC") returns (string memory url) {
            if (bytes(url).length == 0) return;
            vm.createSelectFork(url);
            harness = new RoundsHarness();
            forked = true;
        } catch {
            forked = false;
        }
    }

    modifier onlyForked() {
        if (!forked) {
            console.log("RH_MAINNET_RPC unset, skipping fork test");
            return;
        }
        _;
    }

    function _feeds() internal pure returns (address[4] memory a, string[4] memory n) {
        a = [FEED_TSLA, FEED_AMD, FEED_AMZN, FEED_PLTR];
        n = ["TSLA", "AMD", "AMZN", "PLTR"];
    }

    // -----------------------------------------------------------------------
    // 1. The feeds answer, and answer the interface Richter will call.
    // -----------------------------------------------------------------------

    function test_feedsAreLiveAndWellFormed() public onlyForked {
        assertEq(block.chainid, 4663, "fork is not Robinhood Chain mainnet");

        (address[4] memory addrs, string[4] memory names) = _feeds();
        for (uint256 i = 0; i < addrs.length; ++i) {
            IAggregatorV3 feed = IAggregatorV3(addrs[i]);

            uint8 dec = feed.decimals();
            (uint80 rid, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

            console.log("--", names[i]);
            console.log("   description", feed.description());
            console.log("   decimals   ", dec);
            console.log("   answer");
            console.logInt(answer);
            console.log("   updatedAt  ", updatedAt);
            console.log("   age (s)    ", block.timestamp - updatedAt);

            assertEq(dec, 8, "equity feeds are expected to publish eight decimals");
            assertGt(answer, 0, "answer must be positive");
            assertGt(updatedAt, 0, "round must be complete");
            assertLe(updatedAt, block.timestamp, "round cannot be published in the future");
            assertGt(rid, 0, "round id must be set");
        }
    }

    // -----------------------------------------------------------------------
    // 2. The proxy really is phase-encoded, and the walk decodes it correctly.
    // -----------------------------------------------------------------------

    function test_roundIdEncodingMatchesTheProxy() public onlyForked {
        IAggregatorProxy proxy = IAggregatorProxy(FEED_TSLA);
        (uint80 rid,,,,) = proxy.latestRoundData();

        (uint16 phase, uint64 aggRound) = ChainlinkRounds.decodeRoundId(rid);
        console.log("TSLA latest roundId", uint256(rid));
        console.log("   decoded phase   ", phase);
        console.log("   decoded aggRound", aggRound);
        console.log("   proxy phaseId   ", proxy.phaseId());
        console.log("   aggregator      ", proxy.aggregator());

        assertEq(phase, proxy.phaseId(), "decoded phase must match the proxy");
        assertGt(aggRound, 0, "aggregator round counter starts at one");
        assertEq(ChainlinkRounds.encodeRoundId(phase, aggRound), rid, "encode must invert decode");
    }

    // -----------------------------------------------------------------------
    // 3. History is contiguous and strictly ordered walking backwards.
    // -----------------------------------------------------------------------

    function test_historyIsContiguousAndOrdered() public onlyForked {
        IAggregatorV3 feed = IAggregatorV3(FEED_TSLA);
        (uint80 rid,,, uint256 ts,) = feed.latestRoundData();
        (uint16 phase, uint64 aggRound) = ChainlinkRounds.decodeRoundId(rid);

        uint64 steps = aggRound > 32 ? 32 : aggRound - 1;
        uint256 prevTs = ts;
        uint256 widestGap;

        for (uint64 i = 1; i <= steps; ++i) {
            uint80 probe = ChainlinkRounds.encodeRoundId(phase, aggRound - i);
            (, int256 a,, uint256 t,) = feed.getRoundData(probe);

            assertGt(t, 0, "an earlier round in the same phase must exist");
            assertGt(a, 0, "an earlier round must carry a positive answer");
            assertLt(t, prevTs, "timestamps must strictly decrease walking backwards");

            uint256 gap = prevTs - t;
            if (gap > widestGap) widestGap = gap;
            prevTs = t;
        }

        console.log("walked back rounds        ", uint256(steps));
        console.log("span covered (s)          ", ts - prevTs);
        console.log("widest gap between rounds ", widestGap);
        assertGt(steps, 0, "there must be history to walk");
    }

    // -----------------------------------------------------------------------
    // 4. The boundary is exact: nothing between the answer and the target.
    // -----------------------------------------------------------------------

    function test_lastAtOrBeforeIsTheTightestBound() public onlyForked {
        IAggregatorV3 feed = IAggregatorV3(FEED_TSLA);
        (,,, uint256 latestTs,) = feed.latestRoundData();

        // Six hours back lands inside published history without depending on
        // whether the exchange happens to be open at the moment of the run.
        uint256 target = latestTs - 6 hours;

        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(feed, target, MAX_STEPS);
        assertLe(r.updatedAt, target, "the answer must not be later than the target");
        assertGt(r.answer, 0, "the answer must be positive");

        // The very next round must sit strictly after the target, otherwise the
        // walk stopped one round too early.
        (uint16 phase, uint64 aggRound) = ChainlinkRounds.decodeRoundId(r.id);
        (, int256 nextA,, uint256 nextTs,) =
            feed.getRoundData(ChainlinkRounds.encodeRoundId(phase, aggRound + 1));

        console.log("target      ", target);
        console.log("chosen round", r.updatedAt);
        console.log("next round  ", nextTs);
        console.log("slack (s)   ", target - r.updatedAt);

        assertGt(nextTs, target, "a round between the answer and the target was skipped");
        assertGt(nextA, 0, "the next round must carry a positive answer");
    }

    // -----------------------------------------------------------------------
    // 5. firstAtOrAfter returns the round immediately across the boundary.
    // -----------------------------------------------------------------------

    function test_firstAtOrAfterCrossesTheBoundaryByExactlyOne() public onlyForked {
        IAggregatorV3 feed = IAggregatorV3(FEED_TSLA);
        (,,, uint256 latestTs,) = feed.latestRoundData();
        uint256 target = latestTs - 6 hours;

        ChainlinkRounds.Round memory before = ChainlinkRounds.lastAtOrBefore(feed, target, MAX_STEPS);
        ChainlinkRounds.Round memory after_ = ChainlinkRounds.firstAtOrAfter(feed, target, MAX_STEPS);

        assertGe(after_.updatedAt, target, "the answer must not be earlier than the target");
        assertGt(after_.updatedAt, before.updatedAt, "the pair must straddle the target");

        (uint16 pBefore, uint64 rBefore) = ChainlinkRounds.decodeRoundId(before.id);
        (uint16 pAfter, uint64 rAfter) = ChainlinkRounds.decodeRoundId(after_.id);
        assertEq(pAfter, pBefore, "both sides of the boundary must be in one phase");
        assertEq(rAfter, rBefore + 1, "the two rounds must be adjacent");

        console.log("before", before.updatedAt);
        console.log("after ", after_.updatedAt);
        console.log("gap(s)", after_.updatedAt - before.updatedAt);
    }

    // -----------------------------------------------------------------------
    // 6. How deep the walk has to go. This is the number that sets the gas
    //    budget for a daily market and a weekend market.
    // -----------------------------------------------------------------------

    function test_measureWalkDepthForRealWindows() public onlyForked {
        (address[4] memory addrs, string[4] memory names) = _feeds();

        for (uint256 i = 0; i < addrs.length; ++i) {
            IAggregatorV3 feed = IAggregatorV3(addrs[i]);
            (uint80 rid,,, uint256 ts,) = feed.latestRoundData();
            (uint16 phase, uint64 aggRound) = ChainlinkRounds.decodeRoundId(rid);

            uint64 steps24;
            uint64 steps72;
            uint64 walked;
            uint256 t = ts;

            while (walked < aggRound - 1 && walked < MAX_STEPS) {
                walked += 1;
                uint80 probe = ChainlinkRounds.encodeRoundId(phase, aggRound - walked);
                (,,, uint256 pt,) = feed.getRoundData(probe);
                if (pt == 0) break;
                t = pt;
                if (steps24 == 0 && ts - t >= 24 hours) steps24 = walked;
                if (steps72 == 0 && ts - t >= 72 hours) {
                    steps72 = walked;
                    break;
                }
            }

            console.log("--", names[i]);
            console.log("   rounds available     ", uint256(aggRound));
            console.log("   steps to cover 24h   ", uint256(steps24));
            console.log("   steps to cover 72h   ", uint256(steps72));
            console.log("   oldest reached (s ago)", ts - t);
        }
    }

    // -----------------------------------------------------------------------
    // 7. Failure modes revert instead of guessing.
    // -----------------------------------------------------------------------

    function test_targetBeforeAnyHistoryReverts() public onlyForked {
        IAggregatorV3 feed = IAggregatorV3(FEED_TSLA);
        // Well before Robinhood Chain mainnet existed, so no round can precede it.
        uint256 target = 1_600_000_000;
        vm.expectRevert();
        harness.lastAtOrBefore(feed, target, MAX_STEPS);
    }

    function test_budgetTooSmallReverts() public onlyForked {
        IAggregatorV3 feed = IAggregatorV3(FEED_TSLA);
        (,,, uint256 latestTs,) = feed.latestRoundData();
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkRounds.SearchExhausted.selector, latestTs - 72 hours, 1)
        );
        harness.lastAtOrBefore(feed, latestTs - 72 hours, 1);
    }

    function test_futureTargetReturnsLatest() public onlyForked {
        IAggregatorV3 feed = IAggregatorV3(FEED_TSLA);
        (uint80 rid,,, uint256 ts,) = feed.latestRoundData();
        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(feed, ts + 1 days, MAX_STEPS);
        assertEq(r.id, rid, "a target past the newest round must return the newest round");
    }

    function test_noRoundAfterAFutureTargetReverts() public onlyForked {
        IAggregatorV3 feed = IAggregatorV3(FEED_TSLA);
        (,,, uint256 ts,) = feed.latestRoundData();
        vm.expectRevert();
        harness.firstAtOrAfter(feed, ts + 1 days, MAX_STEPS);
    }
}
