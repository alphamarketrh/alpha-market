// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {MarketRegistry} from "../src/MarketRegistry.sol";
import {AlphaMarketCore} from "../src/AlphaMarketCore.sol";

/// @title Deploy
/// @notice Deploys the Alpha Market core stack and writes addresses to
///         deployments/<chainid>.json so the relayer and docs can read them.
/// @dev Collateral: if COLLATERAL env var is set, that token is used. Otherwise a
///      MockUSDG is deployed as test collateral, which is correct on testnet
///      where the real USDG is not present.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 bond = vm.envOr("BOND_AMOUNT", uint256(100e6));
        uint64 window = uint64(vm.envOr("CHALLENGE_WINDOW", uint256(2 hours)));
        // The depth gate was justified by market makers hedging back to Polymarket.
        // Odds now form in the venue own order flow, so it defaults off.
        uint128 floor = uint128(vm.envOr("MIN_DEPTH_USD", uint256(0)));
        address relayer = vm.envOr("RELAYER_ADDRESS", deployer);
        address collateral = vm.envOr("COLLATERAL", address(0));
        // The arbiter must not be the owner. Defaulting to the deployer is a
        // testnet convenience only; set ARBITER_ADDRESS to a separate multisig.
        address arbiter = vm.envOr("ARBITER_ADDRESS", deployer);
        uint64 rulingDelay = uint64(vm.envOr("RULING_DELAY", uint256(24 hours)));
        uint64 disputeTimeout = uint64(vm.envOr("DISPUTE_TIMEOUT", uint256(7 days)));

        console.log("chainid  ", block.chainid);
        console.log("deployer ", deployer);
        console.log("balance  ", deployer.balance);

        vm.startBroadcast(pk);

        bool mock = collateral == address(0);
        if (mock) {
            MockUSDG m = new MockUSDG();
            collateral = address(m);
            m.mint(deployer, 10_000_000e6);
            console.log("collateral (MockUSDG deployed)", collateral);
        } else {
            console.log("collateral (existing)", collateral);
        }

        MarketRegistry registry = new MarketRegistry(
            collateral, bond, window, floor, arbiter, rulingDelay, disputeTimeout);
        AlphaMarketCore core = new AlphaMarketCore(collateral, address(registry));
        registry.setRelayer(relayer, true);

        vm.stopBroadcast();

        console.log("registry ", address(registry));
        console.log("core     ", address(core));
        console.log("relayer  ", relayer);

        string memory k = "d";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "collateral", collateral);
        vm.serializeBool(k, "collateralIsMock", mock);
        vm.serializeAddress(k, "registry", address(registry));
        vm.serializeAddress(k, "relayer", relayer);
        vm.serializeUint(k, "bondAmount", bond);
        vm.serializeUint(k, "challengeWindow", window);
        vm.serializeUint(k, "minDepthUsd", floor);
        vm.serializeAddress(k, "arbiter", arbiter);
        vm.serializeUint(k, "rulingDelay", rulingDelay);
        vm.serializeUint(k, "disputeTimeout", disputeTimeout);
        string memory out = vm.serializeAddress(k, "core", address(core));

        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), ".json"));
        console.log("wrote deployments/%s.json", vm.toString(block.chainid));
    }
}
