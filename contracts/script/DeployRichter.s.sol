// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RichterCore} from "../src/RichterCore.sol";
import {RichterPositionOracle} from "../src/RichterPositionOracle.sol";
import {RichterMarketFactory} from "../src/RichterMarketFactory.sol";
import {MirrorAggregator} from "../src/testing/MirrorAggregator.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";

/**
 * Deploy the Richter contracts.
 *
 * On chain 46630 it also deploys one MirrorAggregator per ticker, because that
 * chain has no equity feeds and a market cannot otherwise be opened. On any other
 * chain it refuses to deploy them: MirrorAggregator carries bumpPhase and
 * setPaused, which exist so the failure paths can be forced, and neither has any
 * business on a chain holding real money.
 *
 * Caps come from the calibration study of 5 August 2026, which replayed every
 * published round on the four live mainnet feeds. They are per ticker because the
 * median overnight move ran from 0.75% on AMZN to 3.64% on AMD.
 *
 *   forge script script/DeployRichter.s.sol --rpc-url rh_testnet -vvv
 *   forge script script/DeployRichter.s.sol --rpc-url rh_testnet --broadcast -vvv
 *
 * Without --broadcast nothing is sent. Run it that way first.
 */
contract DeployRichter is Script {
    error WrongChain(uint256 chainId);
    error MissingRegistry();

    uint256 constant TESTNET = 46630;
    uint256 constant MAINNET = 4663;

    struct TickerSpec {
        string symbol;
        uint32 capBps;
        address mainnetFeed;
        address testnetToken;
    }

    function _tickers() internal pure returns (TickerSpec[4] memory t) {
        // capBps set near the measured p90 of the overnight move, per ticker.
        t[0] = TickerSpec("AMZN", 300,
            0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C,
            0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02);
        t[1] = TickerSpec("TSLA", 400,
            0x4A1166a659A55625345e9515b32adECea5547C38,
            0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E);
        t[2] = TickerSpec("PLTR", 500,
            0x820ABedFF239034956B7A9d2F0a331f9F075eB4c,
            0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0);
        t[3] = TickerSpec("AMD", 800,
            0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72,
            0x71178BAc73cBeb415514eB542a8995b82669778d);
    }

    function run() external {
        uint256 chainId = block.chainid;
        if (chainId != TESTNET && chainId != MAINNET) revert WrongChain(chainId);

        string memory path = string.concat("deployments/", vm.toString(chainId), ".json");
        string memory existing = vm.readFile(path);
        address registry = vm.parseJsonAddress(existing, ".registry");
        address collateral = vm.parseJsonAddress(existing, ".collateral");
        if (registry == address(0)) revert MissingRegistry();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("chain      ", chainId);
        console.log("deployer   ", deployer);
        console.log("registry   ", registry);
        console.log("collateral ", collateral);

        vm.startBroadcast(pk);

        RichterPositionOracle oracle = new RichterPositionOracle(deployer);
        RichterMarketFactory factory =
            new RichterMarketFactory(registry, address(oracle), deployer);
        oracle.setFactory(address(factory));

        // One core per settlement currency, because collateral is immutable on
        // the core. Alpha Market settles in five, so Richter does too: a market
        // that existed in only some of them would be a different market
        // depending on which page a user opened.
        address[5] memory collaterals = _collaterals(collateral);
        for (uint256 c = 0; c < collaterals.length; c++) {
            if (collaterals[c] == address(0)) continue;
            RichterCore core = new RichterCore(collaterals[c], address(oracle));
            factory.addCore(address(core));
            console.log("core", collaterals[c], address(core));
        }

        TickerSpec[4] memory ts = _tickers();
        address[4] memory feeds;

        for (uint256 i = 0; i < 4; i++) {
            address feed;
            address stock;

            if (chainId == TESTNET) {
                // No equity feeds exist here, so a mirror is deployed and the
                // relayer fills it with the real mainnet price it already reads.
                MirrorAggregator m = new MirrorAggregator(
                    string.concat("Mirror ", ts[i].symbol, " / USD"), 8, deployer
                );
                // The relayer is what keeps the mirror fed, so it needs the
                // writer role at deployment. Granting it later by hand is how a
                // deployment ends up half wired, which is exactly what happened
                // on 6 August 2026: push reverted with NotWriter for a full
                // cycle before anyone noticed.
                m.setWriter(vm.envAddress("RELAYER_ADDRESS"), true);
                feed = address(m);
                stock = address(m);          // the mirror carries the pause flag too
            } else {
                feed = ts[i].mainnetFeed;
                stock = address(0);          // pause flag lives on the stock token, wired separately
            }

            factory.setTicker(feed, stock, ts[i].capBps, true);
            feeds[i] = feed;
            console.log(ts[i].symbol, feed, ts[i].capBps);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("RichterPositionOracle", address(oracle));
        console.log("RichterMarketFactory ", address(factory));
        console.log("cores registered     ", factory.coreCount());
        console.log("");
        console.log("NEXT, one transaction from the registry owner:");
        console.log("  registry.setRelayer(factory, true)");
        console.log("Until that is sent, factory.open reverts and no market exists.");

        _write(path, address(oracle), address(factory), feeds, ts);
    }

    /// @dev The five settlement currencies, read from the existing deployment
    ///      file rather than hardcoded, so adding a sixth needs no code change.
    function _collaterals(address aUsd) internal view returns (address[5] memory out) {
        out[0] = aUsd;
        string[4] memory syms = ["TSLA", "AMD", "AMZN", "PLTR"];
        for (uint256 i = 0; i < 4; i++) {
            string memory file =
                string.concat("deployments/", vm.toString(block.chainid), "-pair-", syms[i], ".json");
            try vm.readFile(file) returns (string memory j) {
                out[i + 1] = vm.parseJsonAddress(j, ".collateral");
            } catch {
                out[i + 1] = address(0);
            }
        }
    }

    function _write(
        string memory path,
        address oracle,
        address factory,
        address[4] memory feeds,
        TickerSpec[4] memory ts
    ) internal {
        string memory k = "richter";
        vm.serializeAddress(k, "richterPositionOracle", oracle);
        vm.serializeAddress(k, "richterMarketFactory", factory);
        for (uint256 i = 0; i < 4; i++) {
            vm.serializeAddress(k, string.concat("feed", ts[i].symbol), feeds[i]);
        }
        string memory out = vm.serializeString(
            k, "richterNote",
            "caps are per ticker, set from the calibration study of 5 Aug 2026"
        );
        vm.writeJson(out, string.concat("deployments/richter-", vm.toString(block.chainid), ".json"));
        console.log("wrote deployments/richter-%s.json", vm.toString(block.chainid));
    }
}
