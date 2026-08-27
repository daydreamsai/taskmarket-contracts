// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPRegistry } from "../src/interfaces/ITMPRegistry.sol";
import {
    TMP_BOUNTY,
    TMP_CLAIM,
    TMP_PITCH,
    TMP_BENCHMARK,
    TMP_AUCTION,
    TMP_AUCTION_ENGLISH
} from "../src/interfaces/ITMPModes.sol";
import { RequiredTagPolicyHook } from "../src/hooks/reference/RequiredTagPolicyHook.sol";
import { AllowlistedWorkerHook } from "../src/hooks/reference/AllowlistedWorkerHook.sol";
import { CompletionReceiptHook } from "../src/hooks/reference/CompletionReceiptHook.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { TMPHookConformance } from "./helpers/TMPHookConformance.t.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

contract RequiredTagPolicyHookTest is TMPHookConformance {
    RequiredTagPolicyHook internal hook;
    address internal constant DIAMOND = address(0xD1A);
    address internal constant WORKER = address(0xA11CE);

    function setUp() public {
        hook = new RequiredTagPolicyHook(DIAMOND, CONFORMANCE_TAG);
    }

    function hookUnderTest() internal view override returns (ITMPHook) {
        return hook;
    }

    function taskmarketDiamond() internal pure override returns (address) {
        return DIAMOND;
    }

    function allowedConformanceWorker() internal pure override returns (address) {
        return WORKER;
    }

    function test_constructorRejectsZeroRequiredTag() public {
        vm.expectRevert(RequiredTagPolicyHook.RequiredTagZero.selector);
        new RequiredTagPolicyHook(DIAMOND, bytes32(0));
    }

    function test_exposesImmutableRequiredTag() public view {
        assertEq(hook.requiredTag(), CONFORMANCE_TAG);
    }

    function test_rejectsFundingWithoutRequiredImmutableTag() public {
        ITMPCore.TaskContext memory ctx = _context(1);
        ctx.tags = new bytes32[](0);
        vm.prank(DIAMOND);
        assertFalse(hook.checkFund(TASK_ID, ctx, bytes("")));
    }

    function testFuzz_acceptsRequiredTagAtAnyPosition(uint8 rawPosition) public {
        uint256 position = uint256(rawPosition) % 32;
        uint256 complementaryPosition = 31 - position;
        ITMPCore.TaskContext memory ctx = _context(1);
        ctx.tags = new bytes32[](32);
        for (uint256 i; i < ctx.tags.length; ++i) {
            ctx.tags[i] = bytes32(i + 1);
        }

        // Pair complementary positions so every fuzz run scans 33 tags in total.
        vm.startPrank(DIAMOND);
        bytes32 displacedTag = ctx.tags[position];
        ctx.tags[position] = CONFORMANCE_TAG;
        assertTrue(hook.checkFund(TASK_ID, ctx, bytes("")));
        ctx.tags[position] = displacedTag;

        ctx.tags[complementaryPosition] = CONFORMANCE_TAG;
        assertTrue(hook.checkFund(TASK_ID, ctx, bytes("")));
        vm.stopPrank();
    }
}

contract AllowlistedWorkerHookTest is TMPHookConformance {
    AllowlistedWorkerHook internal hook;
    address internal constant DIAMOND = address(0xD1A);
    address internal constant WORKER = address(0xA11CE);

    function setUp() public {
        hook = new AllowlistedWorkerHook(DIAMOND, WORKER);
        vm.mockCall(DIAMOND, abi.encodeCall(ITMPRegistry.getTaskVerdict, (TASK_ID)), abi.encode(_verdict()));
    }

    function hookUnderTest() internal view override returns (ITMPHook) {
        return hook;
    }

    function taskmarketDiamond() internal pure override returns (address) {
        return DIAMOND;
    }

    function allowedConformanceWorker() internal pure override returns (address) {
        return WORKER;
    }

    function test_constructorRejectsZeroAllowedWorker() public {
        vm.expectRevert(AllowlistedWorkerHook.AllowedWorkerZeroAddress.selector);
        new AllowlistedWorkerHook(DIAMOND, address(0));
    }

    function test_exposesImmutableAllowedWorker() public view {
        assertEq(hook.allowedWorker(), WORKER);
    }

    function test_acceptsOnlyBountyAndClaimAtFunding() public {
        ITMPCore.TaskContext memory ctx = _context(1);

        vm.startPrank(DIAMOND);
        ctx.mode = TMP_BOUNTY;
        assertTrue(hook.checkFund(TASK_ID, ctx, bytes("")));
        ctx.mode = TMP_CLAIM;
        assertTrue(hook.checkFund(TASK_ID, ctx, bytes("")));
        vm.stopPrank();
    }

    function test_rejectsModesWithUngatedWorkerEntryPoints() public {
        ITMPCore.TaskContext memory ctx = _context(1);

        vm.startPrank(DIAMOND);
        ctx.mode = TMP_PITCH;
        assertFalse(hook.checkFund(TASK_ID, ctx, bytes("")));
        ctx.mode = TMP_BENCHMARK;
        assertFalse(hook.checkFund(TASK_ID, ctx, bytes("")));
        ctx.mode = TMP_AUCTION;
        assertFalse(hook.checkFund(TASK_ID, ctx, bytes("")));
        vm.stopPrank();
    }

    function test_rejectsUnallowlistedWorker() public {
        vm.prank(DIAMOND);
        assertFalse(hook.checkClaim(TASK_ID, _context(1), address(0xBAD)));
        vm.prank(DIAMOND);
        assertFalse(hook.checkSelectWorker(TASK_ID, _context(1), address(0xBAD)));
        vm.prank(DIAMOND);
        assertFalse(hook.checkSubmit(TASK_ID, _context(1), address(0xBAD), bytes32(0)));
    }

    function test_evaluationAwardsRequireEveryRecipientToBeAllowlistedIncludingZeroAmount() public {
        ITMPCore.Verdict memory verdict = _verdict();
        verdict.awards = new ITMPCore.Award[](2);
        verdict.awards[0] = ITMPCore.Award({ worker: address(0xBAD), amount: 0, rank: 1 });
        verdict.awards[1] = ITMPCore.Award({ worker: WORKER, amount: 1, rank: 2 });
        vm.mockCall(DIAMOND, abi.encodeCall(ITMPRegistry.getTaskVerdict, (TASK_ID)), abi.encode(verdict));

        vm.startPrank(DIAMOND);
        assertFalse(hook.checkEvaluate(TASK_ID, _context(1), address(0xE1A1)));
        assertFalse(hook.checkComplete(TASK_ID, _context(1), verdict));
        vm.stopPrank();
    }

    function test_evaluationAwardsAllowZeroAndNonzeroAmountsForAllowedWorker() public {
        ITMPCore.Verdict memory verdict = _verdict();
        verdict.awards = new ITMPCore.Award[](2);
        verdict.awards[0] = ITMPCore.Award({ worker: WORKER, amount: 0, rank: 1 });
        verdict.awards[1] = ITMPCore.Award({ worker: WORKER, amount: 1, rank: 2 });
        vm.mockCall(DIAMOND, abi.encodeCall(ITMPRegistry.getTaskVerdict, (TASK_ID)), abi.encode(verdict));

        vm.startPrank(DIAMOND);
        assertTrue(hook.checkEvaluate(TASK_ID, _context(1), address(0xE1A1)));
        assertTrue(hook.checkComplete(TASK_ID, _context(1), verdict));
        vm.stopPrank();
    }

    function testFuzz_rejectsEveryOtherWorker(address worker) public {
        vm.assume(worker != WORKER);
        vm.prank(DIAMOND);
        assertFalse(hook.checkClaim(TASK_ID, _context(1), worker));
    }
}

contract AllowlistedWorkerHookDiamondIntegrationTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    AllowlistedWorkerHook internal hook;

    address internal constant OWNER = address(0x1001);
    address internal constant FEE_RECIPIENT = address(0x1002);
    address internal constant REQUESTER = address(0x1003);
    address internal constant ALLOWED_WORKER = address(0x1004);
    address internal constant OTHER_WORKER = address(0x1005);
    address internal constant EVALUATOR = address(0x1006);
    address internal constant DISPUTE_RESOLVER = address(0x1007);
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        usdc = new MockUSDC();

        vm.startPrank(OWNER);
        market = deployDiamond(OWNER, address(usdc), FEE_RECIPIENT, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();

        hook = new AllowlistedWorkerHook(address(market), ALLOWED_WORKER);
        usdc.mint(address(forwarder), 10 * REWARD);
    }

    function test_DiamondAllowsBountyForAllowlistedWorker() public {
        bytes32 taskId = _createTask(TMP_BOUNTY, bytes4(0));
        bytes32 deliverable = keccak256("allowed-bounty-work");

        _relay(ALLOWED_WORKER, abi.encodeCall(market.submitWork, (taskId, deliverable)));
        assertEq(market.taskSubmissionHashes(taskId, ALLOWED_WORKER).length, 1);

        vm.expectRevert(ITMPCore.HookCheckSubmitRejected.selector);
        _relay(OTHER_WORKER, abi.encodeCall(market.submitWork, (taskId, keccak256("other-bounty-work"))));
        assertEq(market.taskSubmissionHashes(taskId, OTHER_WORKER).length, 0);
    }

    function test_DiamondAllowsClaimForAllowlistedWorker() public {
        bytes32 taskId = _createTask(TMP_CLAIM, bytes4(0));

        vm.expectRevert(ITMPCore.HookCheckClaimRejected.selector);
        _relay(OTHER_WORKER, abi.encodeCall(market.claimTask, (taskId, 0)));

        _relay(ALLOWED_WORKER, abi.encodeCall(market.claimTask, (taskId, 0)));
        bytes32 deliverable = keccak256("allowed-claim-work");
        _relay(ALLOWED_WORKER, abi.encodeCall(market.submitWork, (taskId, deliverable)));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.worker, ALLOWED_WORKER);
        assertEq(task.deliverable, deliverable);
    }

    function test_DiamondRejectsZeroFirstUnallowlistedBountyEvaluationAndRollsBack() public {
        bytes32 taskId = _createTaskWithEvaluator(TMP_BOUNTY, address(0));
        _relay(ALLOWED_WORKER, abi.encodeCall(market.submitWork, (taskId, keccak256("allowed-bounty-work"))));

        vm.expectRevert(ITMPCore.HookCheckEvaluateRejected.selector);
        _evaluate(taskId, _zeroFirstUnallowlistedAwards());

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.worker, address(0));
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open));
        assertFalse(market.getTaskVerdict(taskId).issued);

        _evaluate(taskId, _allowedAwards());
        assertEq(market.getTask(taskId).worker, ALLOWED_WORKER);
    }

    function test_DiamondRejectsZeroFirstUnallowlistedClaimEvaluationAndRollsBack() public {
        bytes32 taskId = _createTaskWithEvaluator(TMP_CLAIM, address(0));
        _relay(ALLOWED_WORKER, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(ALLOWED_WORKER, abi.encodeCall(market.submitWork, (taskId, keccak256("allowed-claim-work"))));

        vm.expectRevert(ITMPCore.HookCheckEvaluateRejected.selector);
        _evaluate(taskId, _zeroFirstUnallowlistedAwards());

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.worker, ALLOWED_WORKER);
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Review));
        assertFalse(market.getTaskVerdict(taskId).issued);

        _evaluate(taskId, _allowedAwards());
        assertEq(market.getTask(taskId).worker, ALLOWED_WORKER);
    }

    function test_DiamondRejectsUnallowlistedDisputeAwardAndAllowsRetry() public {
        bytes32 taskId = _createTaskWithEvaluator(TMP_CLAIM, DISPUTE_RESOLVER);
        _relay(ALLOWED_WORKER, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(ALLOWED_WORKER, abi.encodeCall(market.submitWork, (taskId, keccak256("allowed-claim-work"))));
        _evaluate(taskId, _allowedAwards());
        _relay(ALLOWED_WORKER, abi.encodeCall(market.appeal, (taskId)));

        vm.expectRevert(ITMPCore.HookCheckCompleteRejected.selector);
        _relay(
            DISPUTE_RESOLVER,
            abi.encodeCall(
                market.resolveDispute, (taskId, ITMPCore.VerdictType.APPROVE, _zeroFirstUnallowlistedAwards())
            )
        );

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Disputed));
        assertEq(market.getTask(taskId).worker, ALLOWED_WORKER);

        _relay(
            DISPUTE_RESOLVER,
            abi.encodeCall(market.resolveDispute, (taskId, ITMPCore.VerdictType.APPROVE, _allowedAwards()))
        );
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(market.getTask(taskId).worker, ALLOWED_WORKER);
    }

    function test_DiamondRejectsPitchAtCreation() public {
        _assertCreationRejected(TMP_PITCH, bytes4(0));
    }

    function test_DiamondRejectsBenchmarkAtCreation() public {
        _assertCreationRejected(TMP_BENCHMARK, bytes4(0));
    }

    function test_DiamondRejectsAuctionBeforeBidsCanBeRecorded() public {
        bytes32 taskId = _nextTaskId();
        _assertCreationRejected(TMP_AUCTION, TMP_AUCTION_ENGLISH);

        vm.expectRevert(ITMPCore.TaskDoesNotExist.selector);
        _relay(ALLOWED_WORKER, abi.encodeCall(market.submitBid, (taskId, REWARD / 2)));
        vm.expectRevert(ITMPCore.TaskDoesNotExist.selector);
        _relay(OTHER_WORKER, abi.encodeCall(market.submitBid, (taskId, REWARD / 3)));
        assertEq(market.getBids(taskId).length, 0);
    }

    function _assertCreationRejected(bytes4 mode, bytes4 auctionSubtype) private {
        uint256 forwarderBalance = usdc.balanceOf(address(forwarder));
        uint256 diamondBalance = usdc.balanceOf(address(market));

        vm.expectRevert(ITMPCore.HookCheckFundRejected.selector);
        _relayCreateTask(mode, auctionSubtype);

        assertEq(usdc.balanceOf(address(forwarder)), forwarderBalance);
        assertEq(usdc.balanceOf(address(market)), diamondBalance);
        assertEq(market.requesterNonce(REQUESTER), 0);
    }

    function _createTask(bytes4 mode, bytes4 auctionSubtype) private returns (bytes32) {
        return abi.decode(_relayCreateTask(mode, auctionSubtype), (bytes32));
    }

    function _createTaskWithEvaluator(bytes4 mode, address disputeResolver) private returns (bytes32) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);

        return abi.decode(
            forwarder.relay(
                address(market),
                REQUESTER,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, mode, 0, 0, bytes4(0)),
                        ITMPCore.StakeConfig({ required: false, bps: 0 }),
                        ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        ITMPCore.TaskEvaluatorConfig({
                            evaluator: EVALUATOR,
                            evaluatorStake: 0,
                            evaluatorFeeBps: 0,
                            evaluationWindow: uint32(2 days),
                            appealWindow: uint32(1 days),
                            disputeResolver: disputeResolver
                        })
                    )
                )
            ),
            (bytes32)
        );
    }

    function _evaluate(bytes32 taskId, ITMPCore.Award[] memory awards) private {
        _relay(
            EVALUATOR,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.APPROVE, 1000, 1000, bytes32(0), awards))
        );
    }

    function _zeroFirstUnallowlistedAwards() private pure returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: OTHER_WORKER, amount: 0, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: ALLOWED_WORKER, amount: REWARD, rank: 2 });
    }

    function _allowedAwards() private pure returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: ALLOWED_WORKER, amount: REWARD, rank: 1 });
    }

    function _relayCreateTask(bytes4 mode, bytes4 auctionSubtype) private returns (bytes memory) {
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        uint256 pitchDeadline = mode == TMP_PITCH ? DURATION : 0;
        uint256 bidDeadline = mode == TMP_AUCTION ? DURATION : 0;

        return forwarder.relay(
            address(market),
            REQUESTER,
            REWARD,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD, DURATION, mode, pitchDeadline, bidDeadline, auctionSubtype),
                    ITMPCore.StakeConfig({ required: false, bps: 0 }),
                    ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig()
                )
            )
        );
    }

    function _relay(address worker, bytes memory data) private returns (bytes memory) {
        return forwarder.relay(address(market), worker, 0, data);
    }

    function _nextTaskId() private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(market), REQUESTER, market.requesterNonce(REQUESTER)));
    }
}

contract CompletionReceiptHookTest is TMPHookConformance {
    CompletionReceiptHook internal hook;
    address internal constant DIAMOND = address(0xD1A);
    address internal constant WORKER = address(0xA11CE);

    function setUp() public {
        hook = new CompletionReceiptHook(DIAMOND);
    }

    function hookUnderTest() internal view override returns (ITMPHook) {
        return hook;
    }

    function taskmarketDiamond() internal pure override returns (address) {
        return DIAMOND;
    }

    function allowedConformanceWorker() internal pure override returns (address) {
        return WORKER;
    }

    function test_recordsCompletionAndTerminalRecoveryCallbacks() public {
        ITMPCore.Verdict memory verdict = _verdict();
        verdict.evidenceHash = keccak256("evidence");
        vm.warp(123);
        vm.prank(DIAMOND);
        hook.onComplete(TASK_ID, _context(1), verdict);

        (CompletionReceiptHook.Outcome outcome, address actor, bytes32 evidenceHash, uint64 recordedAt) =
            hook.receipts(TASK_ID);
        assertEq(uint8(outcome), uint8(CompletionReceiptHook.Outcome.Completed));
        assertEq(actor, address(0));
        assertEq(evidenceHash, verdict.evidenceHash);
        assertEq(recordedAt, 123);

        vm.prank(DIAMOND);
        hook.onForfeit(TASK_ID, _context(1), WORKER);
        (outcome, actor, evidenceHash, recordedAt) = hook.receipts(TASK_ID);
        assertEq(uint8(outcome), uint8(CompletionReceiptHook.Outcome.Forfeited));
        assertEq(actor, WORKER);
        assertEq(evidenceHash, bytes32(0));
        assertEq(recordedAt, 123);

        vm.prank(DIAMOND);
        hook.onCancel(TASK_ID, _context(1));
        (outcome, actor, evidenceHash, recordedAt) = hook.receipts(TASK_ID);
        assertEq(uint8(outcome), uint8(CompletionReceiptHook.Outcome.Cancelled));
        assertEq(actor, address(0));
        assertEq(evidenceHash, bytes32(0));
        assertEq(recordedAt, 123);

        vm.prank(DIAMOND);
        hook.onExpire(TASK_ID, _context(1));
        (outcome,,, recordedAt) = hook.receipts(TASK_ID);
        assertEq(uint8(outcome), uint8(CompletionReceiptHook.Outcome.Expired));
        assertEq(recordedAt, 123);
    }
}
