// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarginVault} from "../src/MarginVault.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";

/// @title DeployVault
/// @notice Deploys MarginVault against an already-deployed core and funds the
///         capped treasury facility. Appends the address to the existing
///         deployments/<chainid>.json rather than overwriting it.
contract DeployVault is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address core = vm.parseJsonAddress(json, ".core");
        address coll = vm.parseJsonAddress(json, ".collateral");

        uint256 haircut = vm.envOr("HAIRCUT_BPS", uint256(500));      // 5%
        uint256 rate = vm.envOr("RATE_BPS", uint256(1500));           // 15% APR
        uint256 cap = vm.envOr("FACILITY_CAP", uint256(100_000e6));   // 100k USDG
        uint256 seed = vm.envOr("FACILITY_SEED", uint256(100_000e6));

        console.log("core      ", core);
        console.log("collateral", coll);
        console.log("deployer  ", deployer);

        vm.startBroadcast(pk);
        MarginVault vault = new MarginVault(core, haircut, rate, cap);
        if (seed > 0) {
            IERC20(coll).approve(address(vault), seed);
            vault.fund(seed);
        }
        vm.stopBroadcast();

        console.log("vault     ", address(vault));
        console.log("haircutBps", haircut);
        console.log("rateBps   ", rate);
        console.log("cap       ", cap);
        console.log("funded    ", IERC20(coll).balanceOf(address(vault)));

        vm.writeJson(vm.toString(address(vault)), path, ".marginVault");
        vm.writeJson(vm.toString(haircut), path, ".haircutBps");
        vm.writeJson(vm.toString(rate), path, ".rateBps");
        vm.writeJson(vm.toString(cap), path, ".facilityCap");
        console.log("updated %s", path);
    }
}
