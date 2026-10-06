// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";

/// @notice Covers SponsoredTasksVault's own direct-call validation branches -- `fund`'s
///         zero-amount guard, `onlyActive`'s post-exit rejection, `configureManager`/
///         `withdrawAvailable`'s zero-address guards, and `reserveTask`'s direct input
///         validation -- that the main behavioral suite in SponsoredTasksVault.t.sol only
///         exercises indirectly through the hook's always-well-formed calls.
contract SponsoredTasksVaultValidationTest is Test {
    address internal controller = makeAddr("controller");
    address internal manager = makeAddr("manager");
    SponsoredTaskFeePolicy internal feePolicy;
    SponsoredTaskRegistry internal registry;
    SponsoredTaskFactory internal factory;
    SponsoredTasksVault internal vault;
    MockERC20 internal token;

    function setUp() external {
        vm.etch(controller, hex"00");
        token = new MockERC20("Project", "PROJECT", 18, address(this));
        feePolicy = new SponsoredTaskFeePolicy(address(this), 50, makeAddr("feeRecipient"));
        registry = new SponsoredTaskRegistry(address(this));
        factory = new SponsoredTaskFactory(controller, address(feePolicy), registry);
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(token), address(this), keccak256("validation-vault"));
        vault = SponsoredTasksVault(vaultAddress);
    }

    function test_FundRejectsZeroAmount() external {
        vm.expectRevert(SponsoredTasksVault.GrossAmountRequired.selector);
        vault.fund(0);
    }

    function test_FundRejectsOnceVaultHasExited() external {
        vault.emergencyExitVault(address(this));
        vm.expectRevert(SponsoredTasksVault.VaultNotActive.selector);
        vault.fund(1);
    }

    function test_ConfigureManagerRejectsZeroAddress() external {
        vm.expectRevert(SponsoredTasksVault.ZeroAddress.selector);
        vault.configureManager(address(0), 1, true);
    }

    function test_WithdrawAvailableRejectsZeroRecipient() external {
        vm.expectRevert(SponsoredTasksVault.ZeroAddress.selector);
        vault.withdrawAvailable(address(0), 1);
    }

    function test_WithdrawAvailableRejectsAmountAboveAvailable() external {
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.InsufficientAvailable.selector, 1, 0));
        vault.withdrawAvailable(makeAddr("recipient"), 1);
    }

    function test_ReserveTaskRejectsZeroAllocationId() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.AllocationIdRequired.selector);
        vault.reserveTask(bytes32(0), keccak256("task"), manager, 1, currentEpoch, 0, address(0), keccak256("terms"));
    }

    function test_ReserveTaskRejectsZeroManager() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.ZeroAddress.selector);
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), address(0), 1, currentEpoch, 0, address(0), keccak256("terms")
        );
    }

    function test_ReserveTaskRejectsZeroGrossAmount() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.GrossAmountRequired.selector);
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), manager, 0, currentEpoch, 0, address(0), keccak256("terms")
        );
    }

    function test_ReserveTaskRejectsZeroTermsHash() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVault.TermsHashRequired.selector);
        vault.reserveTask(keccak256("alloc"), keccak256("task"), manager, 1, currentEpoch, 0, address(0), bytes32(0));
    }

    function test_ReserveTaskRejectsMismatchedEpoch() external {
        uint64 currentEpoch = vault.epoch();
        uint64 wrongEpoch = currentEpoch + 1;
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVault.AllocationEpochMismatch.selector, wrongEpoch, currentEpoch)
        );
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), manager, 1, wrongEpoch, 0, address(0), keccak256("terms")
        );
    }

    function test_ReserveTaskRejectsCallerOtherThanController() external {
        uint64 currentEpoch = vault.epoch();
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVault.OnlyController.selector, address(this)));
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), manager, 1, currentEpoch, 0, address(0), keccak256("terms")
        );
    }
}
