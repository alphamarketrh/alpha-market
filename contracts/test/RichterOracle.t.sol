// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {RichterPositionOracle} from "../src/RichterPositionOracle.sol";
import {RichterMarketFactory} from "../src/RichterMarketFactory.sol";
import {RichterCore} from "../src/RichterCore.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";
import {ChainlinkRounds, IAggregatorV3} from "../src/ChainlinkRounds.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// A phase-encoded aggregator the test drives directly, so every failure path a
/// live feed will not perform on demand can still be exercised.
contract MockFeed is IAggregatorV3 {
    uint16 public phase = 1;
    int256[] internal _answers;
    uint256[] internal _stamps;

    function push(int256 a, uint256 t) external {
        _answers.push(a);
        _stamps.push(t);
    }

    function bumpPhase() external {
        phase += 1;
    }

    function count() external view returns (uint256) {
        return _answers.length;
    }

    function decimals() external pure returns (uint8) { return 8; }
    function description() external pure returns (string memory) { return "MOCK / USD"; }

    function _id(uint64 n) internal view returns (uint80) {
        return ChainlinkRounds.encodeRoundId(phase, n);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint64 n = uint64(_answers.length);
        return (_id(n), _answers[n - 1], _stamps[n - 1], _stamps[n - 1], _id(n));
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint16 p, uint64 n) = ChainlinkRounds.decodeRoundId(roundId);
        require(p == phase && n >= 1 && n <= _answers.length, "no round");
        return (roundId, _answers[n - 1], _stamps[n - 1], _stamps[n - 1], roundId);
    }
}

contract PausableStock {
    bool public paused;
    function setPaused(bool p) external { paused = p; }
    function oraclePaused() external view returns (bool) { return paused; }
}

contract RichterOracleTest is Test {
    RichterPositionOracle internal oracle;
    RichterMarketFactory internal factory;
    RichterCore internal core;
    MarketRegistry internal registry;
    MockUSDG internal usd;
    MockFeed internal feed;
    PausableStock internal stock;

    uint256 constant ONE = 1e6;
    uint256 constant HALF = 5e5;
    uint64 constant T0 = 1_785_000_000;
    uint64 constant CLOSE = T0 + 3600;
    uint64 constant OPEN = T0 + 3600 + 17 hours;

    function setUp() public {
        usd = new MockUSDG();
        registry = new MarketRegistry(address(usd), 100e6, 120, 0, address(this), 86400, 604800);
        oracle = new RichterPositionOracle(address(this));
        core = new RichterCore(address(usd), address(oracle));
        factory = new RichterMarketFactory(address(registry), address(oracle), address(this));
        factory.addCore(address(core));

        oracle.setFactory(address(factory));
        registry.setRelayer(address(factory), true);

        feed = new MockFeed();
        stock = new PausableStock();

        // A day of rounds: some before the close, a gap over the closed session,
        // then rounds after the open. 100.00 with 8 decimals.
        feed.push(99_00000000, T0);
        feed.push(100_00000000, CLOSE - 600);
        feed.push(100_00000000, CLOSE - 60);       // the close price
        feed.push(103_00000000, OPEN + 30);        // the open price, up 3%
        feed.push(103_50000000, OPEN + 600);

        factory.setTicker(address(feed), address(stock), 500, true);   // 5% cap
        vm.warp(OPEN + 3600);
    }

    function _open() internal returns (bytes32 id) {
        id = factory.open(address(feed), CLOSE, OPEN);
    }

    // -- settlement arithmetic ----------------------------------------------

    function test_aThreePercentMoveAgainstAFivePercentCap() public {
        bytes32 id = _open();
        // 3 of 5 is 0.6
        assertEq(oracle.settlementFraction(id), 600_000);
    }

    function test_directionIsDiscarded() public {
        MockFeed down = new MockFeed();
        down.push(100_00000000, CLOSE - 60);
        down.push(97_00000000, OPEN + 30);          // down 3%
        factory.setTicker(address(down), address(0), 500, true);
        bytes32 id = factory.open(address(down), CLOSE, OPEN);
        assertEq(oracle.settlementFraction(id), 600_000, "a fall settles like a rise");
    }

    function test_aMoveAtTheCapSettlesInFull() public {
        MockFeed big = new MockFeed();
        big.push(100_00000000, CLOSE - 60);
        big.push(108_00000000, OPEN + 30);          // 8%, over a 5% cap
        factory.setTicker(address(big), address(0), 500, true);
        bytes32 id = factory.open(address(big), CLOSE, OPEN);
        assertEq(oracle.settlementFraction(id), ONE);
    }

    function test_noMoveSettlesAtZero() public {
        MockFeed flat = new MockFeed();
        flat.push(100_00000000, CLOSE - 60);
        flat.push(100_00000000, OPEN + 30);
        factory.setTicker(address(flat), address(0), 500, true);
        bytes32 id = factory.open(address(flat), CLOSE, OPEN);
        assertEq(oracle.settlementFraction(id), 0);
    }

    function testFuzz_fractionAlwaysInRange(uint256 moveBps) public {
        moveBps = bound(moveBps, 0, 5000);
        MockFeed f = new MockFeed();
        f.push(100_00000000, CLOSE - 60);
        f.push(int256(100_00000000 + (100_00000000 * moveBps) / 10_000), OPEN + 30);
        factory.setTicker(address(f), address(0), 500, true);
        bytes32 id = factory.open(address(f), CLOSE, OPEN);
        uint256 s = oracle.settlementFraction(id);
        assertLe(s, ONE, "a fraction can never exceed one");
    }

    // -- the void paths ------------------------------------------------------

    function test_aPausedOracleVoids() public {
        bytes32 id = _open();
        stock.setPaused(true);
        assertEq(oracle.settlementFraction(id), HALF, "paused pays half to each");
    }

    function test_aPhaseChangeVoids() public {
        bytes32 id = _open();
        feed.bumpPhase();
        assertEq(oracle.settlementFraction(id), HALF, "a new aggregator voids the window");
    }

    function test_noRoundAfterTheOpenVoids() public {
        MockFeed stale = new MockFeed();
        stale.push(100_00000000, CLOSE - 60);       // nothing after the open at all
        factory.setTicker(address(stale), address(0), 500, true);
        bytes32 id = factory.open(address(stale), CLOSE, OPEN);
        assertEq(oracle.settlementFraction(id), HALF);
    }

    function test_aRoundTooLongAfterTheOpenVoids() public {
        MockFeed late = new MockFeed();
        late.push(100_00000000, CLOSE - 60);
        late.push(110_00000000, OPEN + 7 hours);    // past the six hour lag
        factory.setTicker(address(late), address(0), 500, true);
        vm.warp(OPEN + 8 hours);
        bytes32 id = factory.open(address(late), CLOSE, OPEN);
        assertEq(oracle.settlementFraction(id), HALF, "a sequencer outage voids rather than lies");
    }

    function test_noRoundBeforeTheCloseVoids() public {
        MockFeed young = new MockFeed();
        young.push(100_00000000, OPEN + 30);        // history starts after the close
        factory.setTicker(address(young), address(0), 500, true);
        bytes32 id = factory.open(address(young), CLOSE, OPEN);
        assertEq(oracle.settlementFraction(id), HALF);
    }

    // -- window rules --------------------------------------------------------

    function test_cannotSettleBeforeTheOpen() public {
        bytes32 id = _open();
        vm.warp(OPEN - 1);
        vm.expectRevert();
        oracle.settlementFraction(id);
    }

    function test_priceOfIsZeroBeforeTheOpen() public {
        bytes32 id = _open();
        vm.warp(OPEN - 1);
        (uint256 p, uint256 at) = oracle.priceOf(id, true);
        assertEq(p, 0);
        assertEq(at, 0);
        assertFalse(oracle.isPriced(id));
    }

    function test_priceOfMirrorsTheFractionAfterTheOpen() public {
        bytes32 id = _open();
        (uint256 pb,) = oracle.priceOf(id, true);
        (uint256 pc,) = oracle.priceOf(id, false);
        assertEq(pb, 600_000);
        assertEq(pb + pc, ONE, "both sides must sum to one unit");
        assertTrue(oracle.isPriced(id));
    }

    function test_onlyTheFactoryCanCreateAWindow() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(RichterPositionOracle.NotFactory.selector);
        oracle.createWindow(keccak256("x"), address(feed), address(0), 500, CLOSE, OPEN);
    }

    // -- factory rules -------------------------------------------------------

    function test_openWiresRegistryOracleAndCore() public {
        bytes32 id = _open();
        assertTrue(registry.isTradeable(id), "the registry must know it");
        assertTrue(oracle.isKnownMarket(id), "the oracle must have a window");
        (address b, address c) = core.tokensOf(id);
        assertTrue(b != address(0) && c != address(0), "the pair must exist");
    }

    function test_theIdIsDerivedAndRecomputable() public {
        bytes32 id = _open();
        assertEq(id, factory.marketId(address(feed), 500, CLOSE), "anyone can recompute it");
    }

    function test_cannotOpenTheSameMarketTwice() public {
        bytes32 id = _open();
        vm.expectRevert(abi.encodeWithSelector(RichterMarketFactory.AlreadyOpened.selector, id));
        factory.open(address(feed), CLOSE, OPEN);
    }

    function test_anUnknownTickerIsRefused() public {
        MockFeed other = new MockFeed();
        other.push(1e8, T0);
        vm.expectRevert(abi.encodeWithSelector(RichterMarketFactory.UnknownTicker.selector, address(other)));
        factory.open(address(other), CLOSE, OPEN);
    }

    function test_aDisabledTickerIsRefused() public {
        factory.setTicker(address(feed), address(stock), 500, false);
        vm.expectRevert(abi.encodeWithSelector(RichterMarketFactory.TickerDisabled.selector, address(feed)));
        factory.open(address(feed), CLOSE, OPEN);
    }

    function test_aCloseStillAheadIsRefused() public {
        uint64 future = uint64(block.timestamp) + 1 days;
        vm.expectRevert(abi.encodeWithSelector(RichterMarketFactory.CloseInFuture.selector, future));
        factory.open(address(feed), future, future + 1 hours);
    }

    function test_aWindowLongerThanFiveDaysIsRefused() public {
        uint64 far = OPEN + 200 hours;
        vm.warp(far + 1);
        vm.expectRevert();
        factory.open(address(feed), CLOSE, far);
    }

    function test_openIsPermissionless() public {
        vm.prank(address(0xCAFE));
        bytes32 id = factory.open(address(feed), CLOSE, OPEN);
        assertTrue(oracle.isKnownMarket(id), "anyone may pay the gas to open one");
    }

    /// The cap floor exists because below 300 bps more than a quarter of measured
    /// windows settled at the ceiling, where the graded payout is a coin flip.
    function test_aCapBelowThreePercentIsRefused() public {
        MockFeed f = new MockFeed();
        f.push(1e8, CLOSE - 60);
        f.push(1e8, OPEN + 30);
        factory.setTicker(address(f), address(0), 100, true);
        vm.expectRevert(abi.encodeWithSelector(RichterPositionOracle.BadCap.selector, uint32(100)));
        factory.open(address(f), CLOSE, OPEN);
    }

    // -- end to end ----------------------------------------------------------

    function test_openSplitSettleRedeem() public {
        bytes32 id = _open();
        address alice = address(0xA11CE);
        usd.mint(alice, 1000e6);
        vm.startPrank(alice);
        usd.approve(address(core), type(uint256).max);
        core.split(id, 1000e6);
        vm.stopPrank();

        core.settle(id);
        (uint256 s,) = core.settlementOf(id);
        assertEq(s, 600_000);

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        core.redeem(id, 1000e6, 1000e6);
        assertEq(usd.balanceOf(alice) - before, 1000e6, "a full pair returns one unit");
    }
}
