// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MirrorPositionOracle} from "../src/MirrorPositionOracle.sol";
import {DirectionalVault} from "../src/DirectionalVault.sol";

/// @title DeployDirectional
/// @notice Deploys the position price oracle and the directional lending vault.
/// @dev The oracle is deliberately swappable. It currently relays Polymarket
///      prices; once Alpha Market forms its own order flow the vault should be
///      pointed at a book-derived source with setOracle, unchanged otherwise.
contract DeployDirectional is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address registry = vm.parseJsonAddress(json, ".registry");
        address core = vm.parseJsonAddress(json, ".core");
        address coll = vm.parseJsonAddress(json, ".collateral");

        uint256 maxAge = vm.envOr("POS_ORACLE_MAX_AGE", uint256(1 hours));
        uint256 maxMove = vm.envOr("POS_ORACLE_MAX_MOVE_BPS", uint256(2000));
        uint256 seed = vm.envOr("DV_FACILITY_SEED", uint256(100_000e6));
        address writer = vm.envOr("PRICE_WRITER", deployer);

        vm.startBroadcast(pk);
        MirrorPositionOracle oracle = new MirrorPositionOracle(registry, maxAge, maxMove);
        oracle.setWriter(writer, true);
        DirectionalVault vault = new DirectionalVault(core, address(oracle));
        if (seed > 0) {
            IERC20(coll).approve(address(vault), seed);
            vault.fund(seed);
        }
        vm.stopBroadcast();

        console.log("positionOracle  ", address(oracle));
        console.log("directionalVault", address(vault));
        console.log("writer          ", writer);
        console.log("funded          ", IERC20(coll).balanceOf(address(vault)));

        vm.writeJson(vm.toString(address(oracle)), path, ".positionOracle");
        vm.writeJson(vm.toString(address(vault)), path, ".directionalVault");
        vm.writeJson(vm.toString(writer), path, ".priceWriter");
    }
}
