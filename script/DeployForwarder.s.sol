// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/TaskMarketForwarder.sol";

contract DeployForwarder is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_TOKEN_ADDRESS");
        address taskMarket = vm.envAddress("CONTRACT_ADDRESS");
        address authorizedRelayer = vm.envAddress("FORGE_SERVER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        TaskMarketForwarder forwarder = new TaskMarketForwarder(usdc, taskMarket, authorizedRelayer);

        vm.stopBroadcast();

        console.log("Forwarder (FORWARDER_ADDRESS):", address(forwarder));
        console.log("USDC:", usdc);
        console.log("TaskMarket:", taskMarket);
        console.log("Authorized relayer:", authorizedRelayer);
    }
}
