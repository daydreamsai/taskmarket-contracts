// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/TaskMarket.sol";

contract UpgradeScript is Script {
    function run() external {
        address proxyAddress = vm.envAddress("CONTRACT_ADDRESS");
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        TaskMarket newImpl = new TaskMarket();
        TaskMarket(proxyAddress).upgradeToAndCall(address(newImpl), "");

        console.log("Proxy:", proxyAddress);
        console.log("Upgraded implementation to:", address(newImpl));

        vm.stopBroadcast();
    }
}
