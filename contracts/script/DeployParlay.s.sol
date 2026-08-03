// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ParlayFactory} from "../src/ParlayFactory.sol";

/// @title DeployParlay
/// @notice Deploys ParlayFactory against the existing registry and collateral,
///         appending the address to deployments/<chainid>.json.
contract DeployParlay is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address registry = vm.parseJsonAddress(json, ".registry");
        address coll = vm.parseJsonAddress(json, ".collateral");

        console.log("registry  ", registry);
        console.log("collateral", coll);

        vm.startBroadcast(pk);
        ParlayFactory factory = new ParlayFactory(coll, registry);
        vm.stopBroadcast();

        console.log("parlay    ", address(factory));
        vm.writeJson(vm.toString(address(factory)), path, ".parlayFactory");
        console.log("updated %s", path);
    }
}
