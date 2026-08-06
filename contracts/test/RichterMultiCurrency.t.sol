// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RichterCore} from "../src/RichterCore.sol";
import {RichterPositionOracle} from "../src/RichterPositionOracle.sol";
import {RichterMarketFactory} from "../src/RichterMarketFactory.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MirrorAggregator} from "../src/testing/MirrorAggregator.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MockStock} from "./mocks/MockStock.sol";

/**
 * Alpha Market settles in five currencies, so Richter must too.
 *
 * A settlement currency is a whole core, because collateral is immutable on it.
 * A Richter market that existed in only some of them would be a different market
 * depending on which page a user opened, and a position taken in one could not be
 * closed in another. These tests hold that line.
 *
 * Decimals differ across the set: the dollar has six and the equity tokens have
 * eighteen. The settlement fraction is scaled to 1e6 regardless, so the same
 * fraction has to pay out correctly in both, and that is checked here rather than
 * assumed.
 */
contract RichterMultiCurrencyTest is Test {
    MarketRegistry internal registry;
    RichterPositionOracle internal oracle;
    RichterMarketFactory internal factory;
    MirrorAggregator internal feed;

    MockUSDG internal usd;      // 6 decimals
    MockStock internal tsla;    // 18 decimals
    MockStock internal amd;

    RichterCore internal coreUsd;
    RichterCore internal coreTsla;
    RichterCore internal coreAmd;

    uint64 constant T0 = 1_785_000_000;
    uint64 constant CLOSE = T0 + 3600;
    uint64 constant OPEN = CLOSE + 17 hours;

    address internal alice = address(0xA11CE);

    function setUp() public {
        usd = new MockUSDG();
        tsla = new MockStock("Tesla", "TSLA");
        amd = new MockStock("AMD", "AMD");

        registry = new MarketRegistry(address(usd), 100e6, 120, 0, address(this), 86400, 604800);
        oracle = new RichterPositionOracle(address(this));
        factory = new RichterMarketFactory(address(registry), address(oracle), address(this));
        oracle.setFactory(address(factory));
        registry.setRelayer(address(factory), true);

        coreUsd = new RichterCore(address(usd), address(oracle));
        coreTsla = new RichterCore(address(tsla), address(oracle));
        coreAmd = new RichterCore(address(amd), address(oracle));
        factory.addCore(address(coreUsd));
        factory.addCore(address(coreTsla));
        factory.addCore(address(coreAmd));

        feed = new MirrorAggregator("Mirror NVDA / USD", 8, address(this));
        feed.push(100_00000000, CLOSE - 600);
        feed.push(103_00000000, OPEN + 30);        // 3% against a 5% cap -> 0.6
        factory.setTicker(address(feed), address(feed), 500, true);

        vm.warp(OPEN + 3600);
    }

    function test_oneCallOpensThePairInEveryCurrency() public {
        bytes32 id = factory.open(address(feed), CLOSE, OPEN);

        assertEq(factory.coreCount(), 3);
        for (uint256 i = 0; i < 3; i++) {
            RichterCore c = RichterCore(address(factory.cores(i)));
            (address big, address calm) = c.tokensOf(id);
            assertTrue(big != address(0), "every core must hold a pair");
            assertTrue(calm != address(0), "every core must hold a pair");
        }
    }

    function test_theTokensAreDistinctPerCurrency() public {
        bytes32 id = factory.open(address(feed), CLOSE, OPEN);
        (address bu,) = coreUsd.tokensOf(id);
        (address bt,) = coreTsla.tokensOf(id);
        (address ba,) = coreAmd.tokensOf(id);
        assertTrue(bu != bt && bt != ba && bu != ba, "one question, three separate books");
    }

    /// The same fraction, settled in six-decimal and eighteen-decimal collateral.
    function test_theSameFractionPaysCorrectlyInBothDecimals() public {
        bytes32 id = factory.open(address(feed), CLOSE, OPEN);

        usd.mint(alice, 1_000e6);
        tsla.mint(alice, 1_000e18);

        vm.startPrank(alice);
        usd.approve(address(coreUsd), type(uint256).max);
        tsla.approve(address(coreTsla), type(uint256).max);
        coreUsd.split(id, 1_000e6);
        coreTsla.split(id, 1_000e18);
        vm.stopPrank();

        coreUsd.settle(id);
        coreTsla.settle(id);

        (uint256 sUsd,) = coreUsd.settlementOf(id);
        (uint256 sTsla,) = coreTsla.settlementOf(id);
        assertEq(sUsd, 600_000, "0.6 in the dollar core");
        assertEq(sTsla, 600_000, "the same 0.6 in the equity core");

        uint256 beforeUsd = usd.balanceOf(alice);
        uint256 beforeTsla = tsla.balanceOf(alice);
        vm.startPrank(alice);
        coreUsd.redeem(id, 1_000e6, 0);
        coreTsla.redeem(id, 1_000e18, 0);
        vm.stopPrank();

        assertEq(usd.balanceOf(alice) - beforeUsd, 600e6, "60% of a 6-decimal unit");
        assertEq(tsla.balanceOf(alice) - beforeTsla, 600e18, "60% of an 18-decimal unit");
    }

    /// A market opened before a currency was added gets filled in, not reopened.
    function test_aCurrencyAddedLaterCanBeFilledIn() public {
        bytes32 id = factory.open(address(feed), CLOSE, OPEN);

        MockStock pltr = new MockStock("Palantir", "PLTR");
        RichterCore corePltr = new RichterCore(address(pltr), address(oracle));
        factory.addCore(address(corePltr));

        (address b0,) = corePltr.tokensOf(id);
        assertEq(b0, address(0), "the new core has no pair yet");

        factory.initialiseIn(id, 3);
        (address b1, address c1) = corePltr.tokensOf(id);
        assertTrue(b1 != address(0) && c1 != address(0), "filled in without reopening");
    }

    function test_theSameCoreCannotBeAddedTwice() public {
        vm.expectRevert(
            abi.encodeWithSelector(RichterMarketFactory.CoreAlreadyAdded.selector, address(coreUsd))
        );
        factory.addCore(address(coreUsd));
    }

    function test_openRevertsWithNoCores() public {
        RichterPositionOracle o2 = new RichterPositionOracle(address(this));
        RichterMarketFactory f2 =
            new RichterMarketFactory(address(registry), address(o2), address(this));
        o2.setFactory(address(f2));
        f2.setTicker(address(feed), address(feed), 500, true);
        vm.expectRevert(RichterMarketFactory.NoCores.selector);
        f2.open(address(feed), CLOSE, OPEN);
    }

    /// Solvency has to hold per core. One core paying out must never be able to
    /// reach the collateral locked in another.
    function test_eachCoreHoldsItsOwnCollateral() public {
        bytes32 id = factory.open(address(feed), CLOSE, OPEN);
        usd.mint(alice, 1_000e6);
        tsla.mint(alice, 1_000e18);

        vm.startPrank(alice);
        usd.approve(address(coreUsd), type(uint256).max);
        tsla.approve(address(coreTsla), type(uint256).max);
        coreUsd.split(id, 1_000e6);
        coreTsla.split(id, 1_000e18);
        vm.stopPrank();

        assertEq(usd.balanceOf(address(coreUsd)), 1_000e6);
        assertEq(usd.balanceOf(address(coreTsla)), 0, "no dollar reaches the equity core");
        assertEq(tsla.balanceOf(address(coreTsla)), 1_000e18);
        assertEq(tsla.balanceOf(address(coreUsd)), 0, "no equity reaches the dollar core");
    }
}
