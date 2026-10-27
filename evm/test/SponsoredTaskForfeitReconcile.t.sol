// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";
import { MockTaskmarketForSponsoredTask } from "./SponsoredTaskHook.t.sol";

/// @notice FR-7 lifecycle coverage kept separate from the broad hook behavior suite.
contract SponsoredTaskForfeitReconcileTest is Test {
    // taskAllocationSettlement returns a tuple, not the TaskAllocation struct -- the whole-struct
    // external getter tripped forge coverage --ir-minimum's stack-too-deep limit on its own ABI
    // encoding (see SponsoredTaskHook.taskAllocationSettlement's own doc comment).
    function _allocationStatus(SponsoredTaskHook h, bytes32 taskId)
        private
        view
        returns (SponsoredTaskHook.HookStatus status)
    {
        (,,,,,,,, status) = h.taskAllocationSettlement(taskId);
    }

    function _vaultAllocationStatus(SponsoredTasksVault v, bytes32 allocationId)
        private
        view
        returns (SponsoredTaskTypes.AllocationStatus status)
    {
        (,,,,,,, status) = v.allocationSettlement(allocationId);
    }

    bytes32 private constant TASK_ID = keccak256("forfeit-reconcile-task");
    uint256 private constant GROSS = 10_000;
    uint256 private constant NATIVE_REWARD = 1_000_000;
    uint16 private constant TOKEN_FEE_BPS = 50;

    address private constant MANAGER = address(0xCAFE);
    address private constant WORKER = address(0xA11CE);
    address private constant TOKEN_FEE_RECIPIENT = address(0xFEE1);
    address private constant CREATION_FEE_RECIPIENT = address(0xFEE2);

    MockTaskmarketForSponsoredTask private market;
    MockERC20 private usdc;
    MockERC20 private projectToken;
    SponsoredTaskHook private hook;
    SponsoredTasksVault private vault;

    function setUp() external {
        market = new MockTaskmarketForSponsoredTask();
        usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));

        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(this), TOKEN_FEE_BPS, TOKEN_FEE_RECIPIENT);
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));
        hook = new SponsoredTaskHook(address(market), IERC20(address(usdc)), registry);

        SponsoredTaskFactory factory = new SponsoredTaskFactory(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(projectToken), address(this), keccak256("forfeit-vault"));
        vault = SponsoredTasksVault(vaultAddress);
        vault.configureManager(MANAGER, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);

        usdc.mint(MANAGER, 10_000_000);

        market.primeTask(TASK_ID, MANAGER, address(usdc), NATIVE_REWARD, TMP_CLAIM, address(hook));
    }

    function testRepeatedForfeitCallbacksLeaveReservationAndCapacityUntouched() external {
        _fund();
        _assertReservedAccounting();

        // V20's forfeit-and-reopen is nonterminal; callbacks may be repeated or absent.
        market.callOnForfeit(hook, TASK_ID, WORKER);
        market.callOnForfeit(hook, TASK_ID, WORKER);

        _assertReservedAccounting();
        assertEq(usdc.balanceOf(CREATION_FEE_RECIPIENT), 0, "a task, forfeited or not, never pays a creation fee");
    }

    function testSwallowedForfeitThenCancellationReleasesExactlyOnceAcrossReconcileAndDuplicateCallback() external {
        _fund();
        // Simulate a swallowed onForfeit: no callback is made before the task later reaches Cancelled.
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Cancelled);

        assertEq(uint8(hook.reconcile(TASK_ID)), uint8(SponsoredTaskHook.HookStatus.Released));
        _assertReleasedAccounting();

        // A duplicate late callback and a repeated permissionless reconcile are both inert.
        market.callOnCancel(hook, TASK_ID);
        assertEq(uint8(hook.reconcile(TASK_ID)), uint8(SponsoredTaskHook.HookStatus.Released));
        _assertReleasedAccounting();
    }

    function testRepeatedForfeitThenSwallowedExpiryReleasesExactlyOnce() external {
        _fund();
        market.callOnForfeit(hook, TASK_ID, WORKER);
        market.callOnForfeit(hook, TASK_ID, WORKER);
        market.setStatus(TASK_ID, ITMPCore.TaskStatus.Expired);

        assertEq(uint8(hook.reconcile(TASK_ID)), uint8(SponsoredTaskHook.HookStatus.Released));
        _assertReleasedAccounting();
        assertEq(uint8(hook.reconcile(TASK_ID)), uint8(SponsoredTaskHook.HookStatus.Released));
        _assertReleasedAccounting();
    }

    function _fund() private {
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: vault.epoch(),
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: hook.currentTaskTermsHash(TASK_ID)
        });
        market.callCheckFund(hook, TASK_ID, hook.encodeHookData(request));
    }

    function _assertReservedAccounting() private view {
        SponsoredTaskTypes.AllocationStatus allocationStatus = _vaultAllocationStatus(vault, TASK_ID);
        SponsoredTaskTypes.ManagerAccount memory manager = vault.managerAccount(MANAGER);
        assertEq(uint8(allocationStatus), uint8(SponsoredTaskTypes.AllocationStatus.Reserved));
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHook.HookStatus.Reserved));
        assertEq(vault.available(), GROSS * 99);
        assertEq(vault.totalReserved(), GROSS);
        assertEq(manager.reserved, GROSS);
        assertEq(manager.spent, 0);
    }

    function _assertReleasedAccounting() private view {
        SponsoredTaskTypes.AllocationStatus allocationStatus = _vaultAllocationStatus(vault, TASK_ID);
        SponsoredTaskTypes.ManagerAccount memory manager = vault.managerAccount(MANAGER);
        assertEq(uint8(allocationStatus), uint8(SponsoredTaskTypes.AllocationStatus.Released));
        assertEq(uint8(_allocationStatus(hook, TASK_ID)), uint8(SponsoredTaskHook.HookStatus.Released));
        assertEq(vault.available(), GROSS * 100);
        assertEq(vault.totalReserved(), 0);
        assertEq(manager.reserved, 0);
        assertEq(manager.spent, 0);
    }
}
