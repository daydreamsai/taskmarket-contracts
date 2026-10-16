// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { LibGuards } from "../src/libraries/LibGuards.sol";
import { TMP_CLAIM, TMP_PITCH } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev025 releaseClaim: the claimed worker gives up a Claim task before delivery and expiry,
///      paying a stake penalty that is zero through the grace period and linear to the full stake
///      at expiry.
contract ReleaseClaimTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC1);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant DURATION = 7 days;
    bytes32 internal constant WORK = keccak256("work");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _expectRelayRevert(address sender, bytes memory data, bytes4 err) internal {
        vm.expectRevert(err);
        forwarder.relay(address(market), sender, 0, data);
    }

    function _terms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 1;
        t.stakeRequired = true;
        t.stakeBps = 1000;
    }

    function _create(bytes4 mode, ITMPCore.TaskTerms memory t, address hook) internal returns (bytes32) {
        address[] memory hooks = new address[](hook == address(0) ? 0 : 1);
        if (hook != address(0)) hooks[0] = hook;
        bytes memory data = abi.encodeCall(
            ITMPTerms.createTask,
            (
                taskConfig(REWARD, DURATION, mode, DURATION, DURATION, bytes4(0)),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    function _claimed(ITMPCore.TaskTerms memory t) internal returns (bytes32 taskId) {
        taskId = _create(TMP_CLAIM, t, address(0));
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
    }

    function _release(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));
    }

    function _expected(uint256 claimedAt, uint256 expiry, uint256 grace) internal view returns (uint256) {
        uint256 graceEnd = claimedAt + ((expiry - claimedAt) * grace) / 10000;
        uint256 nowTs = vm.getBlockTimestamp();
        if (nowTs <= graceEnd) return 0;
        return (STAKE * (nowTs - graceEnd)) / (expiry - graceEnd);
    }

    /// @dev Releases at `at` seconds after the claim and checks every balance and the event.
    function _releaseAt(ITMPCore.TaskTerms memory t, uint256 at, uint256 expectedPenalty) internal returns (bytes32) {
        bytes32 taskId = _claimed(t);
        uint256 claimedAt = vm.getBlockTimestamp();
        vm.warp(claimedAt + at);

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 marketBefore = usdc.balanceOf(address(market));
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.ClaimReleased(taskId, worker, expectedPenalty, STAKE - expectedPenalty);
        _release(taskId);

        assertEq(usdc.balanceOf(worker), STAKE - expectedPenalty, "worker gets the remainder");
        assertEq(usdc.balanceOf(requester) - reqBefore, expectedPenalty, "requester gets the penalty");
        assertEq(marketBefore - usdc.balanceOf(address(market)), STAKE, "whole stake leaves; reward stays");
        assertEq(usdc.balanceOf(address(market)), REWARD, "escrow holds the reward");
        return taskId;
    }

    function test_Release_InGrace_ZeroPenalty() public {
        uint256 graceSecs = (DURATION * 1000) / 10000;
        _releaseAt(_terms(), graceSecs, 0);
    }

    function test_Release_MidSpan_ExactLinear() public {
        uint256 graceSecs = (DURATION * 1000) / 10000;
        uint256 rest = DURATION - graceSecs;
        _releaseAt(_terms(), graceSecs + rest / 2, STAKE / 2);
    }

    function test_Release_OneSecondAfterGrace_RoundsDown() public {
        uint256 graceSecs = (DURATION * 1000) / 10000;
        uint256 rest = DURATION - graceSecs;
        // 10e6 / 544320 = 18.37..., floored.
        assertEq(rest, 544320);
        _releaseAt(_terms(), graceSecs + 1, 18);
    }

    function test_Release_JustBeforeExpiry() public {
        uint256 rest = DURATION - (DURATION * 1000) / 10000;
        uint256 penalty = (STAKE * (rest - 1)) / rest;
        assertEq(penalty, STAKE - 19);
        _releaseAt(_terms(), DURATION - 1, penalty);
    }

    function test_Release_CustomGrace_MatchesFormula() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.releaseGraceBps = 2501; // 25%
        bytes32 taskId = _claimed(t);
        uint256 claimedAt = vm.getBlockTimestamp();
        uint256 expiry = market.getTask(taskId).expiryTime;
        vm.warp(claimedAt + 3 days + 7);
        uint256 penalty = _expected(claimedAt, expiry, 2500);
        assertGt(penalty, 0);
        _release(taskId);
        assertEq(usdc.balanceOf(worker), STAKE - penalty);
    }

    function test_Release_NoGrace_PenaltyFromClaim() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.releaseGraceBps = 1; // stored as grace + 1: no grace
        _releaseAt(t, DURATION / 2, STAKE / 2);
    }

    function test_Release_FullGrace_ZeroPenaltyBeforeExpiry() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.releaseGraceBps = 10001;
        _releaseAt(t, DURATION - 1, 0);
    }

    function test_Release_AfterExpiry_Reverts() public {
        bytes32 taskId = _claimed(_terms());
        vm.warp(market.getTask(taskId).expiryTime);
        _expectRelayRevert(worker, abi.encodeCall(market.releaseClaim, (taskId)), ITMPCore.TaskIsExpired.selector);
    }

    function test_Release_AfterDelivery_Reverts() public {
        bytes32 taskId = _claimed(_terms());
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _expectRelayRevert(
            worker, abi.encodeCall(market.releaseClaim, (taskId)), ITMPCore.DeliverableAlreadySet.selector
        );
    }

    function test_Release_DuringRevision_Reverts() public {
        bytes32 taskId = _claimed(_terms());
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(requester, 0, abi.encodeCall(market.requestRevision, (taskId)));
        _expectRelayRevert(
            worker, abi.encodeCall(market.releaseClaim, (taskId)), ITMPCore.DeliverableAlreadySet.selector
        );
    }

    function test_Release_Disallowed_Reverts() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Disallowed;
        bytes32 taskId = _claimed(t);
        _expectRelayRevert(worker, abi.encodeCall(market.releaseClaim, (taskId)), ITMPCore.ReleaseNotAllowed.selector);
    }

    function test_Release_ExplicitlyAllowed() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Allowed;
        _releaseAt(t, 1, 0);
    }

    function test_Release_NotWorker_Reverts() public {
        bytes32 taskId = _claimed(_terms());
        _expectRelayRevert(requester, abi.encodeCall(market.releaseClaim, (taskId)), ITMPCore.NotWorker.selector);
    }

    function test_Release_NotClaimed_Reverts() public {
        bytes32 taskId = _create(TMP_CLAIM, _terms(), address(0));
        _expectRelayRevert(worker, abi.encodeCall(market.releaseClaim, (taskId)), ITMPCore.TaskNotClaimed.selector);
    }

    function test_Release_NotClaimMode_Reverts() public {
        bytes32 taskId = _create(TMP_PITCH, _terms(), address(0));
        _expectRelayRevert(worker, abi.encodeCall(market.releaseClaim, (taskId)), ITMPCore.NotAClaimTask.selector);
    }

    function test_Release_Paused_Reverts() public {
        bytes32 taskId = _claimed(_terms());
        vm.prank(owner);
        market.pause();
        _expectRelayRevert(worker, abi.encodeCall(market.releaseClaim, (taskId)), LibGuards.EnforcedPause.selector);
    }

    function test_Release_NoStake() public {
        ITMPCore.TaskTerms memory t;
        t.version = 1;
        bytes32 taskId = _create(TMP_CLAIM, t, address(0));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        vm.warp(vm.getBlockTimestamp() + DURATION - 1);
        uint256 reqBefore = usdc.balanceOf(requester);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.ClaimReleased(taskId, worker, 0, 0);
        _release(taskId);
        assertEq(usdc.balanceOf(worker), 0);
        assertEq(usdc.balanceOf(requester), reqBefore);
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Open));
    }

    function test_Release_PenaltyToProtocol() public {
        ITMPCore.TaskTerms memory t = _terms();
        t.penaltyTo = ITMPCore.PenaltyTo.Protocol;
        t.releaseGraceBps = 1;
        bytes32 taskId = _claimed(t);
        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 feesBefore = market.totalFeesCollected();
        _release(taskId);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, STAKE / 2, "fee recipient gets the penalty");
        assertEq(market.totalFeesCollected() - feesBefore, STAKE / 2, "booked as protocol fees");
        assertEq(usdc.balanceOf(requester), reqBefore, "requester gets nothing");
        assertEq(usdc.balanceOf(worker), STAKE / 2, "worker gets the remainder");
    }

    function test_Release_ReopensWithExtension_WorkerCannotReclaim() public {
        bytes32 taskId = _claimed(_terms());
        uint256 oldExpiry = market.getTask(taskId).expiryTime;
        vm.warp(oldExpiry - 1 hours);
        vm.expectEmit(true, false, false, false, address(market));
        emit ITMPCore.TaskReopened(taskId);
        _release(taskId);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open));
        assertEq(task.worker, address(0));
        assertEq(task.stakeAmount, 0);
        assertEq(task.expiryTime, block.timestamp + 72 hours, "extended by the default reopen extension");
        assertTrue(RegistryFacet(address(market)).taskRejectedWorkers(taskId, worker), "worker barred");

        vm.expectRevert(ITMPCore.SubmissionAlreadyRejected.selector);
        forwarder.relay(address(market), worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));

        _relay(worker2, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
        assertEq(market.getTask(taskId).worker, worker2, "another worker can claim");
    }

    function test_Release_EarlyKeepsLaterExpiry() public {
        bytes32 taskId = _claimed(_terms());
        uint256 oldExpiry = market.getTask(taskId).expiryTime;
        _release(taskId);
        assertEq(market.getTask(taskId).expiryTime, oldExpiry, "expiry already beyond the extension");
    }

    function test_Release_DispatchesOnForfeitHook() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _create(TMP_CLAIM, _terms(), address(hook));
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
        _release(taskId);
        assertEq(hook.onForfeitCalls(), 1);
    }
}
