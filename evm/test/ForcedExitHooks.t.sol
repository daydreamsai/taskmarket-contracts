// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { TMP_CLAIM, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev A hook may veto voluntary actions but never a forced exit. Each test creates a task with
///      a cooperative hook, progresses it normally, then turns the hook hostile (every check*
///      reverts, every on* reverts) and proves the forced exit still settles funds and status.
contract ForcedExitHooksTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    MockTaskHook internal hook;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant FEE_BPS = 500;
    uint32 internal constant EVAL_WINDOW = 2 days;
    uint32 internal constant APPEAL_WINDOW = 1 days;
    bytes32 internal constant WORK = keccak256("work");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, uint16(FEE_BPS));
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 1_000_000e6);
        hook = new MockTaskHook();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(bytes4 mode) internal returns (bytes32) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, mode),
                        ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _claim(bytes32 taskId, uint256 stake) internal {
        _relay(worker, stake, abi.encodeCall(market.claimTask, (taskId, stake)));
    }

    function _submit(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    /// @dev Claim task with an evaluator, claimed and delivered: status Review.
    function _evalTaskInReview() internal returns (bytes32 taskId) {
        taskId = _create(TMP_CLAIM);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, EVAL_WINDOW, APPEAL_WINDOW, address(0)))
        );
        _claim(taskId, 0);
        _submit(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Review), "review");
    }

    /// @dev Evaluator task with an APPROVE verdict for the full reward: status Appealing.
    function _evalTaskApproved() internal returns (bytes32 taskId) {
        taskId = _evalTaskInReview();
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.APPROVE, 950, 1000, bytes32(0), awards))
        );
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing), "appealing");
    }

    /// @dev Every check* reverts and every on* reverts from here on.
    function _makeHostile() internal {
        hook.setRevertOnCheckFund(true);
        hook.setRevertOnCheckClaim(true);
        hook.setRevertOnCheckSelectWorker(true);
        hook.setRevertOnCheckSubmit(true);
        hook.setRevertOnCheckEvaluate(true);
        hook.setRevertOnCheckComplete(true);
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(ITMPHook.onComplete.selector), "x");
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(ITMPHook.onForfeit.selector), "x");
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(ITMPHook.onCancel.selector), "x");
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(ITMPHook.onExpire.selector), "x");
    }

    function _expectHookFailed() internal {
        vm.expectEmit(true, true, true, true, address(market));
        emit ITMPCore.HookCallFailed(address(hook));
    }

    function _bal(address a) internal view returns (uint256) {
        return usdc.balanceOf(a);
    }

    /// @dev Funds never leave the four parties a single-task test touches.
    function _assertConserved(uint256 total) internal view {
        assertEq(
            _bal(address(market)) + _bal(requester) + _bal(worker) + _bal(feeRecipient) + _bal(evaluator),
            total,
            "funds conserved"
        );
    }

    function _workerNet() internal pure returns (uint256) {
        return REWARD - (REWARD * FEE_BPS) / 10000;
    }

    // -------------------------------------------------------------------------
    // Forced exits survive a hostile hook
    // -------------------------------------------------------------------------

    function test_RefundExpired_UndeliveredClaim_HostileHook() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, 0);
        _makeHostile();
        vm.warp(market.getTask(taskId).expiryTime + 1);

        _expectHookFailed();
        market.refundExpired{ gas: 10_000_000 }(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired), "expired");
        assertEq(_bal(requester), REWARD, "requester refunded");
        assertEq(_bal(address(market)), 0, "escrow empty");
    }

    function test_RefundExpired_BountyNoSubmissions_HostileHook() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        _makeHostile();
        vm.warp(market.getTask(taskId).expiryTime + 1);

        _expectHookFailed();
        market.refundExpired{ gas: 10_000_000 }(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired), "expired");
        assertEq(_bal(requester), REWARD, "requester refunded");
        assertEq(_bal(address(market)), 0, "escrow empty");
    }

    function test_SettleLapsedReview_HostileHook() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, 0);
        _submit(taskId);
        _makeHostile();
        uint256 checksBefore = hook.checkCompleteCalls();
        vm.warp(market.reviewDeadline(taskId) + 1);

        _expectHookFailed();
        market.settleLapsedReview{ gas: 10_000_000 }(taskId);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "accepted");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        assertEq(hook.checkCompleteCalls(), checksBefore, "no check hook consulted");
        _assertConserved(REWARD);
    }

    function test_ForfeitAndReopen_HostileHook() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, STAKE);
        _makeHostile();
        vm.warp(market.getTask(taskId).expiryTime + 1);

        _expectHookFailed();
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open), "reopened");
        assertEq(task.worker, address(0), "worker cleared");
        assertEq(task.stakeAmount, 0, "stake cleared");
        assertEq(_bal(worker), 0, "stake forfeited");
        _assertConserved(REWARD + STAKE);
    }

    function test_ReleaseClaim_HostileHook() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, STAKE);
        _makeHostile();

        _expectHookFailed();
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open), "reopened");
        assertEq(task.worker, address(0), "worker cleared");
        // Released inside the grace period: the whole stake comes back.
        assertEq(_bal(worker), STAKE, "stake returned");
        _assertConserved(REWARD + STAKE);
    }

    function test_RejectDelivery_HostileHook() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, 0);
        _submit(taskId);
        _makeHostile();
        assertLe(vm.getBlockTimestamp(), market.reviewDeadline(taskId), "inside window");

        _expectHookFailed();
        _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertTrue(
            task.status == ITMPCore.TaskStatus.Open || task.status == ITMPCore.TaskStatus.Expired, "reopened or ended"
        );
        assertEq(task.worker, address(0), "worker cleared");
        assertEq(task.deliverable, bytes32(0), "deliverable cleared");
        assertEq(market.reviewDeadline(taskId), 0, "review cleared");
        _assertConserved(REWARD);
    }

    function test_EvaluatorTimeout_HostileHook() public {
        bytes32 taskId = _evalTaskInReview();
        _makeHostile();
        vm.warp(vm.getBlockTimestamp() + EVAL_WINDOW + 1);

        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Claimed), "back under review");
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, address(0), "evaluator cleared");
        assertEq(_bal(address(market)), REWARD, "escrow intact");
    }

    function test_RefundExpired_AppealingPastExpiry_HostileHook() public {
        bytes32 taskId = _evalTaskApproved();
        _makeHostile();
        vm.warp(market.getTask(taskId).expiryTime + 1);

        market.refundExpired{ gas: 10_000_000 }(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        assertEq(_bal(requester), 0, "no refund over a verdict");
        _assertConserved(REWARD);
    }

    function test_FinalizeVerdict_PastExpiry_HostileHook() public {
        bytes32 taskId = _evalTaskApproved();
        _makeHostile();
        vm.warp(market.getTask(taskId).expiryTime + 1);

        market.finalizeVerdict{ gas: 10_000_000 }(taskId);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        _assertConserved(REWARD);
    }

    // -------------------------------------------------------------------------
    // Control: gates still apply to non-forced paths
    // -------------------------------------------------------------------------

    function test_FinalizeVerdict_BeforeExpiry_HostileHookBlocks() public {
        bytes32 taskId = _evalTaskApproved();
        _makeHostile();
        vm.warp(vm.getBlockTimestamp() + APPEAL_WINDOW + 1);
        assertLe(vm.getBlockTimestamp(), market.getTask(taskId).expiryTime, "before expiry");

        vm.expectRevert(ITMPCore.HookCheckCompleteRejected.selector);
        market.finalizeVerdict{ gas: 10_000_000 }(taskId);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing), "still appealing");
    }
}
