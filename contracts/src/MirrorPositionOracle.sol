// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPositionOracle} from "./interfaces/IPositionOracle.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {MarketTypes} from "./types/MarketTypes.sol";

/// @title MirrorPositionOracle
/// @notice Outcome-token prices relayed from Polymarket, for use as collateral
///         valuation until Alpha Market has its own order flow.
///
/// @dev THIS IS THE WEAKEST LINK IN DirectionalVault, STATED PLAINLY.
///      MarginVault needs no price at all: min(YES, NO) is a floor proven by
///      enumeration. Here a writer sets the number that decides whether an
///      account is liquidated. A dishonest or compromised writer can therefore
///      manufacture a liquidation. Mitigations in this contract are real but
///      partial: multiple writers, a per-update move cap, and staleness that
///      freezes borrowing and liquidation together rather than acting on a
///      price nobody can trust.
///
/// @dev ONLY ONE SIDE IS STORED.
///      YES + NO always equals one whole unit, so NO is derived rather than
///      written. That removes a whole class of inconsistency where the two
///      sides disagree.
contract MirrorPositionOracle is IPositionOracle, Ownable {
    error NotWriter();
    error ZeroAddress();
    error BadPrice(uint256 price);
    error LengthMismatch();
    error MoveTooLarge(bytes32 id, uint256 from, uint256 to, uint256 capBps);
    error UnknownMarket(bytes32 id);

    struct Point {
        uint256 yesPrice;   // 0 to ONE
        uint64 updatedAt;
        bool seen;
    }

    uint256 public constant ONE = 1e6;
    uint256 private constant BPS = 10_000;

    MarketRegistry public immutable registry;

    /// @notice A price older than this is refused.
    uint256 public maxAge;

    /// @notice Largest single-update move, in basis points of ONE.
    /// @dev A genuine market can gap on news, so this cannot be tight. It exists
    ///      to stop a single bad write from zeroing every position at once; a
    ///      real move simply takes several updates to arrive.
    uint256 public maxMoveBps;

    mapping(address => bool) public isWriter;
    mapping(bytes32 => Point) private _points;

    event WriterSet(address indexed writer, bool allowed);
    event ParamsSet(uint256 maxAge, uint256 maxMoveBps);
    event PriceWritten(bytes32 indexed id, uint256 yesPrice, uint64 at);

    modifier onlyWriter() {
        if (!isWriter[msg.sender]) revert NotWriter();
        _;
    }

    constructor(address registry_, uint256 maxAge_, uint256 maxMoveBps_) Ownable(msg.sender) {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = MarketRegistry(registry_);
        maxAge = maxAge_;
        maxMoveBps = maxMoveBps_;
        emit ParamsSet(maxAge_, maxMoveBps_);
    }

    // ----------------------------------------------------------------- admin

    function setWriter(address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        isWriter[writer] = allowed;
        emit WriterSet(writer, allowed);
    }

    function setParams(uint256 maxAge_, uint256 maxMoveBps_) external onlyOwner {
        maxAge = maxAge_;
        maxMoveBps = maxMoveBps_;
        emit ParamsSet(maxAge_, maxMoveBps_);
    }

    // ----------------------------------------------------------------- write

    function writePrice(bytes32 id, uint256 yesPrice) public onlyWriter {
        if (yesPrice == 0 || yesPrice >= ONE) revert BadPrice(yesPrice);
        if (registry.statusOf(id) == MarketTypes.Status.None) revert UnknownMarket(id);

        Point storage p = _points[id];
        if (p.seen) {
            uint256 prev = p.yesPrice;
            uint256 diff = yesPrice > prev ? yesPrice - prev : prev - yesPrice;
            if (diff * BPS > ONE * maxMoveBps) {
                revert MoveTooLarge(id, prev, yesPrice, maxMoveBps);
            }
        }
        p.yesPrice = yesPrice;
        p.updatedAt = uint64(block.timestamp);
        p.seen = true;
        emit PriceWritten(id, yesPrice, p.updatedAt);
    }

    function writePrices(bytes32[] calldata ids, uint256[] calldata yesPrices)
        external
        onlyWriter
    {
        if (ids.length != yesPrices.length) revert LengthMismatch();
        for (uint256 i = 0; i < ids.length; i++) {
            writePrice(ids[i], yesPrices[i]);
        }
    }

    // ------------------------------------------------------------------ read

    /// @inheritdoc IPositionOracle
    function priceOf(bytes32 id, bool isYes)
        public
        view
        returns (uint256 price, uint256 updatedAt)
    {
        Point memory p = _points[id];
        if (!p.seen) revert UnknownMarket(id);
        price = isYes ? p.yesPrice : ONE - p.yesPrice;
        updatedAt = p.updatedAt;
        if (block.timestamp > updatedAt + maxAge) revert BadPrice(0);
    }

    /// @inheritdoc IPositionOracle
    function isPriced(bytes32 id) external view returns (bool) {
        Point memory p = _points[id];
        if (!p.seen) return false;
        return block.timestamp <= p.updatedAt + maxAge;
    }

    function pointOf(bytes32 id) external view returns (Point memory) {
        return _points[id];
    }
}
