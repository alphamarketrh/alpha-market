// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RichterOrderBook} from "../src/RichterOrderBook.sol";
import {RichterMarketFactory} from "../src/RichterMarketFactory.sol";
import {RichterCore} from "../src/RichterCore.sol";

/**
 * Deploy one order book per Richter core.
 *
 * Separate from DeployRichter because the cores already exist and already hold
 * markets. Re-running the full deploy would mint a fresh oracle, factory and five
 * cores, orphaning every market already open and invalidating every address in
 * /config and the README. This adds only what is missing.
 *
 * A book per core is not a choice. OrderBook holds its core as an immutable with
 * no setter, so one book can never reach another core's pairs.
 *
 *   forge script script/DeployRichterBooks.s.sol --rpc-url rh_testnet -vvv
 *   forge script script/DeployRichterBooks.s.sol --rpc-url rh_testnet --broadcast -vvv
 *
 * Without --broadcast nothing is sent.
 */
contract DeployRichterBooks is Script {
    error NoFactory();
    error NoCores();

    /// @notice Taker fee in basis points, matching the mirrored books already
    ///         deployed. Capped at 200 in the contract itself.
    uint16 constant BOOK_FEE_BPS = 20;

    function run() external {
        string memory path =
            string.concat("deployments/richter-", vm.toString(block.chainid), ".json");
        string memory existing = vm.readFile(path);
        address factoryAddr = vm.parseJsonAddress(existing, ".richterMarketFactory");
        if (factoryAddr == address(0)) revert NoFactory();

        RichterMarketFactory factory = RichterMarketFactory(factoryAddr);
        uint256 n = factory.coreCount();
        if (n == 0) revert NoCores();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        console.log("chain   ", block.chainid);
        console.log("factory ", factoryAddr);
        console.log("cores   ", n);

        vm.startBroadcast(pk);

        string memory k = "richterbooks";
        string memory out;
        for (uint256 i = 0; i < n; i++) {
            RichterCore core = RichterCore(address(factory.cores(i)));
            RichterOrderBook book = new RichterOrderBook(address(core), BOOK_FEE_BPS);
            console.log("book for core", address(core), address(book));
            out = vm.serializeAddress(k, vm.toString(address(core)), address(book));
        }

        vm.stopBroadcast();

        // Keyed by core address rather than by symbol, because the core is what a
        // book is bound to and a symbol would need a second lookup to be useful.
        vm.writeJson(out, string.concat("deployments/richter-books-", vm.toString(block.chainid), ".json"));
        console.log("");
        console.log("wrote deployments/richter-books-%s.json", vm.toString(block.chainid));
    }
}
