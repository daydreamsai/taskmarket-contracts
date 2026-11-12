// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { ITMPEvaluator } from "../src/interfaces/ITMPEvaluator.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { TMP_BOUNTY, TMP_BENCHMARK, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { LibTerms } from "../src/libraries/LibTerms.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev rev030: a Bounty or Benchmark with an evaluator and live submissions has an exit that does
///      not depend on the evaluator or the requester. The evaluator's deadline is
///      `max(expiryTime, decisionStartAt) + evaluationWindow`; after it evaluate refuses a verdict
///      and anyone may call evaluatorTimeout, which forfeits the evaluator's stake, clears the
///      evaluator and starts the requester's decision window. After that window requesterTimeout
///      refunds the requester.
contract Rev030EvaluatorTimeoutTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC1);
    address internal evaluator = address(0xE0);
    address internal stranger = address(0xD0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 5e6;
    uint256 internal constant DURATION = 7 days;
    uint32 internal constant EVAL_WINDOW = 3 days;
    uint32 internal constant APPEAL_WINDOW = 1 days;
    bytes32 internal constant WORK = keccak256("work");
    bytes32 internal constant WORK2 = keccak256("work2");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
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

    function _evalCfg() internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: STAKE,
            evaluatorFeeBps: 0,
            evaluationWindow: EVAL_WINDOW,
            appealWindow: APPEAL_WINDOW,
            disputeResolver: address(0)
        });
    }

    function _create(bytes4 mode) internal returns (bytes32) {
        ITMPCore.TaskTerms memory t;
        t.version = 1;
        bytes memory data = abi.encodeCall(
            ITMPTerms.createTask,
            (
                taskConfig(REWARD, DURATION, mode),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                _evalCfg(),
                t
            )
        );
        return abi.decode(_relay(requester, REWARD + STAKE, data), (bytes32));
    }

    function _submitted(bytes4 mode) internal returns (bytes32 taskId) {
        taskId = _create(mode);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, WORK2)));
    }

    function _evalDeadline(bytes32 taskId) internal view returns (uint256) {
        return market.getTask(taskId).expiryTime + EVAL_WINDOW;
    }

    function _evaluateData(bytes32 taskId) internal view returns (bytes memory) {
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD / 2, rank: 1 });
        return abi.encodeCall(
            market.evaluate, (taskId, ITMPCore.VerdictType.PARTIAL, uint16(8000), uint16(9000), WORK, awards)
        );
    }

    function _acceptData(bytes32 taskId) internal view returns (bytes memory) {
        address[] memory ws = new address[](2);
        ws[0] = worker;
        ws[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        return abi.encodeCall(market.acceptSubmissions, (taskId, ws, shares, new bytes32[](0), 0));
    }

    function _timedOut(bytes4 mode) internal returns (bytes32 taskId, uint256 at) {
        taskId = _submitted(mode);
        at = _evalDeadline(taskId) + 1;
        vm.warp(at);
        vm.prank(stranger);
        market.evaluatorTimeout(taskId);
    }

    // -------------------------------------------------------------------------
    // evaluatorTimeout on a Bounty or Benchmark
    // -------------------------------------------------------------------------

    function test_Timeout_RevertsAtAndBeforeTheDeadline() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        vm.expectRevert(ITMPCore.EvaluationWindowNotExpired.selector);
        market.evaluatorTimeout(taskId);
        vm.warp(_evalDeadline(taskId));
        vm.expectRevert(ITMPCore.EvaluationWindowNotExpired.selector);
        market.evaluatorTimeout(taskId);
    }

    function test_Timeout_RevertsWithNoSubmissions() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        vm.warp(_evalDeadline(taskId) + 1);
        vm.expectRevert(ITMPCore.NoActiveSubmissions.selector);
        market.evaluatorTimeout(taskId);
    }

    function test_Reject_RevertsWhileTheTaskHasAnEvaluator() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.expectRevert(ITMPCore.EvaluatorDecides.selector);
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker)));
        // The evaluator's timeout clears the evaluator, after which the requester may reject.
        vm.warp(_evalDeadline(taskId) + 1);
        market.evaluatorTimeout(taskId);
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker)));
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker2)));
    }

    function test_Timeout_Bounty_ForfeitsClearsAndStartsTheDecisionWindow() public {
        _assertTimedOut(TMP_BOUNTY);
    }

    function test_Timeout_Benchmark_ForfeitsClearsAndStartsTheDecisionWindow() public {
        _assertTimedOut(TMP_BENCHMARK);
    }

    function _assertTimedOut(bytes4 mode) internal {
        bytes32 taskId = _submitted(mode);
        uint256 at = _evalDeadline(taskId) + 1;
        vm.warp(at);
        uint256 feesBefore = usdc.balanceOf(feeRecipient);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPEvaluator.EvaluatorTimedOut(taskId, evaluator, STAKE);
        vm.prank(stranger);
        market.evaluatorTimeout(taskId);

        assertEq(usdc.balanceOf(feeRecipient) - feesBefore, STAKE, "stake forfeited to the fee recipient");
        ITMPCore.TaskEvaluatorConfig memory cfg = market.getTaskEvaluatorConfig(taskId);
        assertEq(cfg.evaluator, address(0), "evaluator cleared");
        assertEq(cfg.evaluatorStake, 0, "stake cleared");
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.PendingApproval));
        assertEq(market.getTaskClock(taskId).decisionStartAt, at, "decision window starts at the timeout");
        assertEq(usdc.balanceOf(address(market)), REWARD, "only the reward stays in escrow");

        vm.expectRevert(ITMPCore.NotInReviewState.selector);
        market.evaluatorTimeout(taskId);
    }

    function test_Timeout_ThenRequesterAcceptsWithinItsDecisionWindow() public {
        (bytes32 taskId, uint256 at) = _timedOut(TMP_BOUNTY);
        vm.warp(at + LibTerms.DEFAULT_DECISION_WINDOW_SECS);
        vm.prank(stranger);
        vm.expectRevert(ITMPCore.DecisionWindowNotLapsed.selector);
        market.requesterTimeout(taskId);
        _relay(requester, 0, _acceptData(taskId));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_Timeout_ThenRejectStaysOpenWithinTheDecisionWindow() public {
        (bytes32 taskId, uint256 at) = _timedOut(TMP_BENCHMARK);
        vm.warp(at + LibTerms.DEFAULT_DECISION_WINDOW_SECS);
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker)));
        vm.warp(at + LibTerms.DEFAULT_DECISION_WINDOW_SECS + 1);
        vm.expectRevert(ITMPCore.DecisionWindowLapsed.selector);
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker2)));
    }

    function test_Timeout_ThenRequesterTimeoutRefundsAfterTheDecisionWindow() public {
        (bytes32 taskId, uint256 at) = _timedOut(TMP_BOUNTY);
        vm.warp(at + LibTerms.DEFAULT_DECISION_WINDOW_SECS + 1);
        uint256 before = usdc.balanceOf(requester);
        vm.prank(stranger);
        market.requesterTimeout(taskId);
        assertEq(usdc.balanceOf(requester) - before, REWARD, "reward refunded");
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(usdc.balanceOf(address(market)), 0, "escrow empty");
        assertEq(market.totalLiabilities(), 0, "liabilities released");
    }

    function test_RequesterTimeout_StillRevertsWhileTheEvaluatorIsSet() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_evalDeadline(taskId) + LibTerms.DEFAULT_DECISION_WINDOW_SECS + 30 days);
        vm.expectRevert(ITMPCore.DecisionWindowNotLapsed.selector);
        market.requesterTimeout(taskId);
    }

    // -------------------------------------------------------------------------
    // evaluate on a Bounty or Benchmark
    // -------------------------------------------------------------------------

    function test_Evaluate_AtTheDeadline_Works() public {
        bytes32 taskId = _submitted(TMP_BENCHMARK);
        vm.warp(_evalDeadline(taskId));
        _relay(evaluator, 0, _evaluateData(taskId));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Appealing));
        vm.expectRevert(ITMPCore.NotInReviewState.selector);
        market.evaluatorTimeout(taskId);
    }

    function test_Evaluate_BeforeExpiry_Works() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        _relay(evaluator, 0, _evaluateData(taskId));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Appealing));
    }

    function test_Evaluate_AfterTheDeadline_Reverts() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_evalDeadline(taskId) + 1);
        vm.expectRevert(ITMPCore.EvaluationWindowClosed.selector);
        _relay(evaluator, 0, _evaluateData(taskId));
    }

    // -------------------------------------------------------------------------
    // Claim is unchanged
    // -------------------------------------------------------------------------

    function test_Claim_TimeoutStillNeedsReview() public {
        bytes32 taskId = _create(TMP_CLAIM);
        vm.warp(_evalDeadline(taskId) + 1);
        vm.expectRevert(ITMPCore.NotInReviewState.selector);
        market.evaluatorTimeout(taskId);
        assertEq(market.getTaskClock(taskId).decisionStartAt, 0);
    }
}

/// @dev rev030: the same exit on a project task. Its expiry is held to the project's latest expiry
///      (end date plus task grace), but the evaluation and decision windows run past it, so the
///      worst case for the backers' money is that latest expiry plus evaluationWindow plus the
///      requester's decision window. requesterTimeout then refunds to the project.
contract Rev030EvaluatorTimeoutProjectTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal owner = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);

    uint256 internal constant BUDGET = 10e6;
    uint256 internal constant REWARD = 8e6;
    uint256 internal constant STAKE = 1e6;
    uint64 internal constant LIFETIME = 7 days;
    uint32 internal constant GRACE = 2 days;
    uint32 internal constant EVAL_WINDOW = 3 days;

    uint256 internal id;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        market = deployDiamond(admin, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        projects = ITMPProject(address(market));
        initMockPool(address(market), admin);
        usdc.mint(address(forwarder), 1e18);
        uint64 endsAt = uint64(block.timestamp) + LIFETIME;
        id = abi.decode(
            _relay(owner, BUDGET, abi.encodeCall(projects.createProject, (address(usdc), BUDGET, endsAt, GRACE))),
            (uint256)
        );
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function test_ProjectTask_WorstCaseIsLatestExpiryPlusBothWindows() public {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        bytes memory data = abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(REWARD, LIFETIME + GRACE, TMP_BOUNTY),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                ITMPCore.TaskEvaluatorConfig({
                    evaluator: evaluator,
                    evaluatorStake: STAKE,
                    evaluatorFeeBps: 0,
                    evaluationWindow: EVAL_WINDOW,
                    appealWindow: 1 days,
                    disputeResolver: address(0)
                }),
                t,
                address(0)
            )
        );
        bytes32 taskId = abi.decode(_relay(owner, 0, data), (bytes32));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 latest = uint256(projects.getProject(id).endsAt) + GRACE;
        uint256 expiry = market.getTask(taskId).expiryTime;
        assertLe(expiry, latest, "expiry held to the project's latest expiry");

        uint256 timeoutAt = expiry + EVAL_WINDOW + 1;
        vm.warp(timeoutAt);
        market.evaluatorTimeout(taskId);
        assertEq(market.getTask(taskId).expiryTime, expiry, "the timeout does not extend expiry");

        uint256 refundAt = timeoutAt + LibTerms.DEFAULT_DECISION_WINDOW_SECS + 1;
        assertLe(refundAt, latest + EVAL_WINDOW + LibTerms.DEFAULT_DECISION_WINDOW_SECS + 2, "worst case");
        vm.warp(refundAt);
        market.requesterTimeout(taskId);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(market.totalLiabilities(), 0, "liabilities released");
    }
}
