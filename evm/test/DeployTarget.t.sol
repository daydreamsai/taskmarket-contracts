// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeployTarget } from "../script/lib/DeployTarget.sol";

/// @dev Wraps the library so its revert surfaces at an external call boundary.
contract DeployTargetHarness {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function diamondFor() external view returns (address) {
        return DeployTarget.diamondFor(VM);
    }
}

contract DeployTargetTest is Test {
    DeployTargetHarness internal harness;

    function setUp() public {
        harness = new DeployTargetHarness();
        vm.setEnv("FORGE_DIAMOND_ADDRESS_8453", vm.toString(address(0xB8453)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(0xB84532)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_4217", vm.toString(address(0x74217)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_42431", vm.toString(address(0x742431)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_4663", vm.toString(address(0x84663)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_46630", vm.toString(address(0x846630)));
    }

    function test_DiamondFor_MapsEveryKnownChain() public {
        vm.chainId(8453);
        assertEq(harness.diamondFor(), address(0xB8453));
        vm.chainId(84532);
        assertEq(harness.diamondFor(), address(0xB84532));
        vm.chainId(4217);
        assertEq(harness.diamondFor(), address(0x74217));
        vm.chainId(42431);
        assertEq(harness.diamondFor(), address(0x742431));
        vm.chainId(4663);
        assertEq(harness.diamondFor(), address(0x84663));
        vm.chainId(46630);
        assertEq(harness.diamondFor(), address(0x846630));
    }

    function test_DiamondFor_RevertsOnUnknownChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployTarget.UnknownDeployTarget.selector, uint256(1)));
        harness.diamondFor();
    }
}
