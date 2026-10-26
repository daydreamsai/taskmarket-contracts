// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/TaskMarketForwarderV2.sol";

/// @dev Deploys only. Trust it with AddForwarder.s.sol and keep the previous forwarder trusted
///      until the relayer has switched, then remove that one (rev025 swap window).
contract DeployForwarderV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address usdc = vm.envOr("FORGE_USDC_TOKEN_ADDRESS", vm.envOr("USDC_TOKEN_ADDRESS", address(0)));
        require(usdc != address(0), "DeployForwarderV2: set FORGE_USDC_TOKEN_ADDRESS (or USDC_TOKEN_ADDRESS)");
        address taskMarket = vm.envAddress("CONTRACT_ADDRESS");
        address authorizedRelayer = vm.envAddress("FORGE_SERVER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        TaskMarketForwarderV2 forwarder = new TaskMarketForwarderV2(usdc, taskMarket, authorizedRelayer);

        vm.stopBroadcast();

        console.log("Forwarder v2 (FORWARDER_ADDRESS once trusted):", address(forwarder));
        console.log("USDC:", usdc);
        console.log("TaskMarket:", taskMarket);
        console.log("Authorized relayer:", authorizedRelayer);
    }
}
