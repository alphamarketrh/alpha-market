// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RichterCore} from "../src/RichterCore.sol";
import {DirectionalVault} from "../src/DirectionalVault.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {MarketTypes} from "../src/types/MarketTypes.sol";
import {InterestModel} from "../src/InterestModel.sol";
import {IRichterOracle} from "../src/interfaces/IRichterOracle.sol";
import {IPositionOracle} from "../src/interfaces/IPositionOracle.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

contract StubRichterOracle is IRichterOracle {
    mapping(bytes32 => uint256) public frac;
    mapping(bytes32 => bool) public known;
    function set(bytes32 id, uint256 s) external { known[id] = true; frac[id] = s; }
    function isKnownMarket(bytes32 id) external view returns (bool) { return known[id]; }
    function settlementFraction(bytes32 id) external view returns (uint256) { return frac[id]; }
}

contract StubPositionOracle is IPositionOracle {
    function priceOf(bytes32, bool isYes) external pure returns (uint256, uint256) {
        return (isYes ? 600000 : 400000, 1);
    }
    function isPriced(bytes32) external pure returns (bool) { return true; }
}

/**
 * DirectionalVault must never lend against a Richter position.
 *
 * A one-sided position has no floor, so the vault marks it with an external
 * price. For a mirrored market that price comes from Polymarket, which is deep
 * and expensive to push. A Richter market has no such venue: the only mark would
 * be Alpha Market's own book, which can be pushed on thin liquidity, borrowed
 * against at a self-made price, and abandoned.
 *
 * The separation is structural rather than a gate. DirectionalVault resolves
 * token addresses through AlphaMarketCore, and a Richter pair is minted by
 * RichterCore, so the lookup returns the zero address and pledge reverts. These
 * tests exist so that structure cannot be quietly removed: if a future change
 * ever lets the two cores share a token mapping, they fail.
 */
contract RichterVaultSeparationTest is Test {
    MockUSDG internal usd;
    MarketRegistry internal registry;
    AlphaMarketCore internal alphaCore;
    RichterCore internal richterCore;
    StubRichterOracle internal rOracle;
    DirectionalVault internal vault;

    bytes32 constant RID = keccak256("richter-market");
    address internal alice = address(0xA11CE);

    function setUp() public {
        usd = new MockUSDG();
        registry = new MarketRegistry(address(usd), 100e6, 120, 0, address(this), 86400, 604800);
        alphaCore = new AlphaMarketCore(address(usd), address(registry));

        rOracle = new StubRichterOracle();
        richterCore = new RichterCore(address(usd), address(rOracle));

        InterestModel model = new InterestModel(200, 1500, 3000, 8000);
        vault = new DirectionalVault(
            address(alphaCore), address(new StubPositionOracle()), address(model), 6000
        );

        // A Richter market: registered, so the registry knows it, and initialized
        // on RichterCore, so its pair exists there and nowhere else.
        registry.setRelayer(address(this), true);
        registry.registerMarket(RID, uint64(block.timestamp + 1 days), 0);
        rOracle.set(RID, 600000);
        richterCore.initializeMarket(RID);

        usd.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usd.approve(address(richterCore), type(uint256).max);
        richterCore.split(RID, 1000e6);
        vm.stopPrank();
    }

    function test_theTwoCoresDoNotShareTokens() public view {
        (address rb, address rc) = richterCore.tokensOf(RID);
        (address ay, address an) = alphaCore.tokensOf(RID);
        assertTrue(rb != address(0) && rc != address(0), "Richter must have a pair");
        assertEq(ay, address(0), "AlphaMarketCore must not know this market");
        assertEq(an, address(0), "AlphaMarketCore must not know this market");
    }

    function test_pledgingARichterPositionReverts() public {
        (address big,) = richterCore.tokensOf(RID);
        vm.startPrank(alice);
        OutcomeToken(big).approve(address(vault), type(uint256).max);
        vm.expectRevert(DirectionalVault.MarketNotInitialized.selector);
        vault.pledge(RID, 1000e6, 0);
        vm.stopPrank();
    }

    function test_pledgingBothSidesAlsoReverts() public {
        (address big, address calm) = richterCore.tokensOf(RID);
        vm.startPrank(alice);
        OutcomeToken(big).approve(address(vault), type(uint256).max);
        OutcomeToken(calm).approve(address(vault), type(uint256).max);
        vm.expectRevert(DirectionalVault.MarketNotInitialized.selector);
        vault.pledge(RID, 1000e6, 1000e6);
        vm.stopPrank();
    }

    function test_theVaultHoldsNoRichterTokens() public view {
        (address big, address calm) = richterCore.tokensOf(RID);
        assertEq(OutcomeToken(big).balanceOf(address(vault)), 0);
        assertEq(OutcomeToken(calm).balanceOf(address(vault)), 0);
    }

    /// The user keeps leverage: holding both sides and borrowing 95% through
    /// LendingVault stays open, because min(BIG, CALM) is a proven floor whatever
    /// the settlement fraction turns out to be.
    function test_theMatchedPairIsStillWorthOneUnit() public {
        vm.prank(alice);
        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        richterCore.merge(RID, 1000e6);
        assertEq(usd.balanceOf(alice) - before, 1000e6);
    }
}
