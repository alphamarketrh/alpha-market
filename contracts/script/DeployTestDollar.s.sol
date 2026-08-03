// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TestDollar} from "../src/TestDollar.sol";

/// @title DeployTestDollar
/// @notice Deploys the testnet settlement collateral and records it as the
///         collateral address for every downstream contract.
/// @dev Not deployed on mainnet. There COLLATERAL is set to the real USDG
///      address issued by Paxos and this script is never run.
contract DeployTestDollar is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // 10,000 aUSD per claim is enough to place meaningful orders and still
        // feel the cost of a bad one. A 12 hour cooldown roughly matches the
        // 24 hour rhythm of the official Robinhood faucet.
        uint256 claimAmount = vm.envOr("AUSD_CLAIM", uint256(10_000e6));
        uint256 cooldown = vm.envOr("AUSD_COOLDOWN", uint256(12 hours));
        uint256 cap = vm.envOr("AUSD_SUPPLY_CAP", uint256(100_000_000e6));

        vm.startBroadcast(pk);
        TestDollar usd = new TestDollar(claimAmount, cooldown, cap);
        usd.claim();
        vm.stopBroadcast();

        console.log("testDollar  ", address(usd));
        console.log("claimAmount ", claimAmount);
        console.log("cooldown    ", cooldown);
        console.log("supplyCap   ", cap);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(vm.toString(address(usd)), path, ".collateral");
        vm.writeJson(vm.toString(address(usd)), path, ".testDollar");
        vm.writeJson("false", path, ".collateralIsMock");
    }
}
