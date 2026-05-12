// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/TaskMarket.sol";

contract AddForwarder is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address taskMarket = vm.envAddress("CONTRACT_ADDRESS");
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        TaskMarket(taskMarket).addForwarder(forwarder);
        vm.stopBroadcast();

        console.log("Added forwarder:", forwarder);
        console.log("To TaskMarket:", taskMarket);
    }
}
