// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {MarginVault} from "../src/MarginVault.sol";

/// @title DeployPair
/// @notice Deploys a second settlement currency alongside the existing one.
///
/// @dev ONE REGISTRY, MANY CORES
///      A question resolves once. Everything downstream of that answer can be
///      denominated in whatever asset the holder already owns. So the registry
///      is shared and a fresh core, book and vault are deployed per collateral.
///      YES-aUSD and YES-TSLA on the same question are different tokens with
///      different books and different prices, and that is correct: they are
///      priced in different units, exactly as BTC/USD and BTC/EUR differ.
///
/// @dev WHY THIS NEEDS NO ORACLE
///      MarginVault lends against min(YES, NO), a floor proven by enumerating
///      the outcome space rather than read from a price. That proof holds in
///      any unit, so a TSLA-denominated pair inherits it unchanged: no price
///      feed, no liquidation, no bad debt. Cross-collateral lending, where a
///      TSLA position secures an aUSD loan, is a separate module because that
///      one genuinely does need a price.
///
/// @dev WRITES TO A SEPARATE FILE ON PURPOSE
///      The primary deployment record is left untouched so that a failure here
///      cannot disturb the running system.
///
/// @dev Deployment and recording are split into separate functions because
///      holding every address and parameter in one frame exhausts the EVM
///      stack. Each half keeps its own locals.
contract DeployPair is Script {
    struct Deployed {
        address core;
        address book;
        address vault;
    }

    /// @dev Symbol and decimals are supplied rather than read from the token.
    ///      Robinhood stock tokens are beacon proxies, and a local simulator
    ///      cannot execute proxy to beacon to implementation, so any call to
    ///      them reverts with NotActivated before a single transaction is
    ///      broadcast. Every contract touching a stock token takes decimals
    ///      as a parameter for the same reason.
    function run() external {
        address collateral = vm.envAddress("PAIR_COLLATERAL");
        uint8 dec = uint8(vm.envUint("PAIR_DECIMALS"));
        string memory symbol = vm.envString("PAIR_SYMBOL");
        address registry = vm.parseJsonAddress(
            vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json")),
            ".registry"
        );

        console.log("collateral ", collateral);
        console.log("symbol     ", symbol);
        console.log("decimals   ", dec);
        console.log("registry   ", registry);

        Deployed memory d = _deploy(collateral, registry, dec);
        _record(collateral, symbol, d, dec);
    }

    function _deploy(address collateral, address registry, uint8 dec)
        internal
        returns (Deployed memory d)
    {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        // Sizes are given in whole units so one setting serves a 6 decimal
        // stablecoin and an 18 decimal equity alike.
        uint256 whole = 10 ** dec;
        uint256 cap = vm.envOr("PAIR_FACILITY_CAP", uint256(100)) * whole;
        uint256 seed = vm.envOr("PAIR_SEED_WHOLE", uint256(2)) * whole;
        uint16 feeBps = uint16(vm.envOr("PAIR_BOOK_FEE_BPS", uint256(20)));

        vm.startBroadcast(pk);
        AlphaMarketCore core = new AlphaMarketCore(collateral, registry);
        OrderBook book = new OrderBook(address(core), feeBps);
        MarginVault vault = new MarginVault(address(core), 500, 1500, cap);
        if (seed > 0) {
            IERC20(collateral).approve(address(vault), seed);
            vault.fund(seed);
        }
        vm.stopBroadcast();

        d = Deployed(address(core), address(book), address(vault));
        console.log("core       ", d.core);
        console.log("orderBook  ", d.book);
        console.log("marginVault", d.vault);
    }

    function _record(address collateral, string memory symbol, Deployed memory d, uint8 dec)
        internal
    {
        string memory k = "pair";
        vm.serializeString(k, "symbol", symbol);
        vm.serializeUint(k, "decimals", uint256(dec));
        vm.serializeAddress(k, "collateral", collateral);
        vm.serializeAddress(k, "core", d.core);
        vm.serializeAddress(k, "orderBook", d.book);
        string memory json = vm.serializeAddress(k, "marginVault", d.vault);

        string memory out = string.concat(
            "deployments/", vm.toString(block.chainid), "-pair-", symbol, ".json"
        );
        vm.writeJson(json, out);
        console.log("written to ", out);
    }
}
