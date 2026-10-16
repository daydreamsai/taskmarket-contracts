// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { LibAppStorage } from "../src/libraries/LibAppStorage.sol";
import { LibGuards } from "../src/libraries/LibGuards.sol";
import { TMP_BOUNTY, TMP_BENCHMARK } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Clears a task's terms record, leaving it as a pre-rev025 diamond would have.
contract DecisionProbeFacet {
    function probeWipeDecisionTerms(bytes32 taskId) external {
        delete LibAppStorage.appStorage().taskTerms[taskId];
    }
}

/// @dev rev025 decision deadline on a Bounty or Benchmark without an evaluator.
contract DecisionDeadlineTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC1);
    address internal evaluator = address(0xE0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant FEE_BPS = 500;
    uint256 internal constant DECISION = 7 days;
    bytes32 internal constant WORK = keccak256("work");
    bytes32 internal constant WORK2 = keccak256("work2");

    event RequesterReputation(
        bytes32 indexed taskId,
        address indexed requester,
        bytes32 event_,
        uint256 reward,
        uint32 submissionCount,
        bool selfAward
    );

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, uint16(FEE_BPS));
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = DecisionProbeFacet.probeWipeDecisionTerms.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(new DecisionProbeFacet()), IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        vm.stopPrank();
        usdc.mint(address(forwarder), 1_000_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(bytes4 mode, ITMPCore.TaskEvaluatorConfig memory ev) internal returns (bytes32) {
        ITMPCore.TaskTerms memory t;
        t.version = 1;
        bytes memory data = abi.encodeCall(
            ITMPTerms.createTask,
            (
                taskConfig(REWARD, DURATION, mode),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                ev,
                t
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    function _submitted(bytes4 mode) internal returns (bytes32 taskId) {
        taskId = _create(mode, noEvaluatorConfig());
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, WORK2)));
    }

    function _deadline(bytes32 taskId) internal view returns (uint256) {
        return market.getTask(taskId).expiryTime + DECISION;
    }

    function _rejectData(bytes32 taskId, address w) internal view returns (bytes memory) {
        return abi.encodeCall(market.rejectSubmission, (taskId, w));
    }

    function _acceptAllData(bytes32 taskId) internal view returns (bytes memory) {
        address[] memory ws = new address[](2);
        ws[0] = worker;
        ws[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        return abi.encodeCall(market.acceptSubmissions, (taskId, ws, shares, new bytes32[](0), 0));
    }

    function _expectRelayRevert(address sender, bytes memory data, bytes4 err) internal {
        vm.expectRevert(err);
        forwarder.relay(address(market), sender, 0, data);
    }

    function _assertLapsedReverts(bytes32 taskId) internal {
        bytes4 lapsed = ITMPCore.DecisionWindowLapsed.selector;
        _expectRelayRevert(requester, _rejectData(taskId, worker), lapsed);
        _expectRelayRevert(requester, abi.encodeCall(market.cancelTask, (taskId, 0)), lapsed);
        vm.expectRevert(lapsed);
        market.refundExpired(taskId, 0);
    }

    function _countSignal(Vm.Log[] memory logs, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != RequesterReputation.selector) continue;
            (bytes32 ev,,,) = abi.decode(logs[i].data, (bytes32, uint256, uint32, bool));
            if (ev == sig) ++n;
        }
    }

    // -------------------------------------------------------------------------
    // Inside the window
    // -------------------------------------------------------------------------

    function test_AcceptAtDeadline_NoLapseSignal() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_deadline(taskId));
        vm.recordLogs();
        _relay(requester, 0, _acceptAllData(taskId));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSignal(logs, keccak256("decision_deadline_lapsed")), 0);
        assertEq(_countSignal(logs, keccak256("completed")), 1);
    }

    function test_RejectInsideWindow_StillBlocksCancelWithSubmissionsExist() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_deadline(taskId));
        _relay(requester, 0, _rejectData(taskId, worker));
        _expectRelayRevert(
            requester, abi.encodeCall(market.cancelTask, (taskId, 0)), ITMPCore.SubmissionsExist.selector
        );
        vm.expectRevert(ITMPCore.SubmissionsExist.selector);
        market.refundExpired(taskId, 0);
    }

    function test_RejectAllInsideWindow_ThenRefundAfterDeadline() public {
        bytes32 taskId = _submitted(TMP_BENCHMARK);
        vm.warp(_deadline(taskId));
        _relay(requester, 0, _rejectData(taskId, worker));
        _relay(requester, 0, _rejectData(taskId, worker2));
        vm.warp(_deadline(taskId) + 30 days);
        uint256 before = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);
        assertEq(usdc.balanceOf(requester) - before, REWARD);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired));
    }

    function test_RejectAllInsideWindow_ThenCancelAfterDeadline() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        _relay(requester, 0, _rejectData(taskId, worker));
        _relay(requester, 0, _rejectData(taskId, worker2));
        vm.warp(_deadline(taskId) + 1);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Cancelled));
    }

    // -------------------------------------------------------------------------
    // After the deadline
    // -------------------------------------------------------------------------

    function test_Lapsed_RejectCancelRefundRevert() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_deadline(taskId) + 1);
        _assertLapsedReverts(taskId);
    }

    function test_Lapsed_Benchmark_RejectCancelRefundRevert() public {
        bytes32 taskId = _submitted(TMP_BENCHMARK);
        vm.warp(_deadline(taskId) + 1);
        _assertLapsedReverts(taskId);
    }

    function test_Lapsed_OnePartlyRejected_StillLapses() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        _relay(requester, 0, _rejectData(taskId, worker));
        vm.warp(_deadline(taskId) + 1);
        _expectRelayRevert(requester, _rejectData(taskId, worker2), ITMPCore.DecisionWindowLapsed.selector);
    }

    function test_Lapsed_NoAutomaticPayout() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_deadline(taskId) + 365 days);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open));
        assertEq(usdc.balanceOf(worker), 0);
        _assertLapsedReverts(taskId);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open));
    }

    function test_Lapsed_AcceptSubmissionsSettlesAndSignals() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_deadline(taskId) + 1);
        vm.recordLogs();
        _relay(requester, 0, _acceptAllData(taskId));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(usdc.balanceOf(worker), 60e6 - 60e6 * FEE_BPS / 10000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countSignal(logs, keccak256("decision_deadline_lapsed")), 1);
        assertEq(_countSignal(logs, keccak256("completed")), 1);
    }

    function test_Lapsed_AcceptSubmissionSignals() public {
        bytes32 taskId = _submitted(TMP_BENCHMARK);
        vm.warp(_deadline(taskId) + 1);
        vm.expectEmit(true, true, false, true, address(market));
        emit RequesterReputation(taskId, requester, keccak256("decision_deadline_lapsed"), REWARD, 2, false);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_NoSubmissions_RefundAfterDeadline() public {
        bytes32 taskId = _create(TMP_BOUNTY, noEvaluatorConfig());
        vm.warp(_deadline(taskId) + 1);
        market.refundExpired(taskId, 0);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired));
    }

    // -------------------------------------------------------------------------
    // Pre-rev025 normalized start
    // -------------------------------------------------------------------------

    function test_PreRev025_WindowRunsFromNormalization() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        DecisionProbeFacet(address(market)).probeWipeDecisionTerms(taskId);
        vm.warp(_deadline(taskId) + 10 days);
        market.normalizeTerms(_ids(taskId));
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + DECISION);
        _relay(requester, 0, _rejectData(taskId, worker));
        vm.warp(start + DECISION + 1);
        _expectRelayRevert(requester, _rejectData(taskId, worker2), ITMPCore.DecisionWindowLapsed.selector);
    }

    function test_PreRev025_FirstReadSeedsClockAndDoesNotLapse() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        DecisionProbeFacet(address(market)).probeWipeDecisionTerms(taskId);
        vm.warp(_deadline(taskId) + 10 days);
        _relay(requester, 0, _rejectData(taskId, worker));
        vm.warp(vm.getBlockTimestamp() + DECISION + 1);
        _expectRelayRevert(requester, _rejectData(taskId, worker2), ITMPCore.DecisionWindowLapsed.selector);
    }

    function _ids(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    // -------------------------------------------------------------------------
    // Out of scope and pause
    // -------------------------------------------------------------------------

    function test_EvaluatorTask_Unaffected() public {
        ITMPCore.TaskEvaluatorConfig memory ev = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
        bytes32 taskId = _create(TMP_BOUNTY, ev);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        vm.warp(market.getTask(taskId).expiryTime + DECISION + 30 days);
        _relay(requester, 0, _rejectData(taskId, worker));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open));
    }

    function test_Pause_BlocksDecisions() public {
        bytes32 taskId = _submitted(TMP_BOUNTY);
        vm.warp(_deadline(taskId));
        vm.prank(owner);
        market.pause();
        bytes4 paused = LibGuards.EnforcedPause.selector;
        _expectRelayRevert(requester, _rejectData(taskId, worker), paused);
        _expectRelayRevert(requester, _acceptAllData(taskId), paused);
        _expectRelayRevert(requester, abi.encodeCall(market.cancelTask, (taskId, 0)), paused);
        vm.expectRevert(paused);
        market.refundExpired(taskId, 0);
    }
}
