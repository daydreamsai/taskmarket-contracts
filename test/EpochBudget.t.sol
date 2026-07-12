// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";

/// @dev Unit tests for EpochBudget, exercising every cap, guard, and epoch-rollover branch.
contract EpochBudgetTest is Test {
    EpochBudget budget;

    address constant OWNER = address(0xA0);
    address constant HOOK = address(0xB0);
    address constant WORKER = address(0xC0);
    address constant REQUESTER = address(0xD0);
    address constant STRANGER = address(0xE0);

    uint256 constant EPOCH = 7 days;
    uint256 constant GLOBAL_CAP = 1000e18;
    uint256 constant WORKER_CAP = 400e18;
    uint256 constant REQUESTER_CAP = 600e18;
    uint256 constant MAX_PER_TASK = 300e18;

    function setUp() public {
        budget = new EpochBudget(EPOCH, GLOBAL_CAP, WORKER_CAP, REQUESTER_CAP, MAX_PER_TASK, OWNER);
        vm.prank(OWNER);
        budget.setHook(HOOK);
    }

    function test_setHook_onlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        budget.setHook(STRANGER);
    }

    function test_checkAndConsume_onlyHook() public {
        vm.prank(STRANGER);
        vm.expectRevert(EpochBudget.OnlyHook.selector);
        budget.checkAndConsume(REQUESTER, WORKER, 1e18);
    }

    function test_checkAndConsume_taskCapExceeded() public {
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(EpochBudget.TaskCapExceeded.selector, MAX_PER_TASK + 1, MAX_PER_TASK));
        budget.checkAndConsume(REQUESTER, WORKER, MAX_PER_TASK + 1);
    }

    function test_checkAndConsume_workerCapExceeded() public {
        // Two consumes of 300 by the same worker (different requesters) => worker hits 400 cap on 2nd.
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 300e18);
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(EpochBudget.WorkerCapExceeded.selector, WORKER, 300e18, 100e18));
        budget.checkAndConsume(address(0xD1), WORKER, 300e18);
    }

    function test_checkAndConsume_requesterCapExceeded() public {
        // Same requester, different workers: requester cap 600 hit on 3rd consume of 300.
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, address(0xC1), 300e18);
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, address(0xC2), 300e18);
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(EpochBudget.RequesterCapExceeded.selector, REQUESTER, 300e18, 0));
        budget.checkAndConsume(REQUESTER, address(0xC3), 300e18);
    }

    function test_checkAndConsume_globalCapExceeded() public {
        // Raise per-actor caps so the global cap is the binding constraint.
        vm.startPrank(OWNER);
        budget.setWorkerCapUsd(5000e18);
        budget.setRequesterCapUsd(5000e18);
        budget.setMaxUsdPerTask(5000e18);
        vm.stopPrank();

        vm.prank(HOOK);
        budget.checkAndConsume(address(0xD1), address(0xC1), 600e18);
        vm.prank(HOOK);
        vm.expectRevert(abi.encodeWithSelector(EpochBudget.GlobalCapExceeded.selector, 600e18, 400e18));
        budget.checkAndConsume(address(0xD2), address(0xC2), 600e18);
    }

    function test_consume_updatesViews() public {
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 200e18);
        assertEq(budget.globalUsed(), 200e18);
        assertEq(budget.workerUsed(WORKER), 200e18);
        assertEq(budget.requesterUsed(REQUESTER), 200e18);
        // remaining is bounded by maxTokensPerTask (300)
        assertEq(budget.remaining(REQUESTER, WORKER), 200e18);
    }

    function test_epochRollover_resetsUsageInViews() public {
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 200e18);
        assertEq(budget.workerUsed(WORKER), 200e18);

        // Warp past the epoch boundary; views should treat stored usage as zero.
        vm.warp(block.timestamp + EPOCH + 1);
        assertEq(budget.globalUsed(), 0);
        assertEq(budget.workerUsed(WORKER), 0);
        assertEq(budget.requesterUsed(REQUESTER), 0);
    }

    function test_consumeAfterRollover_advancesEpoch() public {
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 200e18);
        uint64 e0 = budget.currentEpoch();

        vm.warp(block.timestamp + EPOCH + 1);
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 100e18);
        assertGt(budget.currentEpoch(), e0);
        // worker usage is 100 in the new epoch, not 300
        assertEq(budget.workerUsed(WORKER), 100e18);
    }

    function test_release_onlyHook() public {
        vm.prank(STRANGER);
        vm.expectRevert(EpochBudget.OnlyHook.selector);
        budget.release(REQUESTER, WORKER, 1e18);
    }

    function test_release_reversesUsage() public {
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 200e18);
        vm.prank(HOOK);
        budget.release(REQUESTER, WORKER, 50e18);
        assertEq(budget.workerUsed(WORKER), 150e18);
        assertEq(budget.globalUsed(), 150e18);
        assertEq(budget.requesterUsed(REQUESTER), 150e18);
    }

    function test_release_noOpWhenAmountExceedsUsage() public {
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 100e18);
        // Releasing more than used is a no-op for each tracked actor (branch: used < amount).
        vm.prank(HOOK);
        budget.release(REQUESTER, WORKER, 500e18);
        assertEq(budget.workerUsed(WORKER), 100e18);
    }

    function test_release_afterRolloverIsNoOp() public {
        vm.prank(HOOK);
        budget.checkAndConsume(REQUESTER, WORKER, 200e18);
        vm.warp(block.timestamp + EPOCH + 1);
        // Usage already zero in the new epoch; release should leave it at zero.
        vm.prank(HOOK);
        budget.release(REQUESTER, WORKER, 200e18);
        assertEq(budget.workerUsed(WORKER), 0);
    }

    function test_ownerSetters() public {
        vm.startPrank(OWNER);
        budget.setGlobalCapUsd(1);
        budget.setWorkerCapUsd(2);
        budget.setRequesterCapUsd(3);
        budget.setMaxUsdPerTask(4);
        budget.setEpochDuration(5);
        vm.stopPrank();
        assertEq(budget.globalCapUsd(), 1);
        assertEq(budget.workerCapUsd(), 2);
        assertEq(budget.requesterCapUsd(), 3);
        assertEq(budget.maxUsdPerTask(), 4);
        assertEq(budget.epochDuration(), 5);
    }

    function test_setters_onlyOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert();
        budget.setGlobalCapUsd(1);
    }

    function test_setMaxUsdPerTask_overflowReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        budget.setMaxUsdPerTask(uint256(type(uint192).max) + 1);
    }

    function test_constructor_zeroDuration_reverts() public {
        vm.expectRevert(EpochBudget.EpochDurationZero.selector);
        new EpochBudget(0, GLOBAL_CAP, WORKER_CAP, REQUESTER_CAP, MAX_PER_TASK, OWNER);
    }

    function test_constructor_globalCapOverflow_reverts() public {
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        new EpochBudget(EPOCH, uint256(type(uint192).max) + 1, WORKER_CAP, REQUESTER_CAP, MAX_PER_TASK, OWNER);
    }

    function test_constructor_workerCapOverflow_reverts() public {
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        new EpochBudget(EPOCH, GLOBAL_CAP, uint256(type(uint192).max) + 1, REQUESTER_CAP, MAX_PER_TASK, OWNER);
    }

    function test_constructor_requesterCapOverflow_reverts() public {
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        new EpochBudget(EPOCH, GLOBAL_CAP, WORKER_CAP, uint256(type(uint192).max) + 1, MAX_PER_TASK, OWNER);
    }

    function test_constructor_maxUsdPerTaskOverflow_reverts() public {
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        new EpochBudget(EPOCH, GLOBAL_CAP, WORKER_CAP, REQUESTER_CAP, uint256(type(uint192).max) + 1, OWNER);
    }
}
