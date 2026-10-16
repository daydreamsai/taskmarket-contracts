// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { LibGuards } from "../src/libraries/LibGuards.sol";
import { TMP_CLAIM, TMP_PITCH, TMP_AUCTION, TMP_AUCTION_DUTCH, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev025 review window on single-payee tasks without an evaluator: accept, rejectDelivery,
///      requestRevision, settleLapsedReview, and the DeliveryPending guards on refund and forfeit.
contract ReviewWindowTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC1);
    address internal keeper = address(0xD0);
    address internal evaluator = address(0xE0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant PRICE = 60e6;
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant FEE_BPS = 500;
    uint256 internal constant WINDOW = 72 hours;
    bytes32 internal constant WORK = keccak256("work");
    bytes32 internal constant WORK2 = keccak256("work2");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, uint16(FEE_BPS));
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _terms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 1;
    }

    function _create(bytes4 mode, ITMPCore.TaskTerms memory terms) internal returns (bytes32) {
        return _createWith(mode, terms, noEvaluatorConfig());
    }

    function _createWith(bytes4 mode, ITMPCore.TaskTerms memory terms, ITMPCore.TaskEvaluatorConfig memory evalCfg)
        internal
        returns (bytes32)
    {
        ITMPCore.TaskConfig memory cfg = mode == TMP_PITCH
            ? taskConfig(REWARD, DURATION, mode, 1 days, 0, bytes4(0))
            : mode == TMP_AUCTION
                ? taskConfig(REWARD, DURATION, mode, 0, 1 days, TMP_AUCTION_DUTCH)
                : taskConfig(REWARD, DURATION, mode);
        bytes memory data = abi.encodeCall(
            ITMPTerms.createTask,
            (
                cfg,
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                evalCfg,
                terms
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    function _take(bytes32 taskId, bytes4 mode, address w) internal {
        if (mode == TMP_CLAIM) {
            _relay(w, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
        } else if (mode == TMP_PITCH) {
            _relay(w, 0, abi.encodeCall(market.submitPitch, (taskId, keccak256(abi.encode(w)))));
            _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, w)));
        } else {
            _relay(w, 0, abi.encodeCall(market.acceptAuction, (taskId, PRICE)));
        }
    }

    function _submit(bytes32 taskId, address w, bytes32 deliverable) internal {
        _relay(w, 0, abi.encodeCall(market.submitWork, (taskId, deliverable)));
    }

    function _delivered(bytes4 mode, ITMPCore.TaskTerms memory terms) internal returns (bytes32 taskId) {
        taskId = _create(mode, terms);
        _take(taskId, mode, worker);
        _submit(taskId, worker, WORK);
    }

    /// @dev Delivered one hour before expiry, so the review window runs past it.
    function _deliveredLate(bytes4 mode) internal returns (bytes32 taskId) {
        taskId = _create(mode, _terms());
        _take(taskId, mode, worker);
        vm.warp(market.getTask(taskId).expiryTime - 1 hours);
        _submit(taskId, worker, WORK);
    }

    function _accept(bytes32 taskId, address w, bytes32 deliverable) internal {
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, w, deliverable, 0)));
    }

    function _reject(bytes32 taskId) internal {
        _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));
    }

    function _revise(bytes32 taskId) internal {
        _relay(requester, 0, abi.encodeCall(market.requestRevision, (taskId)));
    }

    function _expectRelayRevert(address sender, bytes memory data, bytes4 err) internal {
        vm.expectRevert(err);
        forwarder.relay(address(market), sender, 0, data);
    }

    function _bal(address a) internal view returns (uint256) {
        return usdc.balanceOf(a);
    }

    // -------------------------------------------------------------------------
    // Accept and lapse
    // -------------------------------------------------------------------------

    function test_Accept_InsideWindowAfterExpiry() public {
        bytes32 taskId = _deliveredLate(TMP_CLAIM);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _accept(taskId, worker, WORK);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(_bal(worker), REWARD - REWARD * FEE_BPS / 10000 + STAKE);
        assertEq(market.reviewDeadline(taskId), 0);
        assertEq(_bal(address(market)), 0);
    }

    function test_Accept_AfterWindowReverts() public {
        bytes32 taskId = _delivered(TMP_PITCH, _terms());
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        _expectRelayRevert(
            requester,
            abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)),
            ITMPCore.ReviewWindowClosed.selector
        );
    }

    function test_Reject_AfterWindowReverts() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        _expectRelayRevert(
            requester, abi.encodeCall(market.rejectDelivery, (taskId)), ITMPCore.ReviewWindowClosed.selector
        );
    }

    function test_ReviewDeadline_View() public {
        bytes32 taskId = _create(TMP_CLAIM, _terms());
        assertEq(market.reviewDeadline(taskId), 0);
        _take(taskId, TMP_CLAIM, worker);
        _submit(taskId, worker, WORK);
        assertEq(market.reviewDeadline(taskId), vm.getBlockTimestamp() + WINDOW);
    }

    function test_ReviewDeadline_CustomWindow() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.reviewWindowSecs = 2 days;
        bytes32 taskId = _delivered(TMP_CLAIM, t);
        assertEq(market.reviewDeadline(taskId), vm.getBlockTimestamp() + 2 days);
    }

    function test_SettleLapsedReview_BeforeDeadlineReverts() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        vm.expectRevert(ITMPCore.ReviewWindowOpen.selector);
        vm.prank(keeper);
        market.settleLapsedReview(taskId);
    }

    function test_SettleLapsedReview_NoDeliveryReverts() public {
        bytes32 taskId = _create(TMP_CLAIM, _terms());
        _take(taskId, TMP_CLAIM, worker);
        vm.expectRevert(ITMPCore.DeliverableRequired.selector);
        market.settleLapsedReview(taskId);
    }

    function _lapseEqualsAccept(bytes4 mode) internal {
        uint256 snap = vm.snapshotState();
        bytes32 taskId = _delivered(mode, _terms());
        vm.warp(vm.getBlockTimestamp() + WINDOW - 1);
        _accept(taskId, worker, WORK);
        uint256 wAccept = _bal(worker);
        uint256 rAccept = _bal(requester);
        uint256 fAccept = _bal(feeRecipient);
        vm.revertToState(snap);

        taskId = _delivered(mode, _terms());
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        vm.expectEmit(true, true, false, false, address(market));
        emit ITMPCore.ReviewLapsed(taskId, worker);
        vm.prank(keeper);
        market.settleLapsedReview(taskId);
        assertEq(_bal(worker), wAccept, "worker");
        assertEq(_bal(requester), rAccept, "requester");
        assertEq(_bal(feeRecipient), fAccept, "fee");
        assertEq(_bal(address(market)), 0, "escrow");
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(market.reviewDeadline(taskId), 0);
        vm.expectRevert(ITMPCore.DeliverableRequired.selector);
        market.settleLapsedReview(taskId);
    }

    function test_SettleLapsedReview_EqualsAccept_Claim() public {
        _lapseEqualsAccept(TMP_CLAIM);
    }

    function test_SettleLapsedReview_EqualsAccept_Pitch() public {
        _lapseEqualsAccept(TMP_PITCH);
    }

    function test_SettleLapsedReview_EqualsAccept_Auction() public {
        _lapseEqualsAccept(TMP_AUCTION);
        assertEq(_bal(worker), PRICE - PRICE * FEE_BPS / 10000);
        assertEq(_bal(requester), REWARD - PRICE);
    }

    function test_SettleLapsedReview_WorkerCanBeRated() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        market.settleLapsedReview(taskId);
        vm.expectEmit(true, true, false, false, address(market));
        emit ITMPCore.TaskRated(taskId, worker, 5, 0);
        _relay(requester, 0, abi.encodeCall(market.rateTask, (taskId, worker, 5, 0, 0, "", bytes32(0))));
    }

    // -------------------------------------------------------------------------
    // DeliveryPending on refund and forfeit; no auction pay-at-expiry
    // -------------------------------------------------------------------------

    function test_RefundExpired_DeliveryPending() public {
        bytes4[3] memory modes = [TMP_CLAIM, TMP_PITCH, TMP_AUCTION];
        for (uint256 i; i < 3; ++i) {
            bytes32 taskId = _delivered(modes[i], _terms());
            vm.warp(market.getTask(taskId).expiryTime + 1);
            vm.expectRevert(ITMPCore.DeliveryPending.selector);
            market.refundExpired(taskId, 0);
        }
    }

    function test_Forfeit_DeliveryPending() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        _expectRelayRevert(
            requester, abi.encodeCall(market.forfeitAndReopen, (taskId)), ITMPCore.DeliveryPending.selector
        );
    }

    function test_Auction_DeliveredNotPaidAtExpiry() public {
        bytes32 taskId = _delivered(TMP_AUCTION, _terms());
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.expectRevert(ITMPCore.DeliveryPending.selector);
        market.refundExpired(taskId, 0);
        assertEq(_bal(worker), 0);
    }

    function test_Auction_UndeliveredRefundsAtExpiry() public {
        bytes32 taskId = _create(TMP_AUCTION, _terms());
        _take(taskId, TMP_AUCTION, worker);
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        market.refundExpired(taskId, 0);
        assertEq(_bal(requester), REWARD);
        assertEq(_bal(worker), 0);
        assertEq(_bal(address(market)), 0);
    }

    // -------------------------------------------------------------------------
    // evaluatorTimeout on a delivered single-payee task
    // -------------------------------------------------------------------------

    uint32 internal constant EVAL_WINDOW = 2 days;

    function _evalCfg() internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: EVAL_WINDOW,
            appealWindow: 1 days,
            disputeResolver: address(0)
        });
    }

    /// @dev Delivered one hour before expiry to an evaluator who never evaluates; the requester
    ///      times the evaluator out after the evaluation window, which runs past the expiry.
    function _evaluatorTimedOut(bytes4 mode) internal returns (bytes32 taskId, uint256 timedOutAt) {
        taskId = _createWith(mode, _terms(), _evalCfg());
        _take(taskId, mode, worker);
        vm.warp(market.getTask(taskId).expiryTime - 1 hours);
        _submit(taskId, worker, WORK);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Review), "in review");
        vm.warp(vm.getBlockTimestamp() + EVAL_WINDOW + 1);
        timedOutAt = vm.getBlockTimestamp();
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));
    }

    function test_EvaluatorTimeout_Claim_ReturnsToReviewWindow() public {
        (bytes32 taskId, uint256 timedOutAt) = _evaluatorTimedOut(TMP_CLAIM);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Claimed), "claimed");
        assertEq(market.reviewDeadline(taskId), timedOutAt + WINDOW, "window runs from the timeout");
        assertGt(vm.getBlockTimestamp(), market.getTask(taskId).expiryTime, "past expiry");

        // The requester cannot refund over the delivered work at expiry.
        vm.expectRevert(ITMPCore.DeliveryPending.selector);
        market.refundExpired(taskId, 0);
        _expectRelayRevert(
            requester, abi.encodeCall(market.forfeitAndReopen, (taskId)), ITMPCore.DeliveryPending.selector
        );

        // Once the window lapses the worker is paid.
        vm.warp(timedOutAt + WINDOW + 1);
        market.settleLapsedReview(taskId);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted), "accepted");
        assertEq(_bal(worker), REWARD - REWARD * FEE_BPS / 10000 + STAKE, "worker paid and stake returned");
    }

    function test_EvaluatorTimeout_Pitch_ReturnsToWorkerSelected() public {
        (bytes32 taskId, uint256 timedOutAt) = _evaluatorTimedOut(TMP_PITCH);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.WorkerSelected), "selected");
        assertEq(market.reviewDeadline(taskId), timedOutAt + WINDOW, "window runs from the timeout");
        vm.expectRevert(ITMPCore.DeliveryPending.selector);
        market.refundExpired(taskId, 0);
    }

    // -------------------------------------------------------------------------
    // appeal extends expiry by the resolution window
    // -------------------------------------------------------------------------

    address internal resolver = address(0xE1);
    uint32 internal constant APPEAL_WINDOW = 1 days;

    function _disputeCfg() internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: EVAL_WINDOW,
            appealWindow: APPEAL_WINDOW,
            disputeResolver: resolver
        });
    }

    /// @dev Claim task with an evaluator and a dispute resolver, delivered `before` seconds ahead
    ///      of expiry and rejected at once, so the verdict sits in its appeal window.
    function _rejectedVerdict(ITMPCore.TaskTerms memory terms, uint256 before) internal returns (bytes32 taskId) {
        taskId = _createWith(TMP_CLAIM, terms, _disputeCfg());
        _take(taskId, TMP_CLAIM, worker);
        vm.warp(market.getTask(taskId).expiryTime - before);
        _submit(taskId, worker, WORK);
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate, (taskId, ITMPCore.VerdictType.REJECT, 0, 1000, bytes32(0), new ITMPCore.Award[](0))
            )
        );
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Appealing), "appealing");
    }

    function _appeal(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
    }

    /// @dev Delivered one hour before expiry: the verdict's appeal deadline is the expiry, so
    ///      without the extension the resolver would have one second before the dispute lapses.
    function test_Appeal_LateDelivery_ExtendsExpiryByDefaultResolutionWindow() public {
        bytes32 taskId = _rejectedVerdict(_terms(), 1 hours);
        uint256 oldExpiry = market.getTask(taskId).expiryTime;
        vm.warp(vm.getBlockTimestamp() + APPEAL_WINDOW - 1); // just before the appeal deadline
        uint256 newExpiry = vm.getBlockTimestamp() + 72 hours;
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPCore.TaskExpiryExtended(taskId, newExpiry);
        _appeal(taskId);
        assertEq(market.getTask(taskId).expiryTime, newExpiry, "expiry extended");

        vm.warp(oldExpiry + 1);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, awards);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted), "resolved");
    }

    function test_Appeal_LateDelivery_UnresolvedDisputeLapsesAfterResolutionWindow() public {
        bytes32 taskId = _rejectedVerdict(_terms(), 1 hours);
        vm.warp(vm.getBlockTimestamp() + APPEAL_WINDOW - 1); // just before the appeal deadline
        uint256 oldExpiry = market.getTask(taskId).expiryTime;
        _appeal(taskId);
        uint256 newExpiry = market.getTask(taskId).expiryTime;
        assertGt(newExpiry, oldExpiry, "appeal extended expiry");

        vm.warp(newExpiry);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);

        vm.warp(newExpiry + 1);
        market.refundExpired(taskId, 0);
        // The original REJECT verdict stands.
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Cancelled), "lapsed");
    }

    function test_Appeal_CustomResolutionWindow_ExtendsByTerms() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.resolutionWindowSecs = 2 days;
        bytes32 taskId = _rejectedVerdict(t, 1 hours);
        vm.warp(vm.getBlockTimestamp() + APPEAL_WINDOW - 1); // just before the appeal deadline
        uint256 newExpiry = vm.getBlockTimestamp() + 2 days;
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPCore.TaskExpiryExtended(taskId, newExpiry);
        _appeal(taskId);
        assertEq(market.getTask(taskId).expiryTime, newExpiry, "extended by the custom window");
    }

    function test_Appeal_ExpiryAlreadyCovers_NoExtension() public {
        bytes32 taskId = _rejectedVerdict(_terms(), 5 days);
        uint256 expiry = market.getTask(taskId).expiryTime;
        vm.recordLogs();
        _appeal(taskId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != ITMPCore.TaskExpiryExtended.selector, "no extension log");
        }
        assertEq(market.getTask(taskId).expiryTime, expiry, "expiry unchanged");
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Disputed), "disputed");
    }

    // -------------------------------------------------------------------------
    // rejectDelivery: every mode and outcome at zero, default and maximum fee
    // -------------------------------------------------------------------------

    struct RejectCase {
        bytes4 mode;
        ITMPCore.RejectOutcome outcome;
        uint16 storedFee;
        uint256 feeBps;
        ITMPCore.PenaltyTo penaltyTo;
    }

    function _checkReject(RejectCase memory c) internal {
        ITMPCore.TaskTerms memory t = _terms();
        t.rejectOutcome = c.outcome;
        t.rejectFeeBps = c.storedFee;
        t.penaltyTo = c.penaltyTo;
        bytes32 taskId = _delivered(c.mode, t);
        uint256 expiryBefore = market.getTask(taskId).expiryTime;

        uint256 base = c.mode == TMP_AUCTION ? PRICE : REWARD;
        uint256 rejectFee = base * c.feeBps / 10000;
        uint256 platformFee = rejectFee * FEE_BPS / 10000;
        uint256 stake = c.mode == TMP_CLAIM ? STAKE : 0;
        // A delivered worker's stake always comes back on reject, whatever the reject fee.
        uint256 forfeited = 0;
        bool reopen = c.mode != TMP_AUCTION && c.outcome != ITMPCore.RejectOutcome.Refund;

        if (stake > 0) {
            vm.expectEmit(true, true, false, true, address(market));
            emit ITMPCore.StakeReturned(taskId, worker, stake);
        }
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.DeliveryRejected(taskId, worker, rejectFee, forfeited);
        _reject(taskId);

        ITMPCore.Task memory task = market.getTask(taskId);
        uint256 toPenaltyRequester = c.penaltyTo == ITMPCore.PenaltyTo.Requester ? forfeited : 0;
        uint256 toPenaltyProtocol = forfeited - toPenaltyRequester;
        if (c.mode == TMP_CLAIM) assertEq(task.stakeAmount, 0, "stake cleared");
        assertEq(_bal(worker), rejectFee - platformFee + stake, "worker net");
        assertEq(_bal(feeRecipient), platformFee + toPenaltyProtocol, "platform fee");
        assertEq(task.worker, address(0), "worker cleared");
        assertEq(task.deliverable, bytes32(0), "deliverable cleared");
        assertEq(market.reviewDeadline(taskId), 0);
        if (reopen) {
            assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open), "reopened");
            assertEq(task.reward, REWARD - rejectFee, "reward is remaining escrow");
            assertEq(_bal(address(market)), REWARD - rejectFee, "escrow kept");
            assertEq(_bal(requester), toPenaltyRequester, "requester");
            uint256 ext = vm.getBlockTimestamp() + WINDOW;
            assertEq(task.expiryTime, expiryBefore > ext ? expiryBefore : ext, "expiry extended");
        } else {
            assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Expired), "ended");
            assertEq(task.reward, 0);
            assertEq(_bal(address(market)), 0, "escrow empty");
            assertEq(_bal(requester), REWARD - rejectFee + toPenaltyRequester, "requester refund");
        }
    }

    function _rejectAllFees(bytes4 mode, ITMPCore.RejectOutcome outcome) internal {
        uint16[3] memory stored = [uint16(1), uint16(0), uint16(5001)];
        uint256[3] memory bps = [uint256(0), uint256(2000), uint256(5000)];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            _checkReject(RejectCase(mode, outcome, stored[i], bps[i], ITMPCore.PenaltyTo.Requester));
            vm.revertToState(snap);
        }
    }

    function test_RejectDelivery_Claim_Reopen() public {
        _rejectAllFees(TMP_CLAIM, ITMPCore.RejectOutcome.Default);
        _rejectAllFees(TMP_CLAIM, ITMPCore.RejectOutcome.Reopen);
    }

    function test_RejectDelivery_Claim_Refund() public {
        _rejectAllFees(TMP_CLAIM, ITMPCore.RejectOutcome.Refund);
    }

    function test_RejectDelivery_Pitch_Reopen() public {
        _rejectAllFees(TMP_PITCH, ITMPCore.RejectOutcome.Default);
        _rejectAllFees(TMP_PITCH, ITMPCore.RejectOutcome.Reopen);
    }

    function test_RejectDelivery_Pitch_Refund() public {
        _rejectAllFees(TMP_PITCH, ITMPCore.RejectOutcome.Refund);
    }

    function test_RejectDelivery_Auction_Refund() public {
        _rejectAllFees(TMP_AUCTION, ITMPCore.RejectOutcome.Default);
        _rejectAllFees(TMP_AUCTION, ITMPCore.RejectOutcome.Refund);
    }

    function test_RejectDelivery_ZeroFee_PenaltyToProtocol_StakeReturned() public {
        _checkReject(RejectCase(TMP_CLAIM, ITMPCore.RejectOutcome.Refund, 1, 0, ITMPCore.PenaltyTo.Protocol));
    }

    function test_RejectDelivery_Claim_ReopenedTaskExcludesWorker() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        _reject(taskId);
        _expectRelayRevert(
            worker, abi.encodeCall(market.claimTask, (taskId, 0)), ITMPCore.SubmissionAlreadyRejected.selector
        );
        _take(taskId, TMP_CLAIM, worker2);
        _submit(taskId, worker2, WORK2);
        _accept(taskId, worker2, WORK2);
        uint256 remaining = REWARD - REWARD * 2000 / 10000;
        assertEq(_bal(worker2), remaining - remaining * FEE_BPS / 10000 + STAKE);
        assertEq(_bal(address(market)), 0);
    }

    function test_RejectDelivery_Pitch_BackToSelection() public {
        bytes32 taskId = _create(TMP_PITCH, _terms());
        _relay(worker2, 0, abi.encodeCall(market.submitPitch, (taskId, keccak256("p2"))));
        _take(taskId, TMP_PITCH, worker);
        _submit(taskId, worker, WORK);
        _reject(taskId);
        _expectRelayRevert(
            requester,
            abi.encodeCall(market.selectWorker, (taskId, worker)),
            ITMPCore.SubmissionAlreadyRejected.selector
        );
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker2)));
        _submit(taskId, worker2, WORK2);
        _accept(taskId, worker2, WORK2);
        assertEq(_bal(address(market)), 0);
    }

    function test_RejectDelivery_ReopenedUntakenRefundsAtExpiry() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        _reject(taskId);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        market.refundExpired(taskId, 0);
        assertEq(_bal(requester), REWARD - REWARD * 2000 / 10000);
        assertEq(_bal(address(market)), 0);
    }

    function test_RejectDelivery_Guards() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        _expectRelayRevert(worker, abi.encodeCall(market.rejectDelivery, (taskId)), ITMPCore.NotRequester.selector);
        bytes32 undelivered = _create(TMP_CLAIM, _terms());
        _take(undelivered, TMP_CLAIM, worker);
        _expectRelayRevert(
            requester, abi.encodeCall(market.rejectDelivery, (undelivered)), ITMPCore.DeliverableRequired.selector
        );
        bytes32 bounty = _create(TMP_BOUNTY, _terms());
        _expectRelayRevert(requester, abi.encodeCall(market.rejectDelivery, (bounty)), ITMPCore.InvalidMode.selector);
        _reject(taskId);
        _expectRelayRevert(
            requester, abi.encodeCall(market.rejectDelivery, (taskId)), ITMPCore.DeliverableRequired.selector
        );
    }

    // -------------------------------------------------------------------------
    // requestRevision
    // -------------------------------------------------------------------------

    function test_RequestRevision_LimitThenExhausted() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        for (uint8 i = 1; i <= 2; ++i) {
            vm.expectEmit(true, true, false, true, address(market));
            emit ITMPCore.RevisionRequested(taskId, worker, i);
            _revise(taskId);
            _submit(taskId, worker, keccak256(abi.encode(i)));
        }
        _expectRelayRevert(
            requester, abi.encodeCall(market.requestRevision, (taskId)), ITMPCore.RevisionsExhausted.selector
        );
    }

    function test_RequestRevision_NoneAllowed() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.maxRevisions = 1;
        bytes32 taskId = _delivered(TMP_PITCH, t);
        _expectRelayRevert(
            requester, abi.encodeCall(market.requestRevision, (taskId)), ITMPCore.RevisionsExhausted.selector
        );
    }

    function test_RequestRevision_WindowRestartsAndExpiryExtends() public {
        bytes32 taskId = _deliveredLate(TMP_CLAIM);
        _revise(taskId);
        uint256 due = vm.getBlockTimestamp() + WINDOW;
        assertEq(market.getTask(taskId).expiryTime, due, "expiry extended");
        assertEq(market.reviewDeadline(taskId), due + WINDOW, "superseded delivery deadline");
        _expectRelayRevert(
            requester,
            abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)),
            ITMPCore.DeliveryPending.selector
        );
        _expectRelayRevert(
            requester, abi.encodeCall(market.rejectDelivery, (taskId)), ITMPCore.DeliverableRequired.selector
        );

        vm.warp(vm.getBlockTimestamp() + 2 days);
        _submit(taskId, worker, WORK2);
        assertEq(market.reviewDeadline(taskId), vm.getBlockTimestamp() + WINDOW, "window restarts");
        vm.warp(vm.getBlockTimestamp() + WINDOW - 1);
        _accept(taskId, worker, WORK2);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_RequestRevision_MissedResubmissionReturnsToReview() public {
        bytes32 taskId = _delivered(TMP_AUCTION, _terms());
        _revise(taskId);
        uint256 due = vm.getBlockTimestamp() + WINDOW;
        vm.warp(due + 1);
        _expectRelayRevert(
            worker, abi.encodeCall(market.submitWork, (taskId, WORK2)), ITMPCore.DeliverableAlreadySet.selector
        );
        assertEq(market.reviewDeadline(taskId), due + WINDOW);
        vm.expectRevert(ITMPCore.ReviewWindowOpen.selector);
        market.settleLapsedReview(taskId);
        vm.warp(due + WINDOW + 1);
        market.settleLapsedReview(taskId);
        assertEq(_bal(worker), PRICE - PRICE * FEE_BPS / 10000);
        assertEq(_bal(address(market)), 0);
    }

    function test_RequestRevision_MissedResubmissionCanBeAccepted() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        _revise(taskId);
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        _accept(taskId, worker, WORK);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_RequestRevision_ForfeitAndRefundRevert() public {
        bytes32 taskId = _deliveredLate(TMP_CLAIM);
        _revise(taskId);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        _expectRelayRevert(
            requester, abi.encodeCall(market.forfeitAndReopen, (taskId)), ITMPCore.DeliveryPending.selector
        );
        vm.expectRevert(ITMPCore.DeliveryPending.selector);
        market.refundExpired(taskId, 0);
    }

    function test_RequestRevision_Guards() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        _expectRelayRevert(worker, abi.encodeCall(market.requestRevision, (taskId)), ITMPCore.NotRequester.selector);
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        _expectRelayRevert(
            requester, abi.encodeCall(market.requestRevision, (taskId)), ITMPCore.ReviewWindowClosed.selector
        );
    }

    // -------------------------------------------------------------------------
    // TaskExpiryExtended
    // -------------------------------------------------------------------------

    function _expectExpiryExtended(bytes32 taskId, uint256 newExpiry) internal {
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPCore.TaskExpiryExtended(taskId, newExpiry);
    }

    function _assertNoExpiryExtended() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0) {
                assertTrue(
                    logs[i].topics[0] != ITMPCore.TaskExpiryExtended.selector, "expiry already covered: no event"
                );
            }
        }
    }

    function test_ExpiryExtended_ForfeitAndReopen() public {
        bytes32 taskId = _create(TMP_CLAIM, _terms());
        _take(taskId, TMP_CLAIM, worker);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        uint256 newExpiry = vm.getBlockTimestamp() + WINDOW;
        _expectExpiryExtended(taskId, newExpiry);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        assertEq(market.getTask(taskId).expiryTime, newExpiry);
    }

    function test_ExpiryExtended_RejectDeliveryReopen() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.rejectOutcome = ITMPCore.RejectOutcome.Reopen;
        bytes32 taskId = _create(TMP_CLAIM, t);
        _take(taskId, TMP_CLAIM, worker);
        vm.warp(market.getTask(taskId).expiryTime - 1 hours);
        _submit(taskId, worker, WORK);
        uint256 newExpiry = vm.getBlockTimestamp() + WINDOW;
        _expectExpiryExtended(taskId, newExpiry);
        _reject(taskId);
        assertEq(market.getTask(taskId).expiryTime, newExpiry);
    }

    function test_ExpiryExtended_ReleaseClaim() public {
        bytes32 taskId = _create(TMP_CLAIM, _terms());
        _take(taskId, TMP_CLAIM, worker);
        vm.warp(market.getTask(taskId).expiryTime - 1 hours);
        uint256 newExpiry = vm.getBlockTimestamp() + WINDOW;
        _expectExpiryExtended(taskId, newExpiry);
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));
        assertEq(market.getTask(taskId).expiryTime, newExpiry);
    }

    function test_ExpiryExtended_RequestRevision() public {
        bytes32 taskId = _deliveredLate(TMP_CLAIM);
        uint256 due = vm.getBlockTimestamp() + WINDOW;
        _expectExpiryExtended(taskId, due);
        _revise(taskId);
        assertEq(market.getTask(taskId).expiryTime, due);
    }

    function test_ExpiryExtended_NotEmittedWhenExpiryCovers() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.rejectOutcome = ITMPCore.RejectOutcome.Reopen;
        bytes32 taskId = _delivered(TMP_CLAIM, t);
        uint256 expiry = market.getTask(taskId).expiryTime;
        assertGt(expiry, vm.getBlockTimestamp() + WINDOW, "expiry already past the extension");

        vm.recordLogs();
        _revise(taskId);
        _assertNoExpiryExtended();
        assertEq(market.getTask(taskId).expiryTime, expiry, "revision leaves expiry");

        _submit(taskId, worker, WORK2);
        vm.recordLogs();
        _reject(taskId);
        _assertNoExpiryExtended();
        assertEq(market.getTask(taskId).expiryTime, expiry, "reopen leaves expiry");
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open), "reopened");
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function test_Paused_EveryExitReverts() public {
        bytes32 taskId = _delivered(TMP_CLAIM, _terms());
        vm.prank(owner);
        market.pause();
        bytes4 paused = LibGuards.EnforcedPause.selector;
        _expectRelayRevert(requester, abi.encodeCall(market.rejectDelivery, (taskId)), paused);
        _expectRelayRevert(requester, abi.encodeCall(market.requestRevision, (taskId)), paused);
        _expectRelayRevert(requester, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)), paused);
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        vm.expectRevert(paused);
        market.settleLapsedReview(taskId);
        vm.expectRevert(paused);
        market.refundExpired(taskId, 0);
        _expectRelayRevert(requester, abi.encodeCall(market.forfeitAndReopen, (taskId)), paused);
    }
}
