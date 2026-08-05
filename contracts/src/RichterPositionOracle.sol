// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPositionOracle} from "./interfaces/IPositionOracle.sol";
import {IRichterOracle} from "./interfaces/IRichterOracle.sol";
import {ChainlinkRounds, IAggregatorV3, IAggregatorProxy} from "./ChainlinkRounds.sol";

interface IStockToken {
    function oraclePaused() external view returns (bool);
}

/**
 * Settlement and live pricing for markets on the size of a price move.
 *
 * A market names a feed, a cap and two timestamps. Settlement reads the last
 * round published at or before the close and the first published at or after the
 * open, and returns how far the price moved as a fraction of the cap.
 *
 * WHY THE PRICE IS NOT ADJUSTED FOR THE MULTIPLIER
 * Robinhood equity feeds quote the price of one token, with uiMultiplier already
 * applied upstream. Dividends and splits are handled there. Dividing it out again
 * would double count. This is documented by Robinhood and recorded in
 * relayer/src/equity.js.
 *
 * WHY THE CAP IS PER MARKET
 * Every published round for the four live feeds was replayed on 5 August 2026.
 * The median overnight move ranged from 0.75% on AMZN to 3.64% on AMD, a spread
 * of five times. A shared cap would leave AMD settling at the ceiling half the
 * time, where the graded payout collapses to a coin flip. The cap is therefore
 * fixed per market at creation and never shared.
 *
 * WHY A VOID PAYS ONE HALF
 * A market that cannot be settled honestly returns HALF rather than reverting
 * forever. BIG plus CALM still equals one unit, so every position stays solvent
 * and every loan stays repayable. Locking collateral behind a permanent revert
 * would be the worse failure.
 *
 * WHAT IS NOT COVERED
 * No L2 sequencer uptime feed is consulted, because its address is not published
 * in the Chainlink directory for this chain. During an outage no round appears
 * while the real price moves, so such a window voids through the staleness rule
 * below rather than settling against a price nobody could trade at.
 */
contract RichterPositionOracle is IRichterOracle, IPositionOracle, Ownable {
    error ZeroAddress();
    error NotFactory();
    error UnknownMarket(bytes32 id);
    error AlreadyExists(bytes32 id);
    error BadWindow(uint64 closeAt, uint64 openAt);
    error BadCap(uint32 capBps);
    error WindowOpen(bytes32 id, uint64 openAt);

    struct Window {
        address feed;      // Chainlink proxy for the ticker
        address token;     // stock token, read for oraclePaused
        uint32 capBps;     // move at or above this settles at ONE
        uint64 closeAt;    // exchange close, unix
        uint64 openAt;     // next exchange open, unix
        uint16 phase;      // aggregator phase at creation
        bool exists;
    }

    uint256 public constant ONE = 1e6;
    uint256 public constant HALF = 5e5;

    /// @notice Walk budget. The deepest 72 hour window measured on the four live
    ///         feeds needed 218 steps, on AMD, so this leaves more than double.
    uint256 public constant MAX_STEPS = 512;

    /// @notice A round published this long after the open is treated as the open
    ///         price. Beyond it the market voids, which is how a sequencer outage
    ///         or a halted feed is handled without a dedicated uptime feed.
    uint256 public maxOpenLagS = 6 hours;

    address public factory;
    mapping(bytes32 => Window) private _windows;

    event FactorySet(address factory);
    event ParamsSet(uint256 maxOpenLagS);
    event WindowCreated(bytes32 indexed id, address feed, uint32 capBps, uint64 closeAt, uint64 openAt);

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setParams(uint256 maxOpenLagS_) external onlyOwner {
        maxOpenLagS = maxOpenLagS_;
        emit ParamsSet(maxOpenLagS_);
    }

    /// @notice Record the window a market settles against.
    /// @dev The id is not chosen here. It is derived by the factory from the feed,
    ///      the cap and the close, so anyone can recompute it and check that a
    ///      market is what it claims to be.
    function createWindow(
        bytes32 id,
        address feed,
        address token,
        uint32 capBps,
        uint64 closeAt,
        uint64 openAt
    ) external onlyFactory {
        if (feed == address(0)) revert ZeroAddress();
        if (_windows[id].exists) revert AlreadyExists(id);
        if (openAt <= closeAt) revert BadWindow(closeAt, openAt);
        // Below 300 bps more than a quarter of historical windows settle at the
        // ceiling, where the payout stops being graded at all.
        if (capBps < 300 || capBps > 5000) revert BadCap(capBps);

        (uint80 rid,,,,) = IAggregatorV3(feed).latestRoundData();
        (uint16 phase,) = ChainlinkRounds.decodeRoundId(rid);

        _windows[id] = Window({
            feed: feed,
            token: token,
            capBps: capBps,
            closeAt: closeAt,
            openAt: openAt,
            phase: phase,
            exists: true
        });
        emit WindowCreated(id, feed, capBps, closeAt, openAt);
    }

    // ------------------------------------------------------------------
    // IRichterOracle
    // ------------------------------------------------------------------

    function isKnownMarket(bytes32 id) external view returns (bool) {
        return _windows[id].exists;
    }

    /// @inheritdoc IRichterOracle
    function settlementFraction(bytes32 id) external view returns (uint256) {
        Window memory w = _windows[id];
        if (!w.exists) revert UnknownMarket(id);
        // Every timestamp comparison here gates on a window measured in hours,
        // so a validator shifting the clock by seconds can only move settlement
        // by seconds and cannot change which rounds are read.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < w.openAt) revert WindowOpen(id, w.openAt);
        return _settle(w);
    }

    /// @notice What the market would settle at, and whether it voids, without
    ///         reverting. For interfaces and for the factory to check itself.
    function preview(bytes32 id)
        external
        view
        returns (bool ready, uint256 fraction, bool voided)
    {
        Window memory w = _windows[id];
        if (!w.exists || block.timestamp < w.openAt) return (false, 0, false);
        uint256 s = _settle(w);
        return (true, s, s == HALF && _voids(w));
    }

    function windowOf(bytes32 id) external view returns (Window memory) {
        return _windows[id];
    }

    // ------------------------------------------------------------------
    // IPositionOracle, so CrossVault can value a live Richter position
    // ------------------------------------------------------------------

    /// @inheritdoc IPositionOracle
    /// @dev Before the open there is no price to give: nothing has happened yet
    ///      and the order book is the only opinion that exists. isPriced returns
    ///      false until then, and DirectionalVault refuses Richter markets
    ///      outright, so the only consumer is CrossVault after settlement.
    function priceOf(bytes32 id, bool isBig)
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        Window memory w = _windows[id];
        if (!w.exists) revert UnknownMarket(id);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < w.openAt) return (0, 0);
        uint256 s = _settle(w);
        return (isBig ? s : ONE - s, w.openAt);
    }

    /// @inheritdoc IPositionOracle
    function isPriced(bytes32 id) external view returns (bool) {
        Window memory w = _windows[id];
        return w.exists && block.timestamp >= w.openAt;
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    function _voids(Window memory w) internal view returns (bool) {
        if (w.token != address(0)) {
            // The flag is advisory and the feed does not enforce it, so a token
            // that does not answer is treated as not paused rather than as void.
            try IStockToken(w.token).oraclePaused() returns (bool paused) {
                if (paused) return true;
            } catch {}
        }

        IAggregatorV3 feed = IAggregatorV3(w.feed);

        (uint80 rid,,,,) = feed.latestRoundData();
        (uint16 phase,) = ChainlinkRounds.decodeRoundId(rid);
        // A new aggregator restarts the round counter, so a walk back across the
        // change would address rounds that never existed.
        if (phase != w.phase) return true;

        (bool okClose,) = _tryLastAtOrBefore(feed, w.closeAt);
        if (!okClose) return true;

        (bool okOpen, ChainlinkRounds.Round memory open) = _tryFirstAtOrAfter(feed, w.openAt);
        if (!okOpen) return true;
        // casting to uint256 widens a uint64 and cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (open.updatedAt > uint256(w.openAt) + maxOpenLagS) return true;

        return false;
    }

    function _settle(Window memory w) internal view returns (uint256) {
        if (_voids(w)) return HALF;

        (, ChainlinkRounds.Round memory close) = _tryLastAtOrBefore(IAggregatorV3(w.feed), w.closeAt);
        (, ChainlinkRounds.Round memory open) = _tryFirstAtOrAfter(IAggregatorV3(w.feed), w.openAt);

        // casting to uint256 is safe because ChainlinkRounds reverts with
        // BadAnswer on any answer at or below zero, and _voids above turns that
        // revert into a void, so a negative answer never reaches this line.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(close.answer);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 b = uint256(open.answer);
        uint256 diff = b > a ? b - a : a - b;

        // moveBps = diff / a, in basis points. Direction is discarded on purpose.
        uint256 moveBps = (diff * 10_000) / a;
        if (moveBps >= w.capBps) return ONE;
        return (moveBps * ONE) / w.capBps;
    }

    function _tryLastAtOrBefore(IAggregatorV3 feed, uint64 t)
        internal
        view
        returns (bool ok, ChainlinkRounds.Round memory r)
    {
        try this.externalLastAtOrBefore(feed, t) returns (ChainlinkRounds.Round memory got) {
            return (true, got);
        } catch {
            return (false, r);
        }
    }

    function _tryFirstAtOrAfter(IAggregatorV3 feed, uint64 t)
        internal
        view
        returns (bool ok, ChainlinkRounds.Round memory r)
    {
        try this.externalFirstAtOrAfter(feed, t) returns (ChainlinkRounds.Round memory got) {
            return (true, got);
        } catch {
            return (false, r);
        }
    }

    /// @dev The library reverts on every failure it can detect, which is correct
    ///      for a settlement that must never guess. Turning those reverts into a
    ///      void needs try/catch, and try/catch needs an external call, so these
    ///      two exist purely to give the internal walk an external boundary.
    function externalLastAtOrBefore(IAggregatorV3 feed, uint64 t)
        external
        view
        returns (ChainlinkRounds.Round memory)
    {
        return ChainlinkRounds.lastAtOrBefore(feed, t, MAX_STEPS);
    }

    function externalFirstAtOrAfter(IAggregatorV3 feed, uint64 t)
        external
        view
        returns (ChainlinkRounds.Round memory)
    {
        return ChainlinkRounds.firstAtOrAfter(feed, t, MAX_STEPS);
    }
}
