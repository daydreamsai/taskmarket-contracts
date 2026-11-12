// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { TMP_CLAIM, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev030 retired V1 hook dispatch. A task created before the rev028 cut keeps dispatch version 0
///      and its V1 hook list in storage, and the diamond now treats it as a task with no hooks. Every
///      test makes a task look like that (makeLegacyV1Task writes the dormant data directly, since no
///      code path can attach a V1 hook any more), makes its V1 hook hostile (every check* and every on*
///      reverts) and proves the task still creates, progresses, settles, cancels, expires, releases and
///      times out normally, with the hook never called.
contract Rev030V1RetiredTest is DiamondTestHelper {
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

    /// @dev A task as a rev027 diamond would have left it: no V2 attachments, dispatch version 0 and the
    ///      V1 hook in its list. The hook is made hostile.
    function _create(bytes4 mode) internal returns (bytes32 taskId) {
        taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, mode),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
        address[] memory legacy = new address[](1);
        legacy[0] = address(hook);
        makeLegacyV1Task(address(market), taskId, legacy);
        assertEq(ITMPHooksV2(address(market)).getTaskHookVersion(taskId), 0, "created before the cut");
        assertEq(market.getTaskHooks(taskId).length, 0, "no hooks to dispatch");
        _makeHostile();
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

    /// @dev Every check* and every on* reverts. The hook's call counters then prove it was never called.
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

    /// @dev No V1 callback ran and none was reported as failed.
    function _assertNeverCalled() internal view {
        assertEq(hook.checkFundCalls(), 0, "checkFund");
        assertEq(hook.checkClaimCalls(), 0, "checkClaim");
        assertEq(hook.checkSelectWorkerCalls(), 0, "checkSelectWorker");
        assertEq(hook.checkSubmitCalls(), 0, "checkSubmit");
        assertEq(hook.checkEvaluateCalls(), 0, "checkEvaluate");
        assertEq(hook.checkCompleteCalls(), 0, "checkComplete");
        assertEq(hook.onCompleteCalls(), 0, "onComplete");
        assertEq(hook.onForfeitCalls(), 0, "onForfeit");
        assertEq(hook.onCancelCalls(), 0, "onCancel");
        assertEq(hook.onExpireCalls(), 0, "onExpire");
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
    // The task is a task with no hooks
    // -------------------------------------------------------------------------

    function test_LegacyTaskReadsAsHookless() public {
        bytes32 taskId = _create(TMP_CLAIM);
        assertEq(ITMPHooksV2(address(market)).getTaskHooksV2(taskId).length, 0, "no V2 attachments");
        _assertNeverCalled();
    }

    // -------------------------------------------------------------------------
    // Voluntary actions are not vetoed by the V1 hook
    // -------------------------------------------------------------------------

    function test_ClaimSubmitAccept_SettleWithoutTheHook() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, 0);
        _submit(taskId);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "accepted");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        _assertConserved(REWARD);
        _assertNeverCalled();
        assertTrue(ITMPHooksV2(address(market)).getTaskSettlement(taskId).recorded, "settlement record written");
    }

    function test_BountyAcceptSubmissions_SettleWithoutTheHook() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        _submit(taskId);
        address[] memory workers = new address[](1);
        workers[0] = worker;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10_000;
        _relay(requester, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0)));

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "accepted");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        _assertConserved(REWARD);
        _assertNeverCalled();
    }

    function test_CancelTask_CancelsWithoutTheHook() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Cancelled), "cancelled");
        assertEq(_bal(requester), REWARD, "refunded");
        _assertConserved(REWARD);
        _assertNeverCalled();
        assertTrue(ITMPHooksV2(address(market)).getTaskSettlement(taskId).recorded, "settlement record written");
    }

    function test_Evaluate_IsNotVetoed() public {
        bytes32 taskId = _evalTaskApproved();
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing), "evaluated");
        _assertNeverCalled();
    }

    // -------------------------------------------------------------------------
    // Forced exits and every other terminal path
    // -------------------------------------------------------------------------

    function test_RefundExpired_UndeliveredClaim() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, 0);
        vm.warp(market.getTask(taskId).expiryTime + 1);

        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired), "expired");
        assertEq(_bal(requester), REWARD, "requester refunded");
        assertEq(_bal(address(market)), 0, "escrow empty");
        _assertNeverCalled();
        assertTrue(ITMPHooksV2(address(market)).getTaskSettlement(taskId).recorded, "settlement record written");
    }

    function test_RefundExpired_BountyNoSubmissions() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        vm.warp(market.getTask(taskId).expiryTime + 1);

        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired), "expired");
        assertEq(_bal(requester), REWARD, "requester refunded");
        _assertNeverCalled();
    }

    function test_SettleLapsedReview() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, 0);
        _submit(taskId);
        vm.warp(market.reviewDeadline(taskId) + 1);

        market.settleLapsedReview(taskId);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "accepted");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        _assertConserved(REWARD);
        _assertNeverCalled();
    }

    function test_ForfeitAndReopen() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, STAKE);
        vm.warp(market.getTask(taskId).expiryTime + 1);

        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open), "reopened");
        assertEq(task.worker, address(0), "worker cleared");
        assertEq(_bal(worker), 0, "stake forfeited");
        _assertConserved(REWARD + STAKE);
        _assertNeverCalled();
    }

    function test_ReleaseClaim() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, STAKE);

        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open), "reopened");
        assertEq(task.worker, address(0), "worker cleared");
        // Released inside the grace period: the whole stake comes back.
        assertEq(_bal(worker), STAKE, "stake returned");
        _assertConserved(REWARD + STAKE);
        _assertNeverCalled();
    }

    function test_RejectDelivery() public {
        bytes32 taskId = _create(TMP_CLAIM);
        _claim(taskId, 0);
        _submit(taskId);

        _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertTrue(
            task.status == ITMPCore.TaskStatus.Open || task.status == ITMPCore.TaskStatus.Expired, "reopened or ended"
        );
        assertEq(task.worker, address(0), "worker cleared");
        _assertConserved(REWARD);
        _assertNeverCalled();
    }

    function test_EvaluatorTimeout() public {
        bytes32 taskId = _evalTaskInReview();
        vm.warp(vm.getBlockTimestamp() + EVAL_WINDOW + 1);

        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Claimed), "back under review");
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, address(0), "evaluator cleared");
        assertEq(_bal(address(market)), REWARD, "escrow intact");
        _assertNeverCalled();
    }

    function test_RefundExpired_AppealingPastExpiry() public {
        bytes32 taskId = _evalTaskApproved();
        vm.warp(market.getTask(taskId).expiryTime + 1);

        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        assertEq(_bal(requester), 0, "no refund over a verdict");
        _assertConserved(REWARD);
        _assertNeverCalled();
    }

    function test_FinalizeVerdict_PastExpiry() public {
        bytes32 taskId = _evalTaskApproved();
        vm.warp(market.getTask(taskId).expiryTime + 1);

        market.finalizeVerdict(taskId);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        _assertConserved(REWARD);
        _assertNeverCalled();
    }

    /// @dev Before rev030 a reverting V1 checkComplete blocked this finalize until the task expired.
    function test_FinalizeVerdict_BeforeExpiry_SettlesWithoutTheHook() public {
        bytes32 taskId = _evalTaskApproved();
        vm.warp(vm.getBlockTimestamp() + APPEAL_WINDOW + 1);
        assertLe(vm.getBlockTimestamp(), market.getTask(taskId).expiryTime, "before expiry");

        market.finalizeVerdict(taskId);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "settled");
        assertEq(_bal(worker), _workerNet(), "worker paid");
        _assertConserved(REWARD);
        _assertNeverCalled();
    }

    // -------------------------------------------------------------------------
    // Routing
    // -------------------------------------------------------------------------

    function test_RetiredSelectorsAreNotRouted() public view {
        bytes4[] memory removed = FacetSelectors.selectorsRemovedRev030();
        for (uint256 i; i < removed.length; ++i) {
            assertEq(IDiamondLoupe(address(market)).facetAddress(removed[i]), address(0), "selector routed");
        }
    }
}
