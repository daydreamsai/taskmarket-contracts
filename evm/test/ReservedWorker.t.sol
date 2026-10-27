// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPEvaluator } from "../src/interfaces/ITMPEvaluator.sol";
import { ITMPFeedback } from "../src/interfaces/ITMPFeedback.sol";
import { ITMPReservation } from "../src/interfaces/ITMPReservation.sol";
import { ITMPTerms, ITMPTermsV1 } from "../src/interfaces/ITMPTerms.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { MockReputationRegistry } from "./mocks/MockReputationRegistry.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev027: a Claim task with a reserved worker. Each claim path is exercised with a reserved
///      worker and, where the outcome differs, without one.
contract ReservedWorkerTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    MockReputationRegistry internal registry;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal stranger = address(0xC1);
    address internal evaluator = address(0xE0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant DELIVERY = 7 days;
    uint256 internal constant WINDOW = 72 hours;
    uint256 internal constant WORKER_AGENT = 42;
    bytes32 internal constant WORK = keccak256("work");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        registry = new MockReputationRegistry();
        market.setReputationRegistry(address(registry));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _terms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 2;
    }

    function _stakeTerms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 2;
        t.stakeRequired = true;
        t.stakeBps = 1000;
    }

    function _createCall(
        bytes4 mode,
        uint256 duration,
        address[] memory hooks,
        ITMPCore.TaskEvaluatorConfig memory evalCfg,
        ITMPCore.TaskTerms memory t,
        address reserved
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ITMPReservation.createTask,
            (
                taskConfig(REWARD, duration, mode, duration, duration, bytes4(0)),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                evalCfg,
                t,
                reserved
            )
        );
    }

    function _create(ITMPCore.TaskTerms memory t, address reserved) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester, REWARD, _createCall(TMP_CLAIM, DELIVERY, new address[](0), noEvaluatorConfig(), t, reserved)
            ),
            (bytes32)
        );
    }

    function _reserved() internal returns (bytes32) {
        return _create(_terms(), worker);
    }

    function _withHook(MockTaskHook hook, address reserved) internal returns (bytes32) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        return abi.decode(
            _relay(requester, REWARD, _createCall(TMP_CLAIM, DELIVERY, hooks, noEvaluatorConfig(), _terms(), reserved)),
            (bytes32)
        );
    }

    function _claim(bytes32 taskId, address w, uint256 stake) internal {
        _relay(w, stake, abi.encodeCall(market.claimTask, (taskId, stake)));
    }

    function _deliver(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    function _status(bytes32 taskId) internal view returns (ITMPCore.TaskStatus) {
        return market.getTask(taskId).status;
    }

    function _bindWorkerAgent() internal {
        // A decline binds the worker's agent ID; reservation feedback goes to it.
        bytes32 first = _reserved();
        _relay(worker, 0, abi.encodeCall(market.declineReservation, (first, WORKER_AGENT)));
    }

    function _assertSettled() internal view {
        assertEq(market.totalLiabilities(), 0, "every liability released");
        assertEq(usdc.balanceOf(address(market)), 0, "escrow empty");
    }

    // -------------------------------------------------------------------------
    // Create
    // -------------------------------------------------------------------------

    function test_Create_RecordsReservedWorkerAndDefaultWindow() public {
        uint256 start = block.timestamp;
        bytes32 expectedId =
            keccak256(abi.encode(block.chainid, address(market), requester, market.requesterNonce(requester)));
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.TaskReserved(expectedId, worker, start + WINDOW);
        bytes32 taskId = _reserved();

        (address w, uint256 acceptBy) = market.getReservation(taskId);
        assertEq(w, worker, "reserved worker");
        assertEq(acceptBy, start + WINDOW, "default accept window is 72 hours");
        ITMPCore.Task memory t = market.getTask(taskId);
        assertEq(t.mode, TMP_CLAIM, "a claim task");
        assertEq(uint8(t.status), uint8(ITMPCore.TaskStatus.Open), "open");
        assertEq(t.expiryTime, start + DELIVERY, "expiry as for any task");
        ITMPCore.TaskTerms memory terms = market.getTaskTerms(taskId);
        assertEq(terms.version, 2, "terms version 2");
        assertEq(terms.acceptWindowSecs, 0, "0 stored, read as the default");
    }

    function test_Create_WithoutReservedWorker() public {
        bytes32 taskId = _create(_terms(), address(0));
        (address w, uint256 acceptBy) = market.getReservation(taskId);
        assertEq(w, address(0), "no reserved worker");
        assertEq(acceptBy, 0, "no accept-by time");
        assertEq(market.getTaskTerms(taskId).version, 2, "terms version 2");
    }

    function test_Create_WindowBounds() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.acceptWindowSecs = uint32(1 hours);
        (, uint256 acceptBy) = market.getReservation(_create(t, worker));
        assertEq(acceptBy, block.timestamp + 1 hours, "1 hour is the minimum");

        t.acceptWindowSecs = uint32(30 days);
        bytes memory data = _createCall(TMP_CLAIM, 30 days, new address[](0), noEvaluatorConfig(), t, worker);
        bytes32 longest = abi.decode(_relay(requester, REWARD, data), (bytes32));
        (, acceptBy) = market.getReservation(longest);
        assertEq(acceptBy, block.timestamp + 30 days, "30 days is the maximum");

        t.acceptWindowSecs = uint32(1 hours - 1);
        _expectCreateRevert(TMP_CLAIM, DELIVERY, t, worker, ITMPCore.InvalidTerms.selector);
        t.acceptWindowSecs = uint32(30 days + 1);
        _expectCreateRevert(TMP_CLAIM, 31 days, t, worker, ITMPCore.InvalidTerms.selector);
    }

    function test_Create_AcceptWindowOnlyWithReservedWorker() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.acceptWindowSecs = uint32(1 hours);
        _expectCreateRevert(TMP_CLAIM, DELIVERY, t, address(0), ITMPCore.InvalidTerms.selector);
        bytes memory plain = abi.encodeCall(
            ITMPTerms.createTask,
            (
                taskConfig(REWARD, DELIVERY, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t
            )
        );
        vm.expectRevert(ITMPCore.InvalidTerms.selector);
        _relay(requester, REWARD, plain);
    }

    function test_Create_OnlyClaimModeAndNotTheRequester() public {
        _expectCreateRevert(TMP_BOUNTY, DELIVERY, _terms(), worker, ITMPCore.InvalidMode.selector);
        _expectCreateRevert(TMP_PITCH, DELIVERY, _terms(), worker, ITMPCore.InvalidMode.selector);
        _expectCreateRevert(TMP_CLAIM, DELIVERY, _terms(), requester, ITMPCore.InvalidWorker.selector);
    }

    function test_Create_DeliveryNotShorterThanWindow() public {
        _expectCreateRevert(TMP_CLAIM, WINDOW - 1, _terms(), worker, ITMPCore.InvalidTerms.selector);
        bytes memory data = _createCall(TMP_CLAIM, WINDOW, new address[](0), noEvaluatorConfig(), _terms(), worker);
        _relay(requester, REWARD, data);
    }

    function test_Create_RefundOnReject() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.rejectOutcome = ITMPCore.RejectOutcome.Reopen;
        _expectCreateRevert(TMP_CLAIM, DELIVERY, t, worker, ITMPCore.InvalidTerms.selector);
        // Without a reserved worker Reopen stays allowed.
        _create(t, address(0));
        t.rejectOutcome = ITMPCore.RejectOutcome.Refund;
        _create(t, worker);
    }

    function _expectCreateRevert(
        bytes4 mode,
        uint256 duration,
        ITMPCore.TaskTerms memory t,
        address reserved,
        bytes4 err
    ) internal {
        bytes memory data = _createCall(mode, duration, new address[](0), noEvaluatorConfig(), t, reserved);
        vm.expectRevert(err);
        _relay(requester, REWARD, data);
    }

    function test_Create_VersionOneOverloadStillCreates() public {
        ITMPCore.TaskTermsV1 memory v1;
        v1.version = 1;
        v1.stakeRequired = true;
        v1.stakeBps = 1000;
        bytes memory data = abi.encodeCall(
            ITMPTermsV1.createTask,
            (
                taskConfig(REWARD, DELIVERY, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                v1
            )
        );
        assertEq(
            bytes4(data),
            bytes4(
                keccak256(
                    "createTask((uint256,uint256,bytes4,uint256,uint256,bytes4),(address[],bytes),(bytes32,string,bytes32[]),(address,uint256,uint16,uint32,uint32,address),(uint8,bool,uint16,uint8,uint32,uint32,uint32,uint8,uint16,uint8,uint16,uint8,uint32))"
                )
            ),
            "the rev025 selector"
        );
        bytes32 taskId = abi.decode(_relay(requester, REWARD, data), (bytes32));
        ITMPCore.TaskTerms memory t = market.getTaskTerms(taskId);
        assertEq(t.version, 2, "recorded as version 2");
        assertTrue(t.stakeRequired, "terms carried over");
        assertEq(t.stakeBps, 1000, "terms carried over");
        (address w,) = market.getReservation(taskId);
        assertEq(w, address(0), "no reserved worker");
    }

    // -------------------------------------------------------------------------
    // Claim (accept)
    // -------------------------------------------------------------------------

    function test_Claim_OnlyReservedWorker() public {
        bytes32 taskId = _reserved();
        vm.expectRevert(ITMPCore.NotReservedWorker.selector);
        _claim(taskId, stranger, 0);
        _claim(taskId, worker, 0);
        assertEq(market.getTask(taskId).worker, worker, "claimed by the reserved worker");

        // Without a reserved worker anyone may claim.
        bytes32 open = _create(_terms(), address(0));
        _claim(open, stranger, 0);
        assertEq(market.getTask(open).worker, stranger);
    }

    function test_Claim_UntilAcceptBy() public {
        bytes32 taskId = _reserved();
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(ITMPCore.AcceptWindowClosed.selector);
        _claim(taskId, worker, 0);

        bytes32 onTime = _reserved();
        vm.warp(block.timestamp + WINDOW);
        _claim(onTime, worker, 0);
    }

    function test_Claim_DeliveryPeriodCountsFromTheClaim() public {
        bytes32 taskId = _reserved();
        vm.warp(block.timestamp + 2 days);
        uint256 claimedAt = block.timestamp;
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPCore.TaskExpiryExtended(taskId, claimedAt + DELIVERY);
        _claim(taskId, worker, 0);
        ITMPCore.Task memory t = market.getTask(taskId);
        assertEq(t.expiryTime, claimedAt + DELIVERY, "the full delivery period from the claim");
        assertEq(t.stakeAmount, 0, "stake defaults to zero");

        // Without a reserved worker the expiry does not move.
        bytes32 open = _create(_terms(), address(0));
        uint256 expiry = market.getTask(open).expiryTime;
        vm.warp(block.timestamp + 1 days);
        _claim(open, stranger, 0);
        assertEq(market.getTask(open).expiryTime, expiry, "unchanged for an open claim");
    }

    function test_Claim_RequiredStakeAndHooksAsUsual() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _withHook(hook, worker);
        assertEq(hook.checkFundCalls(), 1, "checkFund at create");
        _claim(taskId, worker, 0);
        assertEq(hook.checkClaimCalls(), 1, "checkClaim runs on the reserved worker's claim");

        hook.setRejectOnCheckClaim(true);
        bytes32 rejected = _withHook(hook, worker);
        vm.expectRevert(ITMPCore.HookCheckClaimRejected.selector);
        _claim(rejected, worker, 0);

        bytes32 staked = _create(_stakeTerms(), worker);
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _claim(staked, worker, STAKE - 1);
        _claim(staked, worker, STAKE);
        assertEq(market.totalLiabilities(), 2 * REWARD + STAKE + REWARD, "stake booked");
    }

    // -------------------------------------------------------------------------
    // Decline
    // -------------------------------------------------------------------------

    function test_Decline_RefundsAndEnds() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _withHook(hook, worker);
        vm.expectRevert(ITMPCore.NotReservedWorker.selector);
        _relay(stranger, 0, abi.encodeCall(market.declineReservation, (taskId, 0)));

        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.TaskCancelled(taskId, requester, REWARD);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.ReservationDeclined(taskId, worker);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPFeedback.WorkerAgentBound(worker, WORKER_AGENT);
        _relay(worker, 0, abi.encodeCall(market.declineReservation, (taskId, WORKER_AGENT)));

        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Cancelled), "declined");
        assertEq(usdc.balanceOf(requester), REWARD, "refunded");
        assertEq(hook.onCancelCalls(), 1, "onCancel runs");
        assertEq(registry.calls(), 0, "declining sends nothing by default");
        assertEq(market.workerAgentOf(worker), WORKER_AGENT, "worker agent bound");
        _assertSettled();
    }

    function test_Decline_Guards() public {
        bytes32 open = _create(_terms(), address(0));
        vm.expectRevert(ITMPCore.NotReserved.selector);
        _relay(worker, 0, abi.encodeCall(market.declineReservation, (open, 0)));

        bytes32 claimed = _reserved();
        _claim(claimed, worker, 0);
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        _relay(worker, 0, abi.encodeCall(market.declineReservation, (claimed, 0)));

        bytes32 late = _reserved();
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(ITMPCore.AcceptWindowClosed.selector);
        _relay(worker, 0, abi.encodeCall(market.declineReservation, (late, 0)));
    }

    function test_Decline_OwnerSetFeedbackAndEvaluatorStake() public {
        vm.prank(owner);
        market.setFeedbackValue(keccak256("reservation_declined"), -5);
        ITMPCore.TaskEvaluatorConfig memory cfg = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: STAKE,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
        bytes memory data = _createCall(TMP_CLAIM, DELIVERY, new address[](0), cfg, _terms(), worker);
        bytes32 taskId = abi.decode(_relay(requester, REWARD + STAKE, data), (bytes32));
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPEvaluator.EvaluatorStakeRefunded(taskId, requester, STAKE);
        _relay(worker, 0, abi.encodeCall(market.declineReservation, (taskId, WORKER_AGENT)));
        assertEq(usdc.balanceOf(requester), REWARD + STAKE, "reward and evaluator stake refunded");
        assertEq(registry.calls(), 1, "owner-set value sent");
        assertEq(registry.lastAgentId(), WORKER_AGENT);
        assertEq(registry.lastValue(), -5);
        assertEq(registry.lastTag2(), "tmp.mode.claim");
        _assertSettled();
    }

    // -------------------------------------------------------------------------
    // Lapse and withdraw
    // -------------------------------------------------------------------------

    function test_Lapse_RefundExpiredAfterAcceptBy() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _withHook(hook, worker);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);

        vm.warp(block.timestamp + 1);
        assertLt(block.timestamp, market.getTask(taskId).expiryTime, "before expiry");
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.TaskExpired(taskId, requester, REWARD);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.ReservationLapsed(taskId, worker);
        vm.prank(stranger);
        market.refundExpired(taskId, 0);
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Expired), "lapsed");
        assertEq(usdc.balanceOf(requester), REWARD, "refunded");
        assertEq(hook.onExpireCalls(), 1, "onExpire runs");
        assertEq(registry.calls(), 0, "a lapse sends nothing by default");
        _assertSettled();

        // Without a reserved worker an open task waits for its expiry.
        bytes32 open = _create(_terms(), address(0));
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(open, 0);
    }

    function test_Lapse_RefundsEvaluatorStakeAndSendsOwnerSetFeedback() public {
        _bindWorkerAgent();
        vm.prank(owner);
        market.setFeedbackValue(keccak256("reservation_lapsed"), -10);
        ITMPCore.TaskEvaluatorConfig memory cfg = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: STAKE,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
        bytes memory data = _createCall(TMP_CLAIM, DELIVERY, new address[](0), cfg, _terms(), worker);
        bytes32 taskId = abi.decode(_relay(requester, REWARD + STAKE, data), (bytes32));
        uint256 before = usdc.balanceOf(requester);
        vm.warp(block.timestamp + WINDOW + 1);
        market.refundExpired(taskId, 0);
        assertEq(usdc.balanceOf(requester) - before, REWARD + STAKE, "reward and evaluator stake refunded");
        assertEq(registry.calls(), 1, "owner-set lapse value sent");
        assertEq(registry.lastValue(), -10);
        assertEq(registry.lastAgentId(), WORKER_AGENT);
        _assertSettled();
    }

    function test_Withdraw_IsCancelTask() public {
        bytes32 taskId = _reserved();
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Cancelled), "withdrawn");
        assertEq(usdc.balanceOf(requester), REWARD, "refunded");
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        _claim(taskId, worker, 0);
    }

    // -------------------------------------------------------------------------
    // updateTask
    // -------------------------------------------------------------------------

    function _expectUpdateReverts(bytes32 taskId, bytes4 err) internal {
        uint256 expiry = market.getTask(taskId).expiryTime;
        vm.expectRevert(err);
        _relay(requester, 0, abi.encodeCall(market.updateTask, (taskId, REWARD / 2, 0, 0, 0)));
        vm.expectRevert(err);
        _relay(requester, REWARD, abi.encodeCall(market.updateTask, (taskId, REWARD * 2, 0, 0, 0)));
        vm.expectRevert(err);
        _relay(requester, 0, abi.encodeCall(market.updateTask, (taskId, 0, expiry + 1 days, 0, 0)));
        vm.expectRevert(err);
        _relay(requester, 0, abi.encodeCall(market.updateTask, (taskId, 0, block.timestamp + 1, 0, 0)));
    }

    function test_Update_RevertsWhileReservationPending() public {
        bytes32 taskId = _reserved();
        (, uint256 acceptBy) = market.getReservation(taskId);
        _expectUpdateReverts(taskId, ITMPCore.ReservationPending.selector);

        vm.warp(acceptBy);
        _expectUpdateReverts(taskId, ITMPCore.ReservationPending.selector);
        assertEq(market.getTask(taskId).reward, REWARD, "offer unchanged");

        // To change the offer the requester withdraws it and makes a new one.
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        bytes32 reoffered = _reserved();
        _claim(reoffered, worker, 0);
    }

    function test_Update_EndedReservation() public {
        bytes32 claimed = _reserved();
        _claim(claimed, worker, 0);
        _expectUpdateReverts(claimed, ITMPCore.TermsFrozen.selector);

        bytes32 declined = _reserved();
        _relay(worker, 0, abi.encodeCall(market.declineReservation, (declined, 0)));
        _expectUpdateReverts(declined, ITMPCore.TaskNotOpen.selector);

        bytes32 lapsed = _reserved();
        (, uint256 acceptBy) = market.getReservation(lapsed);
        vm.warp(acceptBy + 1);
        uint256 newExpiry = market.getTask(lapsed).expiryTime + 1 days;
        _relay(requester, 0, abi.encodeCall(market.updateTask, (lapsed, REWARD / 2, newExpiry, 0, 0)));
        assertEq(market.getTask(lapsed).reward, REWARD / 2, "a lapsed offer updates");
        assertEq(market.getTask(lapsed).expiryTime, newExpiry);

        bytes32 open = _create(_terms(), address(0));
        _relay(requester, 0, abi.encodeCall(market.updateTask, (open, 0, block.timestamp + 1, 0, 0)));
        assertEq(market.getTask(open).expiryTime, block.timestamp + 1, "no reserved worker, no block");
    }

    // -------------------------------------------------------------------------
    // After the claim: never reopened
    // -------------------------------------------------------------------------

    function test_Accepted_DeliverAndAccept() public {
        bytes32 taskId = _create(_stakeTerms(), worker);
        _claim(taskId, worker, STAKE);
        _deliver(taskId);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        uint256 fee = (REWARD * 500) / 10000;
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(usdc.balanceOf(worker), REWARD - fee + STAKE, "same platform fee; stake back");
        _assertSettled();
    }

    function test_Reject_RefundsWithReservedWorker_ReopensWithout() public {
        bytes32 taskId = _create(_stakeTerms(), worker);
        _claim(taskId, worker, STAKE);
        _deliver(taskId);
        _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));
        uint256 rejectFee = (REWARD * 2000) / 10000;
        uint256 platformFee = (rejectFee * 500) / 10000;
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Expired), "rejection ends it");
        assertEq(usdc.balanceOf(worker), rejectFee - platformFee + STAKE, "reject fee and stake to the worker");
        assertEq(usdc.balanceOf(requester), REWARD - rejectFee, "rest refunded");
        _assertSettled();

        bytes32 open = _create(_terms(), address(0));
        _claim(open, stranger, 0);
        _relay(stranger, 0, abi.encodeCall(market.submitWork, (open, WORK)));
        _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (open)));
        assertEq(uint8(_status(open)), uint8(ITMPCore.TaskStatus.Open), "an open claim reopens by default");
    }

    function test_Release_EndsWithRefund_ReopensWithout() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _withHook(hook, worker);
        _claim(taskId, worker, 0);
        vm.recordLogs();
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));
        _assertNoReopen();
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Expired), "hand-back ends it");
        assertEq(usdc.balanceOf(requester), REWARD, "refunded");
        assertEq(hook.onExpireCalls(), 1, "onExpire runs");
        assertEq(hook.onForfeitCalls(), 0, "no onForfeit: the task does not reopen");
        _assertSettled();

        bytes32 open = _create(_terms(), address(0));
        _claim(open, stranger, 0);
        _relay(stranger, 0, abi.encodeCall(market.releaseClaim, (open)));
        assertEq(uint8(_status(open)), uint8(ITMPCore.TaskStatus.Open), "an open claim reopens");
    }

    function test_Release_WithStakeSettlesPenalty() public {
        bytes32 taskId = _create(_stakeTerms(), worker);
        _claim(taskId, worker, STAKE);
        // Inside the 10% grace period: no penalty.
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));
        assertEq(usdc.balanceOf(worker), STAKE, "stake back in grace");
        assertEq(usdc.balanceOf(requester), REWARD, "reward refunded");
        _assertSettled();
    }

    function test_Forfeit_EndsWithRefund_ReopensWithout() public {
        _bindWorkerAgent();
        bytes32 taskId = _create(_stakeTerms(), worker);
        _claim(taskId, worker, STAKE);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        uint256 before = usdc.balanceOf(requester);
        vm.recordLogs();
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        _assertNoReopen();
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Expired), "forfeit ends it");
        assertEq(usdc.balanceOf(requester) - before, REWARD + STAKE, "reward refunded, stake forfeited to requester");
        assertEq(registry.calls(), 1, "reservation_forfeited sent");
        assertEq(registry.lastValue(), -25, "default forfeit value");
        assertEq(registry.lastAgentId(), WORKER_AGENT);
        _assertSettled();

        bytes32 open = _create(_stakeTerms(), address(0));
        _claim(open, stranger, STAKE);
        vm.warp(market.getTask(open).expiryTime + 1);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (open)));
        assertEq(uint8(_status(open)), uint8(ITMPCore.TaskStatus.Open), "an open claim reopens");
        assertEq(registry.calls(), 1, "no reservation feedback without a reserved worker");
    }

    function test_RefundExpired_ClaimedUndeliveredForfeits() public {
        _bindWorkerAgent();
        bytes32 taskId = _create(_stakeTerms(), worker);
        _claim(taskId, worker, STAKE);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        vm.prank(stranger);
        market.refundExpired(taskId, 0);
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(registry.lastValue(), -25, "forfeit feedback");
        _assertSettled();
    }

    function test_Revision_And_LapsedReview() public {
        bytes32 taskId = _reserved();
        _claim(taskId, worker, 0);
        _deliver(taskId);
        _relay(requester, 0, abi.encodeCall(market.requestRevision, (taskId)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("v2"))));
        vm.warp(block.timestamp + 72 hours + 1);
        market.settleLapsedReview(taskId);
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "lapsed review pays");
        _assertSettled();
    }

    // -------------------------------------------------------------------------
    // Evaluator
    // -------------------------------------------------------------------------

    function test_Evaluator_OnlyBeforeTheClaim() public {
        bytes32 taskId = _reserved();
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), address(0))
            )
        );
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, evaluator, "assigned before the claim");

        bytes32 claimed = _reserved();
        _claim(claimed, worker, 0);
        vm.expectRevert(ITMPCore.TermsFrozen.selector);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (claimed, evaluator, 0, 0, uint32(2 days), uint32(1 days), address(0))
            )
        );
    }

    function test_Evaluator_RejectRefundsAndTimeoutDoesNotReopen() public {
        ITMPCore.TaskEvaluatorConfig memory cfg = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
        bytes memory data = _createCall(TMP_CLAIM, DELIVERY, new address[](0), cfg, _terms(), worker);
        bytes32 rejected = abi.decode(_relay(requester, REWARD, data), (bytes32));
        _claim(rejected, worker, 0);
        _deliver(rejected);
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate, (rejected, ITMPCore.VerdictType.REJECT, 0, 0, bytes32(0), new ITMPCore.Award[](0))
            )
        );
        vm.warp(block.timestamp + 1 days);
        market.finalizeVerdict(rejected);
        assertEq(uint8(_status(rejected)), uint8(ITMPCore.TaskStatus.Cancelled), "a rejecting verdict refunds");

        bytes32 timedOut = abi.decode(_relay(requester, REWARD, data), (bytes32));
        _claim(timedOut, worker, 0);
        _deliver(timedOut);
        vm.warp(block.timestamp + 2 days + 1);
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (timedOut)));
        assertEq(uint8(_status(timedOut)), uint8(ITMPCore.TaskStatus.Claimed), "back under review, not reopened");
        assertEq(market.getTask(timedOut).worker, worker, "still the reserved worker's task");
    }

    // -------------------------------------------------------------------------
    // Feedback defaults and the binding
    // -------------------------------------------------------------------------

    function test_FeedbackDefaults() public view {
        (int128 declined,) = market.feedbackValue(keccak256("reservation_declined"));
        (int128 lapsed,) = market.feedbackValue(keccak256("reservation_lapsed"));
        (int128 forfeited,) = market.feedbackValue(keccak256("reservation_forfeited"));
        assertEq(declined, 0);
        assertEq(lapsed, 0);
        assertEq(forfeited, -25);
    }

    function _claimWithAgent(bytes32 taskId, address w, uint256 stake, uint256 agentId) internal {
        _relay(w, stake, abi.encodeCall(ITMPReservation.claimTask, (taskId, stake, agentId)));
    }

    function test_ClaimWithAgent_AcceptThenForfeitSendsFeedback() public {
        bytes32 taskId = _create(_stakeTerms(), worker);
        vm.expectEmit(address(market));
        emit ITMPFeedback.WorkerAgentBound(worker, WORKER_AGENT);
        _claimWithAgent(taskId, worker, STAKE, WORKER_AGENT);
        assertEq(market.workerAgentOf(worker), WORKER_AGENT, "bound by the accept");
        assertEq(uint8(_status(taskId)), uint8(ITMPCore.TaskStatus.Claimed));

        vm.warp(market.getTask(taskId).expiryTime + 1);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        assertEq(registry.calls(), 1, "reservation_forfeited sent");
        assertEq(registry.lastValue(), -25);
        assertEq(registry.lastAgentId(), WORKER_AGENT);
        _assertSettled();
    }

    function test_ClaimWithAgent_BindsOnlyOnTheWorkersRelayedAccept() public {
        bytes32 direct = _reserved();
        vm.prank(worker);
        vm.expectRevert();
        ITMPReservation(address(market)).claimTask(direct, 0, WORKER_AGENT);

        bytes32 open = _create(_terms(), address(0));
        _claimWithAgent(open, worker, 0, WORKER_AGENT);
        assertEq(market.workerAgentOf(worker), 0, "no binding without a reservation");

        bytes32 zero = _reserved();
        _claimWithAgent(zero, worker, 0, 0);
        assertEq(market.workerAgentOf(worker), 0, "0 binds nothing");

        bytes32 other = _reserved();
        vm.expectRevert(ITMPCore.NotReservedWorker.selector);
        _claimWithAgent(other, stranger, 0, WORKER_AGENT);
        assertEq(market.workerAgentOf(stranger), 0);
    }

    function test_Binding_OnlyFromTheWorkersOwnRelay() public {
        assertEq(market.workerAgentOf(worker), 0);
        _bindWorkerAgent();
        assertEq(market.workerAgentOf(worker), WORKER_AGENT);
        assertEq(market.workerAgentOf(stranger), 0);
    }

    function _assertNoReopen() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 reopened = keccak256("TaskReopened(bytes32)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != reopened, "no TaskReopened");
        }
    }
}
