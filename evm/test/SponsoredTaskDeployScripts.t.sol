// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { DeploySponsoredTask } from "../script/DeploySponsoredTask.s.sol";

/// @dev Code-bearing Safe/timelock stand-in that can accept two-step ownership transfers.
contract SponsoredTaskAdminStandIn {
    function acceptOwnership(address ownable) external {
        SponsoredTaskRegistry(ownable).acceptOwnership();
    }
}

/// @dev DeploySponsoredTask deploys the shared pieces every V2 vault factory builds on: the registry
///      and the default fee policy. Rev030 retired the V1 hook and factory it used to deploy too.
contract SponsoredTaskDeployScriptsTest is Test {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;

    address private deployer;
    SponsoredTaskAdminStandIn private admin;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_KEY);
        admin = new SponsoredTaskAdminStandIn();

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(this))); // a contract
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", "750");
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        vm.setEnv("FORGE_SPONSORED_TASK_ADMIN", vm.toString(address(admin)));
    }

    function _deploy() private returns (SponsoredTaskRegistry registry, SponsoredTaskFeePolicy feePolicy) {
        vm.recordLogs();
        new DeploySponsoredTask().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            // The registry is the only contract that emits OwnershipTransferStarted in this script;
            // the fee policy is the only one that emits FeeTermsUpdated.
            if (logs[i].topics[0] == keccak256("OwnershipTransferStarted(address,address)")) {
                registry = SponsoredTaskRegistry(logs[i].emitter);
            }
            if (logs[i].topics[0] == keccak256("FeeTermsUpdated(uint16,address)")) {
                feePolicy = SponsoredTaskFeePolicy(logs[i].emitter);
            }
        }
    }

    function test_DeploySponsoredTask_AdminOwnsFeePolicyAndRegistryIsPendingToIt() public {
        (SponsoredTaskRegistry registry, SponsoredTaskFeePolicy feePolicy) = _deploy();

        assertEq(feePolicy.owner(), address(admin), "fee policy must be owned by the admin");
        assertEq(registry.owner(), deployer, "registry stays with the deployer until accepted");
        assertEq(registry.pendingOwner(), address(admin), "registry must be pending to the admin");

        admin.acceptOwnership(address(registry));
        assertEq(registry.owner(), address(admin));
    }

    function test_RevertWhen_DeploySponsoredTask_AdminIsNotAContract() public {
        // Strip the stand-in's code rather than repointing the process-global env var, which
        // would leak into other tests running alongside this one.
        vm.etch(address(admin), "");
        DeploySponsoredTask script = new DeploySponsoredTask();
        vm.expectRevert("Sponsored Task: admin must be a contract");
        script.run();
    }
}
