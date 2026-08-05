// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ChainlinkRounds, IAggregatorV3} from "../src/ChainlinkRounds.sol";
import {RoundsHarness} from "./RoundsHarness.sol";

/**
 * A phase-encoded aggregator that replays a fixed history.
 *
 * The round ids, answers and timestamps below are not invented. They were read
 * from RHTSLA/USD on Robinhood Chain mainnet on 5 August 2026 and are replayed
 * here so the search can be checked against known answers without a network
 * call. Unknown ids revert, which is how a real proxy behaves when asked for a
 * round that belongs to another phase.
 */
contract MockPhasedAggregator is IAggregatorV3 {
    uint16 public immutable phase;
    uint64 public immutable firstRound;
    uint64 public immutable lastRound;

    mapping(uint64 => int256) internal _answer;
    mapping(uint64 => uint256) internal _updatedAt;

    error UnknownRound(uint80 roundId);

    constructor(uint16 phase_, uint64 firstRound_, int256[] memory answers, uint256[] memory stamps) {
        require(answers.length == stamps.length, "length mismatch");
        phase = phase_;
        firstRound = firstRound_;
        lastRound = firstRound_ + uint64(answers.length) - 1;
        for (uint64 i = 0; i < uint64(answers.length); ++i) {
            _answer[firstRound_ + i] = answers[i];
            _updatedAt[firstRound_ + i] = stamps[i];
        }
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function _id(uint64 n) internal view returns (uint80) {
        return ChainlinkRounds.encodeRoundId(phase, n);
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        uint64 n = lastRound;
        return (_id(n), _answer[n], _updatedAt[n], _updatedAt[n], _id(n));
    }

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint16 p, uint64 n) = ChainlinkRounds.decodeRoundId(roundId);
        if (p != phase || n < firstRound || n > lastRound) revert UnknownRound(roundId);
        return (roundId, _answer[n], _updatedAt[n], _updatedAt[n], roundId);
    }
}

contract ChainlinkRoundsTest is Test {
    MockPhasedAggregator internal feed;
    RoundsHarness internal harness;

    // RHTSLA/USD, rounds 732 through 743, phase 1, read 2026-08-05.
    uint256 constant T732 = 1785902468;
    uint256 constant T733 = 1785918163;
    uint256 constant T734 = 1785919423;
    uint256 constant T735 = 1785928606;
    uint256 constant T736 = 1785934518;
    uint256 constant T737 = 1785936619;
    uint256 constant T738 = 1785936949;
    uint256 constant T739 = 1785937669;
    uint256 constant T740 = 1785937879;
    uint256 constant T741 = 1785938839;
    uint256 constant T742 = 1785939229;
    uint256 constant T743 = 1785941510;

    function setUp() public {
        int256[] memory a = new int256[](12);
        uint256[] memory t = new uint256[](12);

        a[0] = 32703000000;
        t[0] = T732;
        a[1] = 32539480000;
        t[1] = T733;
        a[2] = 32373495000;
        t[2] = T734;
        a[3] = 32541410000;
        t[3] = T735;
        a[4] = 32376980000;
        t[4] = T736;
        a[5] = 32186000000;
        t[5] = T737;
        a[6] = 32396000000;
        t[6] = T738;
        a[7] = 32633490000;
        t[7] = T739;
        a[8] = 32459485000;
        t[8] = T740;
        a[9] = 32691999999;
        t[9] = T741;
        a[10] = 32504499999;
        t[10] = T742;
        a[11] = 32321730000;
        t[11] = T743;

        feed = new MockPhasedAggregator(1, 732, a, t);
        harness = new RoundsHarness();
    }

    function _f() internal view returns (IAggregatorV3) {
        return IAggregatorV3(address(feed));
    }

    // -- encoding ------------------------------------------------------------

    function test_encodeDecodeRoundTrip() public pure {
        uint80 id = ChainlinkRounds.encodeRoundId(1, 743);
        assertEq(uint256(id), 18446744073709552359, "must reproduce the id read from mainnet");

        (uint16 p, uint64 n) = ChainlinkRounds.decodeRoundId(id);
        assertEq(p, 1);
        assertEq(n, 743);
    }

    function testFuzz_encodeDecodeRoundTrip(uint16 p, uint64 n) public pure {
        (uint16 p2, uint64 n2) = ChainlinkRounds.decodeRoundId(ChainlinkRounds.encodeRoundId(p, n));
        assertEq(p2, p);
        assertEq(n2, n);
    }

    // -- lastAtOrBefore ------------------------------------------------------

    function test_exactTimestampReturnsThatRound() public view {
        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(_f(), T737, 64);
        assertEq(r.updatedAt, T737);
        assertEq(r.id, ChainlinkRounds.encodeRoundId(1, 737));
    }

    function test_betweenTwoRoundsReturnsTheEarlier() public view {
        // One second after round 737 and long before 738.
        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(_f(), T737 + 1, 64);
        assertEq(r.updatedAt, T737, "must not jump forward past the target");
    }

    function test_targetInsideTheWidestGap() public view {
        // The gap between 732 and 733 is 15,695 seconds, the widest in the set.
        // A daily market closing bell lands inside a gap like this one.
        uint256 target = T732 + 8000;
        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(_f(), target, 64);
        assertEq(r.updatedAt, T732, "the last round before the gap is the right answer");
        assertEq(r.answer, 32703000000);
    }

    function test_futureTargetReturnsLatestWithoutWalking() public view {
        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(_f(), T743 + 1 days, 1);
        assertEq(r.updatedAt, T743, "a budget of one must suffice when no walk is needed");
    }

    function test_answerIsAlwaysNoLaterThanTarget() public view {
        uint256[12] memory all =
            [T732, T733, T734, T735, T736, T737, T738, T739, T740, T741, T742, T743];
        for (uint256 i = 0; i < all.length; ++i) {
            for (uint256 d = 0; d < 3; ++d) {
                uint256 target = all[i] + d;
                ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(_f(), target, 64);
                assertLe(r.updatedAt, target, "answer must never be later than the target");
            }
        }
    }

    function testFuzz_boundaryIsTight(uint256 offset) public view {
        offset = bound(offset, 0, T743 - T732);
        uint256 target = T732 + offset;

        ChainlinkRounds.Round memory r = ChainlinkRounds.lastAtOrBefore(_f(), target, 64);
        assertLe(r.updatedAt, target, "answer must not be later than the target");

        (uint16 p, uint64 n) = ChainlinkRounds.decodeRoundId(r.id);
        if (n < 743) {
            (,,, uint256 nextTs,) = feed.getRoundData(ChainlinkRounds.encodeRoundId(p, n + 1));
            assertGt(nextTs, target, "a round between the answer and the target was skipped");
        }
    }

    // -- firstAtOrAfter ------------------------------------------------------

    function test_firstAtOrAfterStepsForwardByExactlyOne() public view {
        ChainlinkRounds.Round memory r = ChainlinkRounds.firstAtOrAfter(_f(), T737 + 1, 64);
        assertEq(r.updatedAt, T738, "must return the next published round");
        assertEq(r.id, ChainlinkRounds.encodeRoundId(1, 738));
    }

    function test_firstAtOrAfterOnAnExactStampReturnsThatRound() public view {
        ChainlinkRounds.Round memory r = ChainlinkRounds.firstAtOrAfter(_f(), T738, 64);
        assertEq(r.updatedAt, T738, "an exact hit must not step forward");
    }

    function test_pairStraddlesTheOpeningBell() public view {
        // The shape of a settlement: a close inside one gap, an open after it.
        uint256 bell = T734 + 100;
        ChainlinkRounds.Round memory before = ChainlinkRounds.lastAtOrBefore(_f(), bell, 64);
        ChainlinkRounds.Round memory after_ = ChainlinkRounds.firstAtOrAfter(_f(), bell, 64);

        assertLe(before.updatedAt, bell);
        assertGe(after_.updatedAt, bell);

        (, uint64 nb) = ChainlinkRounds.decodeRoundId(before.id);
        (, uint64 na) = ChainlinkRounds.decodeRoundId(after_.id);
        assertEq(na, nb + 1, "the two rounds must be adjacent");
    }

    // -- failure modes -------------------------------------------------------

    /// An aggregator whose history begins part way through a phase runs out of
    /// published rounds before it reaches the phase floor. That is the ordinary
    /// case on a live feed, and it must refuse rather than return the oldest
    /// round it happens to hold.
    function test_targetBeforeAllHistoryReportsTheMissingRound() public {
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkRounds.EmptyRound.selector, ChainlinkRounds.encodeRoundId(1, 731))
        );
        harness.lastAtOrBefore(_f(), 1, 64);
    }

    /// A phase whose history really does start at round one hits the floor
    /// instead, which is the only case where stepping back would cross into a
    /// different aggregator and produce an id belonging to no round at all.
    function test_targetBeforeAPhaseThatStartsAtRoundOne() public {
        int256[] memory a = new int256[](3);
        uint256[] memory t = new uint256[](3);
        a[0] = 100e8;
        t[0] = 1_700_000_000;
        a[1] = 101e8;
        t[1] = 1_700_000_600;
        a[2] = 102e8;
        t[2] = 1_700_001_200;
        MockPhasedAggregator fresh = new MockPhasedAggregator(2, 1, a, t);

        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkRounds.PhaseBoundary.selector, uint16(2), uint256(1_699_999_999))
        );
        harness.lastAtOrBefore(IAggregatorV3(address(fresh)), 1_699_999_999, 64);
    }

    function test_budgetTooSmallReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkRounds.SearchExhausted.selector, T732, 2));
        harness.lastAtOrBefore(_f(), T732, 2);
    }

    function test_noRoundAfterTheNewestReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkRounds.NoRoundAtOrAfter.selector, T743 + 1, ChainlinkRounds.encodeRoundId(1, 743)
            )
        );
        harness.firstAtOrAfter(_f(), T743 + 1, 64);
    }

    // -- what this history says about gas ------------------------------------

    function test_measureGapsInTheRealHistory() public pure {
        uint256[12] memory all =
            [T732, T733, T734, T735, T736, T737, T738, T739, T740, T741, T742, T743];
        uint256 widest;
        uint256 narrowest = type(uint256).max;
        for (uint256 i = 1; i < all.length; ++i) {
            uint256 gap = all[i] - all[i - 1];
            if (gap > widest) widest = gap;
            if (gap < narrowest) narrowest = gap;
        }
        console.log("rounds in sample     ", all.length);
        console.log("span covered (s)     ", T743 - T732);
        console.log("narrowest gap (s)    ", narrowest);
        console.log("widest gap (s)       ", widest);
        assertGt(widest, 4 hours, "the sample must contain a closed-market gap");
        assertLt(narrowest, 10 minutes, "the sample must contain live trading");
    }
}
