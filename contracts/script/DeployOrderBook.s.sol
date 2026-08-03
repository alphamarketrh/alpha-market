// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {OrderBook} from "../src/OrderBook.sol";

/// @title DeployOrderBook
/// @notice Deploys the on-chain limit order book against the existing core.
/// @dev The fee is capped at 200 bps inside the contract, not merely by policy,
///      so a compromised owner cannot turn it into a confiscation lever.
contract DeployOrderBook is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address core = vm.parseJsonAddress(json, ".core");
        uint16 feeBps = uint16(vm.envOr("BOOK_FEE_BPS", uint256(20)));

        console.log("core   ", core);
        console.log("feeBps ", feeBps);

        vm.startBroadcast(pk);
        OrderBook book = new OrderBook(core, feeBps);
        vm.stopBroadcast();

        console.log("orderBook", address(book));
        vm.writeJson(vm.toString(address(book)), path, ".orderBook");
        vm.writeJson(vm.toString(uint256(feeBps)), path, ".bookFeeBps");
    }
}
