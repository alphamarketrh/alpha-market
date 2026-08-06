// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketRegistry} from "./MarketRegistry.sol";
import {RichterPositionOracle} from "./RichterPositionOracle.sol";
import {RichterCore} from "./RichterCore.sol";

/**
 * Opens Richter markets on a schedule, in every settlement currency at once.
 *
 * WHY A CONTRACT AND NOT A SERVER
 * registerMarket is onlyRelayer, so something has to hold that role. For mirrored
 * markets it is an EOA running a Node process, which is right, because reading
 * Polymarket means reading another chain. Richter needs none of that: exchange
 * hours are a fixed rule and Chainlink prices sit on the same chain.
 *
 * With an EOA a user has to trust that a private server chose the right cap and
 * the right window, and has no way to check. Here the ticker list, the caps and
 * the schedule are readable on an explorer, and the market id is a hash of them,
 * so anyone can recompute an id and see it is what it claims to be. It also
 * removes an operational failure that has already happened twice: the existing
 * relayer has run out of gas silently, and market creation should not depend on
 * that.
 *
 * WHY EVERY CURRENCY AT ONCE
 * A settlement currency is a whole core, because collateral is immutable on it.
 * Alpha Market runs five: aUSD and the four equity tokens. A Richter market that
 * existed in only some of them would be a different market depending on which
 * page a user opened, so open initialises the pair on every registered core in
 * one call, exactly as the relayer does for a mirrored market.
 *
 * WHAT THIS CONTRACT CANNOT DO
 * The relayer role permits registerMarket, updateDepth, halt and unhalt. It
 * cannot move funds, resolve a market or change a parameter. A faulty factory
 * can at worst create junk markets, which can be halted, and the role is revoked
 * with setRelayer(factory, false) without touching any market already registered.
 *
 * CAPS ARE PER TICKER
 * Every published round on the four live feeds was replayed on 5 August 2026.
 * The median overnight move ran from 0.75% on AMZN to 3.64% on AMD. A shared cap
 * would leave AMD at the ceiling half the time, where the graded payout collapses
 * into a coin flip, so each ticker carries its own.
 */
contract RichterMarketFactory is Ownable {
    error ZeroAddress();
    error UnknownTicker(address feed);
    error TickerDisabled(address feed);
    error BadWindow(uint64 closeAt, uint64 openAt);
    error WindowTooLong(uint64 span);
    error CloseInFuture(uint64 closeAt);
    error AlreadyOpened(bytes32 id);
    error NoCores();
    error CoreAlreadyAdded(address core);
    error TooManyCores();

    struct Ticker {
        address token;    // stock token, read for the pause flag at settlement
        uint32 capBps;    // per ticker, set from the calibration study
        bool enabled;
    }

    /// @notice A window longer than this is refused. The longest legitimate one
    ///         is a holiday weekend at roughly 90 hours; beyond that the walk
    ///         depth and the risk both stop being something we have measured.
    uint64 public constant MAX_WINDOW = 120 hours;

    /// @notice Each core costs about 1.16 million gas to initialise, so the
    ///         ceiling keeps one open call inside a sane gas budget.
    uint256 public constant MAX_CORES = 8;

    MarketRegistry public immutable registry;
    RichterPositionOracle public immutable oracle;

    RichterCore[] public cores;
    mapping(address => bool) public isCore;
    mapping(address => Ticker) public tickers;
    mapping(bytes32 => bool) public opened;

    event CoreAdded(address indexed core, address collateral, uint256 index);
    event TickerSet(address indexed feed, address token, uint32 capBps, bool enabled);
    event MarketOpened(
        bytes32 indexed id,
        address indexed feed,
        uint32 capBps,
        uint64 closeAt,
        uint64 openAt,
        uint256 coreCount
    );
    event PairCreated(bytes32 indexed id, address indexed core, address big, address calm);

    constructor(address registry_, address oracle_, address owner_) Ownable(owner_) {
        if (registry_ == address(0) || oracle_ == address(0)) revert ZeroAddress();
        registry = MarketRegistry(registry_);
        oracle = RichterPositionOracle(oracle_);
    }

    /// @notice Register a settlement currency. One core serves one collateral,
    ///         because collateral is immutable on the core.
    function addCore(address core_) external onlyOwner {
        if (core_ == address(0)) revert ZeroAddress();
        if (isCore[core_]) revert CoreAlreadyAdded(core_);
        if (cores.length >= MAX_CORES) revert TooManyCores();
        isCore[core_] = true;
        cores.push(RichterCore(core_));
        emit CoreAdded(core_, address(RichterCore(core_).collateral()), cores.length - 1);
    }

    function coreCount() external view returns (uint256) {
        return cores.length;
    }

    function setTicker(address feed, address token, uint32 capBps, bool enabled)
        external
        onlyOwner
    {
        if (feed == address(0)) revert ZeroAddress();
        tickers[feed] = Ticker({token: token, capBps: capBps, enabled: enabled});
        emit TickerSet(feed, token, capBps, enabled);
    }

    /// @notice The id a market with these parameters must have.
    /// @dev Derived rather than assigned, so anyone can recompute it. The cap is
    ///      included so a market cannot be reopened under a different cap at the
    ///      same id, and this factory's address is included so two factories can
    ///      never collide.
    function marketId(address feed, uint32 capBps, uint64 closeAt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), feed, capBps, closeAt));
    }

    /// @notice Open one market in every registered settlement currency.
    /// @dev Permissionless: the caller pays the gas and every parameter is fixed
    ///      by the ticker table, so there is nothing to choose and nothing to
    ///      gain by calling first.
    function open(address feed, uint64 closeAt, uint64 openAt)
        external
        returns (bytes32 id)
    {
        uint256 n = cores.length;
        if (n == 0) revert NoCores();

        Ticker memory t = tickers[feed];
        if (t.capBps == 0 && !t.enabled) revert UnknownTicker(feed);
        if (!t.enabled) revert TickerDisabled(feed);
        if (openAt <= closeAt) revert BadWindow(closeAt, openAt);
        if (openAt - closeAt > MAX_WINDOW) revert WindowTooLong(openAt - closeAt);
        // The close must already have happened. Opening a market whose close is
        // still ahead would create it before the price it settles against exists,
        // which is a window nobody can reason about.
        // forge-lint: disable-next-line(block-timestamp)
        if (closeAt > block.timestamp) revert CloseInFuture(closeAt);

        id = marketId(feed, t.capBps, closeAt);
        if (opened[id]) revert AlreadyOpened(id);
        opened[id] = true;

        // depthUsd is meaningless for a Richter market and minDepthUsd is zero,
        // so it is passed as zero rather than invented. endTime is the open,
        // which is when the result becomes knowable.
        registry.registerMarket(id, openAt, 0);
        oracle.createWindow(id, feed, t.token, t.capBps, closeAt, openAt);

        for (uint256 i = 0; i < n; ++i) {
            (address big, address calm) = cores[i].initializeMarket(id);
            emit PairCreated(id, address(cores[i]), big, calm);
        }

        emit MarketOpened(id, feed, t.capBps, closeAt, openAt, n);
    }

    /// @notice Add a currency to a market that is already open.
    /// @dev A core registered after a market was opened has no pair for it, so
    ///      this fills the gap without reopening anything.
    function initialiseIn(bytes32 id, uint256 coreIndex)
        external
        returns (address big, address calm)
    {
        if (!opened[id]) revert AlreadyOpened(id);
        return cores[coreIndex].initializeMarket(id);
    }
}
