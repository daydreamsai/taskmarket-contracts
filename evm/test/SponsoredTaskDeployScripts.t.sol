// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { DeploySponsoredTask } from "../script/DeploySponsoredTask.s.sol";
import { UpgradeSponsoredTask } from "../script/UpgradeSponsoredTask.s.sol";

/// @dev Code-bearing Safe/timelock stand-in that can accept two-step ownership transfers.
contract SponsoredTaskAdminStandIn {
    function acceptOwnership(address ownable) external {
        SponsoredTaskRegistry(ownable).acceptOwnership();
    }

    function call(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract SponsoredTaskDeployScriptsTest is Test {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant DEPLOYER_KEY = 0xA11CE;

    address private deployer;
    MockERC20 private usdc;
    SponsoredTaskAdminStandIn private admin;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_KEY);
        usdc = new MockERC20("Mock USDC", "USDC", 6, address(this));
        admin = new SponsoredTaskAdminStandIn();

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("FORGE_USDC_TOKEN_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(0xD1A))); // only stored by the hook
        vm.setEnv("FORGE_SPONSORED_TASK_CREATION_FEE_USDC", "1000000");
        vm.setEnv("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", "750");
        vm.setEnv("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        vm.setEnv("FORGE_SPONSORED_TASK_ADMIN", vm.toString(address(admin)));
    }

    function _deploy()
        private
        returns (SponsoredTaskHook hook, SponsoredTaskRegistry registry, SponsoredTaskFeePolicy feePolicy)
    {
        vm.recordLogs();
        new DeploySponsoredTask().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // The hook proxy is the only contract whose ERC1967 Upgraded event fires in this script.
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Upgraded(address)")) hook = SponsoredTaskHook(logs[i].emitter);
        }
        registry = SponsoredTaskRegistry(address(hook.registry()));
        feePolicy = SponsoredTaskFeePolicy(_feePolicyOf(logs, address(hook)));
    }

    /// @dev The fee policy is the only contract that emits FeeTermsUpdated in this script.
    function _feePolicyOf(Vm.Log[] memory logs, address) private pure returns (address policy) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("FeeTermsUpdated(uint16,address)")) policy = logs[i].emitter;
        }
    }

    /// @dev The factory is the only address the registry authorizes in this script.
    function _factoryOf(Vm.Log[] memory logs) private pure returns (SponsoredTaskFactoryV2 factory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == SponsoredTaskRegistry.FactoryAuthorizationUpdated.selector) {
                factory = SponsoredTaskFactoryV2(address(uint160(uint256(logs[i].topics[1]))));
            }
        }
    }

    function test_DeploySponsoredTask_AdminOwnsHookFeePolicyAndRegistry() public {
        (SponsoredTaskHook hook, SponsoredTaskRegistry registry, SponsoredTaskFeePolicy feePolicy) = _deploy();

        assertEq(hook.owner(), address(admin), "hook proxy must be owned by the admin");
        assertEq(feePolicy.owner(), address(admin), "fee policy must be owned by the admin");
        assertEq(registry.owner(), deployer, "registry stays with the deployer until accepted");
        assertEq(registry.pendingOwner(), address(admin), "registry must be pending to the admin");

        admin.acceptOwnership(address(registry));
        assertEq(registry.owner(), address(admin));
    }

    function test_DeploySponsoredTask_FactoryTakesTheConfiguredCreationFee() public {
        vm.recordLogs();
        new DeploySponsoredTask().run();
        SponsoredTaskFactoryV2 factory = _factoryOf(vm.getRecordedLogs());

        assertEq(address(factory.feeToken()), address(usdc));
        assertEq(factory.creationFee(), 1_000_000);
        assertEq(factory.creationFeeRecipient(), address(0xFEE));
    }

    function test_DeploySponsoredTask_DeployerCannotUpgradeTheHook() public {
        (SponsoredTaskHook hook,,) = _deploy();
        address impl = address(new SponsoredTaskHook(address(0xD1A), usdc, hook.registry()));
        vm.prank(deployer);
        vm.expectRevert();
        hook.upgradeToAndCall(impl, "");
    }

    function test_RevertWhen_DeploySponsoredTask_AdminIsNotAContract() public {
        // Strip the stand-in's code rather than repointing the process-global env var, which
        // would leak into other tests running alongside this one.
        vm.etch(address(admin), "");
        DeploySponsoredTask script = new DeploySponsoredTask();
        vm.expectRevert("Sponsored Task: admin must be a contract");
        script.run();
    }

    function test_UpgradeSponsoredTask_PreparesSafeCalldataWhenKeyIsNotOwner() public {
        (SponsoredTaskHook hook,,) = _deploy();
        address before = address(uint160(uint256(vm.load(address(hook), ERC1967_IMPLEMENTATION_SLOT))));
        vm.setEnv("FORGE_SPONSORED_TASK_HOOK_ADDRESS", vm.toString(address(hook)));

        UpgradeSponsoredTask script = new UpgradeSponsoredTask();
        vm.recordLogs();
        script.run();
        assertEq(
            address(uint160(uint256(vm.load(address(hook), ERC1967_IMPLEMENTATION_SLOT)))),
            before,
            "the deployer key must not upgrade a hook it does not own"
        );

        // The owner executes the printed call.
        address impl = address(new SponsoredTaskHook(address(0xD1A), usdc, hook.registry()));
        admin.call(address(hook), script.upgradeCalldata(impl));
        assertEq(address(uint160(uint256(vm.load(address(hook), ERC1967_IMPLEMENTATION_SLOT)))), impl);
    }
}
