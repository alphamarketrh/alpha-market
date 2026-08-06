// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * A Chainlink-shaped aggregator for the testnet, filled with mainnet prices.
 *
 * WHY THIS EXISTS
 * Chain 46630 has no equity feeds, so a Richter market cannot be opened there and
 * the interface has nowhere to be tested. PriceOracle already holds real mainnet
 * prices on the testnet, relayed hourly, but it keeps only the latest one: its
 * Feed struct has a single pushPrice and pushedAt. Settlement needs round
 * history, so it needs an aggregator.
 *
 * WHY NOT A PLAIN MOCK
 * The prices written here are the real ones read from mainnet Chainlink by the
 * same relayer path that already fills PriceOracle. The history is genuine, so a
 * Richter market settling on the testnet produces the number it would have
 * produced on mainnet. What a plain mock cannot give is a real move; what mainnet
 * cannot give is a paused oracle or a phase change on demand. This gives both.
 *
 * WHAT IS DELIBERATELY UNSAFE
 * bumpPhase and setPaused exist so the failure paths can be forced. They have no
 * counterpart on a real feed and this contract must never be deployed to
 * mainnet 4663. The deploy script refuses to.
 *
 * ROUND IDS
 * Encoded exactly as a Chainlink proxy does, phase in the top sixteen bits and
 * the aggregator counter in the bottom sixty-four, so ChainlinkRounds walks this
 * contract with the same code path it walks a real feed.
 */
contract MirrorAggregator is Ownable {
    error NotWriter();
    error NoData();
    error UnknownRound(uint80 roundId);
    error BadAnswer(int256 answer);
    error StampNotIncreasing(uint256 last, uint256 given);

    struct Round {
        int256 answer;
        uint64 updatedAt;
    }

    string private _description;
    uint8 public immutable override_decimals;

    uint16 public phase = 1;
    uint64 public roundCount;
    bool public paused;

    mapping(uint16 => mapping(uint64 => Round)) private _rounds;
    mapping(address => bool) public isWriter;

    event WriterSet(address indexed writer, bool allowed);
    event RoundPushed(uint16 phase, uint64 round, int256 answer, uint64 updatedAt);
    event PhaseBumped(uint16 from, uint16 to);
    event PausedSet(bool paused);

    constructor(string memory description_, uint8 decimals_, address owner_) Ownable(owner_) {
        _description = description_;
        override_decimals = decimals_;
    }

    modifier onlyWriter() {
        if (!isWriter[msg.sender] && msg.sender != owner()) revert NotWriter();
        _;
    }

    function setWriter(address writer, bool allowed) external onlyOwner {
        isWriter[writer] = allowed;
        emit WriterSet(writer, allowed);
    }

    /// @notice Append one round. Stamps must increase, matching a real feed.
    function push(int256 answer, uint64 updatedAt) public onlyWriter {
        if (answer <= 0) revert BadAnswer(answer);
        uint64 n = roundCount;
        if (n > 0) {
            uint64 last = _rounds[phase][n].updatedAt;
            if (updatedAt <= last) revert StampNotIncreasing(last, updatedAt);
        }
        unchecked { n += 1; }
        roundCount = n;
        _rounds[phase][n] = Round({answer: answer, updatedAt: updatedAt});
        emit RoundPushed(phase, n, answer, updatedAt);
    }

    /// @notice Append using the current block time, which is what the relayer does.
    function pushNow(int256 answer) external onlyWriter {
        push(answer, uint64(block.timestamp));
    }

    /// @notice Start a new phase, restarting the counter, as Chainlink does when
    ///         it swaps the aggregator behind a proxy. Testing only.
    function bumpPhase() external onlyOwner {
        uint16 from = phase;
        phase = from + 1;
        roundCount = 0;
        emit PhaseBumped(from, phase);
    }

    /// @notice Mimic the pause flag a stock token carries. Testing only.
    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function oraclePaused() external view returns (bool) {
        return paused;
    }

    // ------------------------------------------------------------------
    // AggregatorV3, the shape ChainlinkRounds and PriceOracle both expect
    // ------------------------------------------------------------------

    function decimals() external view returns (uint8) {
        return override_decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function _id(uint16 p, uint64 n) internal pure returns (uint80) {
        return uint80(uint80(p) << 64) | uint80(n);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint64 n = roundCount;
        if (n == 0) revert NoData();
        Round memory r = _rounds[phase][n];
        uint80 id = _id(phase, n);
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        // Both casts truncate on purpose: extracting a bit field is what they
        // are for. Shifting a uint80 right by sixty-four leaves at most sixteen
        // bits, and the counter cast keeps exactly the low sixty-four.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 p = uint16(roundId >> 64);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 n = uint64(roundId);
        Round memory r = _rounds[p][n];
        if (r.updatedAt == 0) revert UnknownRound(roundId);
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    /// @notice Seed history in one transaction, for a fresh deployment.
    function seed(int256[] calldata answers, uint64[] calldata stamps) external onlyWriter {
        for (uint256 i = 0; i < answers.length; i++) {
            push(answers[i], stamps[i]);
        }
    }
}
