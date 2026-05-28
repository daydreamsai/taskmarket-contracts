// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";

contract AddForwarder is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = vm.envAddress("CONTRACT_ADDRESS");
        address forwarder = vm.envAddress("FORWARDER_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        AdminFacet(diamond).addForwarder(forwarder);
        vm.stopBroadcast();

        console.log("Added forwarder:", forwarder);
        console.log("To Diamond:", diamond);
    }
}
