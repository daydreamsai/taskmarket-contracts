// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";

/// @notice Covers SponsoredTasksVaultV2's own direct-call validation branches -- `fund`'s
///         zero-amount guard, `onlyActive`'s post-exit rejection, `configureManager`/
///         `withdrawAvailable`'s zero-address guards, and `reserveTask`'s direct input
///         validation -- that the main behavioral suite in SponsoredTasksVaultV2.t.sol only
///         exercises indirectly through the hook's always-well-formed calls.
contract SponsoredTasksVaultValidationTest is Test {
    address internal controller = makeAddr("controller");
    address internal manager = makeAddr("manager");
    SponsoredTaskFeePolicy internal feePolicy;
    SponsoredTaskRegistry internal registry;
    SponsoredTaskFactoryV2 internal factory;
    SponsoredTasksVaultV2 internal vault;
    MockERC20 internal token;

    function setUp() external {
        vm.etch(controller, hex"00");
        token = new MockERC20("Project", "PROJECT", 18, address(this));
        feePolicy = new SponsoredTaskFeePolicy(address(this), 50, makeAddr("feeRecipient"));
        registry = new SponsoredTaskRegistry(address(this));
        factory = new SponsoredTaskFactoryV2(
            controller, address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(token), address(this), keccak256("validation-vault"));
        vault = SponsoredTasksVaultV2(vaultAddress);
    }

    function test_FundRejectsZeroAmount() external {
        vm.expectRevert(SponsoredTasksVaultV2.GrossAmountRequired.selector);
        vault.fund(0);
    }

    function test_FundRejectsOnceVaultHasExited() external {
        vault.emergencyExitVault(address(this));
        vm.expectRevert(SponsoredTasksVaultV2.VaultNotActive.selector);
        vault.fund(1);
    }

    function test_ConfigureManagerRejectsZeroAddress() external {
        vm.expectRevert(SponsoredTasksVaultV2.ZeroAddress.selector);
        vault.configureManager(address(0), 1, true);
    }

    function test_WithdrawAvailableRejectsZeroRecipient() external {
        vm.expectRevert(SponsoredTasksVaultV2.ZeroAddress.selector);
        vault.withdrawAvailable(address(0), 1);
    }

    function test_WithdrawAvailableRejectsAmountAboveAvailable() external {
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.InsufficientAvailable.selector, 1, 0));
        vault.withdrawAvailable(makeAddr("recipient"), 1);
    }

    function test_ReserveTaskRejectsZeroAllocationId() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVaultV2.AllocationIdRequired.selector);
        vault.reserveTask(bytes32(0), keccak256("task"), manager, 1, currentEpoch, 0, address(0), keccak256("terms"));
    }

    function test_ReserveTaskRejectsZeroManager() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVaultV2.ZeroAddress.selector);
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), address(0), 1, currentEpoch, 0, address(0), keccak256("terms")
        );
    }

    function test_ReserveTaskRejectsZeroGrossAmount() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVaultV2.GrossAmountRequired.selector);
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), manager, 0, currentEpoch, 0, address(0), keccak256("terms")
        );
    }

    function test_ReserveTaskRejectsZeroTermsHash() external {
        uint64 currentEpoch = vault.epoch();
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVaultV2.TermsHashRequired.selector);
        vault.reserveTask(keccak256("alloc"), keccak256("task"), manager, 1, currentEpoch, 0, address(0), bytes32(0));
    }

    function test_ReserveTaskRejectsMismatchedEpoch() external {
        uint64 currentEpoch = vault.epoch();
        uint64 wrongEpoch = currentEpoch + 1;
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVaultV2.AllocationEpochMismatch.selector, wrongEpoch, currentEpoch)
        );
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), manager, 1, wrongEpoch, 0, address(0), keccak256("terms")
        );
    }

    function test_ReserveTaskRejectsCallerOtherThanController() external {
        uint64 currentEpoch = vault.epoch();
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.OnlyController.selector, address(this)));
        vault.reserveTask(
            keccak256("alloc"), keccak256("task"), manager, 1, currentEpoch, 0, address(0), keccak256("terms")
        );
    }
}
