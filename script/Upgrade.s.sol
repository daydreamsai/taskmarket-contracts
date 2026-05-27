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

        // Pass empty bytes when the upgrade introduces no new state variables.
        // If the upgrade introduces new state, replace "" with the ABI-encoded
        // reinitializer call. Example for a hypothetical initializeV2(address):
        //
        //   bytes memory initData = abi.encodeWithSelector(
        //       TaskMarket.initializeV2.selector,
        //       newDependencyAddress
        //   );
        //   TaskMarket(proxyAddress).upgradeToAndCall(address(newImpl), initData);
        //
        // The reinitializer MUST use reinitializer(N) where N increments by 1
        // for each upgrade that introduces new state. __Ownable_init and
        // __Pausable_init MUST NOT be called in any reinitializer.
        TaskMarket(proxyAddress).upgradeToAndCall(address(newImpl), "");

        console.log("Proxy:", proxyAddress);
        console.log("Upgraded implementation to:", address(newImpl));

        vm.stopBroadcast();
    }
}
