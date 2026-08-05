// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IAggregatorProxy is IAggregatorV3 {
    function phaseId() external view returns (uint16);

    function aggregator() external view returns (address);
}

/**
 * Locating a Chainlink round by wall-clock time.
 *
 * A settlement that asks "what did this feed say at the closing bell" cannot use
 * latestRoundData, because by the time anyone settles, the feed has moved on. It
 * has to walk back through history and stop at the right round.
 *
 * WHY THE WALK IS NOT A SIMPLE SUBTRACTION
 * A Chainlink proxy encodes two numbers in one roundId: the phase in the top
 * sixteen bits, and the aggregator own round counter in the bottom sixty-four.
 * A phase changes when Chainlink swaps the aggregator behind the proxy, and the
 * round counter restarts at one. Subtracting across that boundary produces an id
 * that belongs to no round at all, so the walk decodes the id, decrements only
 * the counter, and refuses to step below one.
 *
 * WHY THE STEP COUNT IS BOUNDED AND PASSED IN
 * Equity feeds publish on deviation during market hours and go quiet when the
 * exchange closes, so the number of rounds between two timestamps depends on the
 * window and on how the day traded. Measured on RHTSLA/USD, consecutive rounds
 * were as close as 210 seconds and as far apart as 15,695 seconds in the same
 * day. An unbounded loop would let one badly chosen window consume the block gas
 * limit, so the ceiling is the caller decision and exhausting it is an error
 * rather than a silently wrong answer.
 *
 * WHAT THIS DOES NOT DO
 * It does not consult an L2 sequencer uptime feed. During a sequencer outage no
 * round is published even though the underlying price moves, so a window that
 * spans an outage will resolve against the last round before it. A caller that
 * cares must bound the age of the round it receives and reject what is too old.
 */
library ChainlinkRounds {
    struct Round {
        uint80 id;
        int256 answer;
        uint256 updatedAt;
    }

    /// @notice The walk reached the first round of a phase without passing the target.
    error PhaseBoundary(uint16 phase, uint256 target);

    /// @notice The walk used its whole budget and never passed the target.
    error SearchExhausted(uint256 target, uint256 maxSteps);

    /// @notice A round id resolved to no data, which means it was never published.
    error EmptyRound(uint80 roundId);

    /// @notice Nothing has been published at or after the target yet.
    error NoRoundAtOrAfter(uint256 target, uint80 newestSeen);

    /// @notice A round carried a zero or negative answer.
    error BadAnswer(uint80 roundId, int256 answer);

    /// @dev Split a proxy round id into its phase and the aggregator own counter.
    ///      Both casts truncate on purpose: that is what extracting a bit field
    ///      means. Shifting a uint80 right by sixty-four leaves at most sixteen
    ///      bits, so the phase cast cannot lose data, and the counter cast is
    ///      defined to keep exactly the low sixty-four bits.
    function decodeRoundId(uint80 roundId) internal pure returns (uint16 phase, uint64 aggRound) {
        // forge-lint: disable-next-line(unsafe-typecast)
        phase = uint16(roundId >> 64);
        // forge-lint: disable-next-line(unsafe-typecast)
        aggRound = uint64(roundId);
    }

    /// @dev Rebuild a proxy round id from a phase and an aggregator counter.
    function encodeRoundId(uint16 phase, uint64 aggRound) internal pure returns (uint80) {
        return uint80(uint80(phase) << 64) | uint80(aggRound);
    }

    /**
     * The most recent round published at or before target.
     *
     * Reverts rather than approximating: a settlement that silently used the
     * wrong round would be indistinguishable from one that used the right one.
     */
    function lastAtOrBefore(IAggregatorV3 feed, uint256 target, uint256 maxSteps)
        internal
        view
        returns (Round memory)
    {
        (uint80 rid, int256 ans,, uint256 ts,) = feed.latestRoundData();
        if (ts == 0) revert EmptyRound(rid);
        if (ans <= 0) revert BadAnswer(rid, ans);
        if (ts <= target) return Round(rid, ans, ts);

        (uint16 phase, uint64 aggRound) = decodeRoundId(rid);

        for (uint256 i = 0; i < maxSteps; ++i) {
            if (aggRound <= 1) revert PhaseBoundary(phase, target);
            unchecked {
                aggRound -= 1;
            }
            uint80 probe = encodeRoundId(phase, aggRound);

            (int256 a, uint256 t) = _read(feed, probe);
            if (t == 0) revert EmptyRound(probe);
            if (t <= target) {
                if (a <= 0) revert BadAnswer(probe, a);
                return Round(probe, a, t);
            }
        }
        revert SearchExhausted(target, maxSteps);
    }

    /**
     * The first round published at or after target.
     *
     * Found by locating the boundary from below and stepping forward once, which
     * costs the same walk and cannot overshoot into a round that does not exist.
     */
    function firstAtOrAfter(IAggregatorV3 feed, uint256 target, uint256 maxSteps)
        internal
        view
        returns (Round memory)
    {
        Round memory before = lastAtOrBefore(feed, target, maxSteps);
        if (before.updatedAt == target) return before;

        (uint16 phase, uint64 aggRound) = decodeRoundId(before.id);
        uint80 probe = encodeRoundId(phase, aggRound + 1);

        (int256 a, uint256 t) = _read(feed, probe);
        if (t == 0) revert NoRoundAtOrAfter(target, before.id);
        if (a <= 0) revert BadAnswer(probe, a);
        return Round(probe, a, t);
    }

    /// @dev A missing round is reported as a zero timestamp whether the feed
    ///      returns empty data or reverts outright, so both are handled here and
    ///      the callers above stay readable.
    function _read(IAggregatorV3 feed, uint80 roundId) private view returns (int256 answer, uint256 updatedAt) {
        try feed.getRoundData(roundId) returns (uint80, int256 a, uint256, uint256 t, uint80) {
            return (a, t);
        } catch {
            return (0, 0);
        }
    }
}
