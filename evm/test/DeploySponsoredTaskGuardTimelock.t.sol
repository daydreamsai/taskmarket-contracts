// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { DeploySponsoredTaskGuardTimelock } from "../script/DeploySponsoredTaskGuardTimelock.s.sol";

/// @dev Code-bearing stand-in for the Safe, which the script requires to be a contract.
contract GuardTimelockSafeStandIn { }

contract DeploySponsoredTaskGuardTimelockTest is Test {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;
    address private constant STANDING_ADMIN = address(0xAD11);

    address private safe;
    address private deployer;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_KEY);
        safe = address(new GuardTimelockSafeStandIn());
        vm.setEnv("TIMELOCK_DEPLOYER_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("TIMELOCK_SAFE", vm.toString(safe));
        vm.setEnv("TIMELOCK_MIN_DELAY", "86400");
    }

    function testUnsetAdminLeavesNoStandingAdmin() public {
        vm.setEnv("TIMELOCK_ADMIN", "");
        TimelockController t = TimelockController(payable(new DeploySponsoredTaskGuardTimelock().run()));
        bytes32 role = t.DEFAULT_ADMIN_ROLE();
        assertTrue(t.hasRole(role, address(t)));
        assertFalse(t.hasRole(role, deployer));
        assertFalse(t.hasRole(role, safe));
    }

    function testZeroAdminIsTreatedAsUnset() public {
        vm.setEnv("TIMELOCK_ADMIN", vm.toString(address(0)));
        TimelockController t = TimelockController(payable(new DeploySponsoredTaskGuardTimelock().run()));
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(0)));
    }

    function testStandingAdminIsGrantedAndVerified() public {
        vm.setEnv("TIMELOCK_ADMIN", vm.toString(STANDING_ADMIN));
        TimelockController t = TimelockController(payable(new DeploySponsoredTaskGuardTimelock().run()));
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), STANDING_ADMIN));
    }

    function testDeployerAsAdminReverts() public {
        vm.setEnv("TIMELOCK_ADMIN", vm.toString(deployer));
        DeploySponsoredTaskGuardTimelock script = new DeploySponsoredTaskGuardTimelock();
        vm.expectRevert(bytes("DeployGuardTimelock: TIMELOCK_ADMIN must not be the deployer"));
        script.run();
    }
}
