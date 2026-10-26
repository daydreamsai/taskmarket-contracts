// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskSettler } from "../src/hooks/sponsored-task/SponsoredTaskSettler.sol";
import { RemoteSponsoredTaskHook } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHook.sol";
import { DeploySponsoredTaskSettler } from "../script/DeploySponsoredTaskSettler.s.sol";
import { DeployRemoteSponsoredTaskHook } from "../script/DeployRemoteSponsoredTaskHook.s.sol";

contract SettlerAdminStandIn { }

contract SponsoredTaskSettlerDeployScriptsTest is Test {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;
    address private admin;

    function setUp() public {
        admin = address(new SettlerAdminStandIn());
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_ADMIN", vm.toString(admin));
        vm.setEnv("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN", vm.toString(admin));
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", "750");
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(0xD1A)));
    }

    function test_DeploySettler_AdminOwnsSettlerAndFactoryIsControlledBySettler() public {
        vm.setEnv(
            "FORGE_SPONSORED_TASK_SETTLER_ADDRESSES",
            string.concat(
                vm.toString(address(0xBBB)), ",", vm.toString(address(0xAAA)), ",", vm.toString(address(0xCCC))
            )
        );
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_THRESHOLD", "2");
        vm.recordLogs();
        new DeploySponsoredTaskSettler().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        SponsoredTaskSettler settler;
        SponsoredTaskFactory factory;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SponsoredTaskSettler.SettlersChanged.selector) {
                settler = SponsoredTaskSettler(logs[i].emitter);
            }
            if (logs[i].topics[0] == SponsoredTaskRegistry.FactoryAuthorizationUpdated.selector) {
                factory = SponsoredTaskFactory(address(uint160(uint256(logs[i].topics[1]))));
            }
        }
        assertEq(settler.owner(), admin);
        assertEq(settler.threshold(), 2);
        address[] memory list = settler.settlers();
        assertEq(list.length, 3);
        assertEq(list[0], address(0xAAA));
        assertEq(list[2], address(0xCCC));
        assertEq(factory.controller(), address(settler));
        assertEq(SponsoredTaskRegistry(address(factory.registry())).pendingOwner(), admin);
    }

    function test_DeploySettler_RejectsDeployerAsAdmin() public {
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_ADDRESSES", vm.toString(address(0xAAA)));
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_THRESHOLD", "1");
        vm.setEnv("FORGE_SPONSORED_TASK_SETTLER_ADMIN", vm.toString(vm.addr(DEPLOYER_KEY)));
        DeploySponsoredTaskSettler script = new DeploySponsoredTaskSettler();
        vm.expectRevert(bytes("Settler: admin must be a contract"));
        script.run();
    }

    function test_DeployRemoteHook_AdminOwnsProxy() public {
        vm.recordLogs();
        new DeployRemoteSponsoredTaskHook().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        RemoteSponsoredTaskHook hook;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Upgraded(address)")) hook = RemoteSponsoredTaskHook(logs[i].emitter);
        }
        assertEq(hook.owner(), admin);
        assertEq(hook.diamond(), address(0xD1A));
    }
}
