// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { TMP_BOUNTY, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev029: the owner's limits on a grant (expiry, modes, reward per task, a budget per period),
///      lowering a cap, and the GrantCommitted event after every draw and refund.
contract ProjectGrantLimitsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal owner = address(0xB0);
    address internal operator = address(0xB1);
    address internal stranger = address(0xC1);

    uint256 internal constant BUDGET = 100e6;
    uint256 internal constant REWARD = 2e6;
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
        usdc.mint(address(forwarder), 1_000e6);
        id = abi.decode(
            _relay(
                owner,
                BUDGET,
                abi.encodeCall(
                    projects.createProject, (address(usdc), BUDGET, uint64(block.timestamp + 30 days), 30 days)
                )
            ),
            (uint256)
        );
        ITMPProject.GrantTerms memory t = ITMPProject.GrantTerms({
            cap: 20e6,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: true,
            revokeRemovesControl: true
        });
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, t)));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _accept() internal {
        bytes32 h = keccak256(abi.encode(projects.getGrant(id, operator).terms));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, h)));
    }

    function _limits(uint64 expiresAt, uint32 mask, uint128 maxReward, uint64 periodSecs, uint128 periodCap)
        internal
        pure
        returns (ITMPProject.GrantLimitsInput memory)
    {
        return ITMPProject.GrantLimitsInput({
            expiresAt: expiresAt,
            allowedModesMask: mask,
            maxRewardPerTask: maxReward,
            periodSecs: periodSecs,
            periodCap: periodCap
        });
    }

    function _set(ITMPProject.GrantLimitsInput memory l) internal {
        _relay(owner, 0, abi.encodeCall(projects.setGrantLimits, (id, operator, l)));
    }

    function _taskCall(uint256 reward, bytes4 mode) internal view returns (bytes memory) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(reward, 7 days, mode),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
    }

    function _task(address who, uint256 reward) internal returns (bytes32) {
        return abi.decode(_relay(who, 0, _taskCall(reward, TMP_BOUNTY)), (bytes32));
    }

    function _cancel(bytes32 taskId) internal {
        _relay(owner, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function _meter() internal view returns (uint64 start, uint128 spent) {
        ITMPProject.GrantLimits memory l = projects.getGrantLimits(id, operator);
        return (l.periodStart, l.periodSpent);
    }

    // -------------------------------------------------------------------------
    // setGrantLimits
    // -------------------------------------------------------------------------

    function test_Limits_DefaultToNone() public {
        _accept();
        ITMPProject.GrantLimits memory l = projects.getGrantLimits(id, operator);
        assertEq(l.expiresAt, 0);
        assertEq(l.allowedModesMask, 0);
        assertEq(l.maxRewardPerTask, 0);
        assertEq(l.periodSecs, 0);
        _task(operator, REWARD);
    }

    function test_SetLimits_EmitsAndStores() public {
        uint64 exp = uint64(block.timestamp + 10 days);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.GrantLimitsSet(id, operator, exp, 3, 5e6, 7 days, 8e6);
        _set(_limits(exp, 3, 5e6, 7 days, 8e6));
        ITMPProject.GrantLimits memory l = projects.getGrantLimits(id, operator);
        assertEq(l.expiresAt, exp);
        assertEq(l.allowedModesMask, 3);
        assertEq(l.maxRewardPerTask, 5e6);
        assertEq(l.periodSecs, 7 days);
        assertEq(l.periodCap, 8e6);
        assertEq(l.periodStart, 0, "the meter starts at the first draw");
    }

    function test_PendingGrant_LimitsAreEditedFreely() public {
        _set(_limits(0, 1, 1e6, 1 days, 2e6));
        _set(_limits(0, 0, 0, 0, 0));
        _set(_limits(uint64(block.timestamp + 1 days), 31, 9e6, 30 days, 9e6));
        assertEq(projects.getGrantLimits(id, operator).periodCap, 9e6);
    }

    function test_AcceptedGrant_OwnerMayTightenAndLoosen() public {
        _accept();
        _set(_limits(uint64(block.timestamp + 5 days), 1, 3e6, 1 days, 3e6));
        // Loosen: the operator is given more room, which needs no agreement from it.
        _set(_limits(uint64(block.timestamp + 20 days), 0, 0, 7 days, 15e6));
        ITMPProject.GrantLimits memory l = projects.getGrantLimits(id, operator);
        assertEq(l.allowedModesMask, 0);
        assertEq(l.periodCap, 15e6);
        assertTrue(projects.getGrant(id, operator).accepted, "still accepted");
    }

    function test_RevertWhen_Limits_NotOwnerMissingOrRevoked() public {
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(stranger, 0, abi.encodeCall(projects.setGrantLimits, (id, operator, _limits(0, 0, 0, 0, 0))));
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _relay(operator, 0, abi.encodeCall(projects.setGrantLimits, (id, operator, _limits(0, 0, 0, 0, 0))));
        vm.expectRevert(ITMPProject.GrantNotFound.selector);
        _relay(owner, 0, abi.encodeCall(projects.setGrantLimits, (id, stranger, _limits(0, 0, 0, 0, 0))));
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _relay(owner, 0, abi.encodeCall(projects.setGrantLimits, (id, operator, _limits(0, 0, 0, 0, 0))));
    }

    function test_RevertWhen_Limits_Malformed() public {
        bytes memory bad = abi.encodeWithSelector(ITMPProject.InvalidGrantLimits.selector);
        // An unknown mode bit.
        vm.expectRevert(bad);
        _set(_limits(0, 32, 0, 0, 0));
        vm.expectRevert(bad);
        _set(_limits(0, uint32(1) << 31, 0, 0, 0));
        // A period without a cap, and a cap without a period.
        vm.expectRevert(bad);
        _set(_limits(0, 0, 0, 1 days, 0));
        vm.expectRevert(bad);
        _set(_limits(0, 0, 0, 0, 1e6));
        // An expiry that has passed.
        vm.expectRevert(bad);
        _set(_limits(uint64(block.timestamp), 0, 0, 0, 0));
    }

    // -------------------------------------------------------------------------
    // Expiry
    // -------------------------------------------------------------------------

    function test_Expiry_OperatorCannotDrawAfterItButOwnerCan() public {
        _accept();
        uint64 exp = uint64(block.timestamp + 3 days);
        _set(_limits(exp, 0, 0, 0, 0));
        bytes32 t = _task(operator, REWARD);
        vm.warp(exp);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantExpired.selector, exp));
        _relay(operator, 0, _taskCall(REWARD, TMP_BOUNTY));
        // A top-up by the operator is a draw too.
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantExpired.selector, exp));
        _relay(operator, 0, abi.encodeCall(market.updateTask, (t, 3e6, 0, 0, 0)));
        // The owner's own task is unaffected, and so is the owner's top-up of the operator's task.
        _task(owner, REWARD);
        _relay(owner, 0, abi.encodeCall(market.updateTask, (t, 3e6, 0, 0, 0)));
    }

    /// @dev A task created at the cap, claimed with a stake and forfeited: the forfeited stake is
    ///      the worker's money, not a draw, so it neither raises what the task holds nor gives the
    ///      operator room to top up past maxRewardPerTask.
    function test_MaxReward_ForfeitedStakeGivesNoRoomToTopUp() public {
        _accept();
        _set(_limits(0, 0, uint128(REWARD), 0, 0));
        ITMPCore.TaskTerms memory terms;
        terms.version = 2;
        terms.penaltyTo = ITMPCore.PenaltyTo.Requester;
        bytes32 t = abi.decode(
            _relay(
                operator,
                0,
                abi.encodeCall(
                    projects.createProjectTask,
                    (
                        id,
                        taskConfig(REWARD, 7 days, TMP_CLAIM),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        terms,
                        address(0)
                    )
                )
            ),
            (bytes32)
        );
        address claimer = address(0xC2);
        uint256 stake = 1e6;
        _relay(claimer, stake, abi.encodeCall(market.claimTask, (t, stake)));
        vm.warp(market.getTask(t).expiryTime + 1);
        _relay(owner, 0, abi.encodeCall(market.forfeitAndReopen, (t)));
        assertEq(uint8(market.getTask(t).status), uint8(ITMPCore.TaskStatus.Open));

        uint256 availableBefore = projects.getProject(id).available;
        uint256 committedBefore = projects.getGrant(id, operator).committed;
        assertEq(committedBefore, REWARD, "the stake is not part of the operator's commitment");

        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantRewardTooHigh.selector, REWARD, REWARD + 1));
        _relay(operator, 0, abi.encodeCall(market.updateTask, (t, REWARD + 1, 0, 0, 0)));

        assertEq(projects.getProject(id).available, availableBefore, "the pool is untouched by the refused top-up");
        assertEq(projects.getGrant(id, operator).committed, committedBefore);
    }

    function test_Expiry_ExtendedByTheOwnerLetsTheOperatorDrawAgain() public {
        _accept();
        uint64 exp = uint64(block.timestamp + 1 days);
        _set(_limits(exp, 0, 0, 0, 0));
        vm.warp(exp + 1);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantExpired.selector, exp));
        _relay(operator, 0, _taskCall(REWARD, TMP_BOUNTY));
        _set(_limits(uint64(block.timestamp + 5 days), 0, 0, 0, 0));
        _task(operator, REWARD);
    }

    // -------------------------------------------------------------------------
    // Modes
    // -------------------------------------------------------------------------

    function test_Modes_MaskAllowsOnlyTheNamedModes() public {
        _accept();
        _set(_limits(0, 1, 0, 0, 0)); // bounty only
        _task(operator, REWARD);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantModeNotAllowed.selector, TMP_CLAIM));
        _relay(operator, 0, _taskCall(REWARD, TMP_CLAIM));
        _set(_limits(0, 3, 0, 0, 0)); // bounty and claim
        _relay(operator, 0, _taskCall(REWARD, TMP_CLAIM));
    }

    function test_Modes_AnUnknownTaskModeIsRefusedUnderAMask() public {
        _accept();
        bytes4 unknown = bytes4(0xdeadbeef);
        _set(_limits(0, 31, 0, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantModeNotAllowed.selector, unknown));
        _relay(operator, 0, _taskCall(REWARD, unknown));
    }

    function test_Modes_TheOwnerIsNotBoundByTheMask() public {
        _accept();
        _set(_limits(0, 1, 0, 0, 0));
        _relay(owner, 0, _taskCall(REWARD, TMP_CLAIM));
    }

    // -------------------------------------------------------------------------
    // Max reward per task
    // -------------------------------------------------------------------------

    function test_MaxReward_RefusesABiggerTaskAndATopUpPastIt() public {
        _accept();
        _set(_limits(0, 0, 3e6, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantRewardTooHigh.selector, 3e6, 3e6 + 1));
        _relay(operator, 0, _taskCall(3e6 + 1, TMP_BOUNTY));
        bytes32 t = _task(operator, 3e6);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantRewardTooHigh.selector, 3e6, 4e6));
        _relay(operator, 0, abi.encodeCall(market.updateTask, (t, 4e6, 0, 0, 0)));
        // The owner may top the task up past it.
        _relay(owner, 0, abi.encodeCall(market.updateTask, (t, 4e6, 0, 0, 0)));
    }

    // -------------------------------------------------------------------------
    // Period budget
    // -------------------------------------------------------------------------

    function test_Period_BudgetBoundsTheOperatorWithinThePeriod() public {
        _accept();
        _set(_limits(0, 0, 0, 7 days, 5e6));
        _task(operator, 3e6);
        (uint64 start, uint128 spent) = _meter();
        assertEq(start, block.timestamp);
        assertEq(spent, 3e6);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantPeriodCapExceeded.selector, 2e6, 3e6));
        _relay(operator, 0, _taskCall(3e6, TMP_BOUNTY));
        _task(operator, 2e6);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantPeriodCapExceeded.selector, 0, 1));
        _relay(operator, 0, _taskCall(1, TMP_BOUNTY));
    }

    function test_Period_RollsOverAfterPeriodSecs() public {
        _accept();
        _set(_limits(0, 0, 0, 7 days, 5e6));
        _task(operator, 5e6);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantPeriodCapExceeded.selector, 0, 1e6));
        _relay(operator, 0, _taskCall(1e6, TMP_BOUNTY));
        vm.warp(block.timestamp + 1);
        _task(operator, 4e6);
        (uint64 start, uint128 spent) = _meter();
        assertEq(start, block.timestamp, "a new period starts at the first draw after the last ended");
        assertEq(spent, 4e6, "and counts only that draw");
    }

    function test_Period_RefundInsideThePeriodGivesTheBudgetBack() public {
        _accept();
        _set(_limits(0, 0, 0, 7 days, 5e6));
        bytes32 t = _task(operator, 5e6);
        _cancel(t);
        (, uint128 spent) = _meter();
        assertEq(spent, 0, "the refund reduced the period's spend");
        assertEq(projects.getGrant(id, operator).committed, 0);
        _task(operator, 5e6);
    }

    function test_Period_RefundFloorsAtZeroAndDoesNotReachAnEarlierPeriod() public {
        _accept();
        _set(_limits(0, 0, 0, 7 days, 5e6));
        bytes32 first = _task(operator, 4e6);
        vm.warp(block.timestamp + 7 days);
        // The period that held the draw is over: its refund leaves the next period's meter alone.
        _cancel(first);
        (, uint128 stale) = _meter();
        assertEq(stale, 4e6, "the ended period's meter is untouched until the next draw");
        _task(operator, 1e6);
        (, uint128 spent) = _meter();
        assertEq(spent, 1e6, "the next period starts clean");
        // A refund larger than the current period's spend floors at zero.
        bytes32 big = _task(owner, 1e6); // an owner task: no operator, no meter
        _cancel(big);
        (, spent) = _meter();
        assertEq(spent, 1e6, "an owner task never touches the meter");
    }

    function test_Period_OwnerTopUpOfAnOperatorTaskCountsButIsNeverRefused() public {
        _accept();
        _set(_limits(0, 0, 0, 7 days, 5e6));
        bytes32 t = _task(operator, 5e6);
        _relay(owner, 0, abi.encodeCall(market.updateTask, (t, 6e6, 0, 0, 0)));
        (, uint128 spent) = _meter();
        assertEq(spent, 6e6, "counted, as committed counts it");
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantPeriodCapExceeded.selector, 0, 1));
        _relay(operator, 0, _taskCall(1, TMP_BOUNTY));
    }

    function test_Period_ChangingThePeriodLengthRestartsTheMeter() public {
        _accept();
        _set(_limits(0, 0, 0, 7 days, 5e6));
        _task(operator, 5e6);
        _set(_limits(0, 0, 0, 1 days, 5e6));
        (uint64 start, uint128 spent) = _meter();
        assertEq(start, 0);
        assertEq(spent, 0);
        // Same length again keeps the meter.
        _task(operator, 2e6);
        _set(_limits(0, 0, 0, 1 days, 6e6));
        (, spent) = _meter();
        assertEq(spent, 2e6);
    }

    function test_Period_LifetimeCapStillApplies() public {
        _accept();
        _set(_limits(0, 0, 0, 1 days, 15e6));
        _task(operator, 15e6);
        vm.warp(block.timestamp + 1 days);
        // The period is fresh, but only 5e6 of the 20e6 lifetime cap is left.
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.OperatorCapExceeded.selector, 5e6, 6e6));
        _relay(operator, 0, _taskCall(6e6, TMP_BOUNTY));
        _task(operator, 5e6);
    }

    // -------------------------------------------------------------------------
    // lowerGrantCap
    // -------------------------------------------------------------------------

    function _lower(address who, address op, uint256 cap) internal {
        _relay(who, 0, abi.encodeCall(projects.lowerGrantCap, (id, op, cap)));
    }

    function test_LowerCap_AcceptedAndPending() public {
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.GrantCapLowered(id, operator, 20e6, 12e6);
        _lower(owner, operator, 12e6);
        assertEq(projects.getGrant(id, operator).terms.cap, 12e6);
        _accept();
        _task(operator, 5e6);
        _lower(owner, operator, 5e6); // exactly committed is allowed
        assertEq(projects.getGrant(id, operator).terms.cap, 5e6);
        assertTrue(projects.getGrant(id, operator).accepted, "still accepted");
    }

    function test_RevertWhen_LowerCap_BelowCommitted() public {
        _accept();
        _task(operator, 6e6);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapBelowCommitted.selector, 5e6, 6e6));
        _lower(owner, operator, 5e6);
    }

    function test_RevertWhen_LowerCap_NotLoweredOrNotOwnerOrGone() public {
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapNotLowered.selector, 20e6, 20e6));
        _lower(owner, operator, 20e6);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapNotLowered.selector, 20e6, 25e6));
        _lower(owner, operator, 25e6);
        vm.expectRevert(abi.encodeWithSelector(ITMPProject.GrantCapNotLowered.selector, 20e6, 0));
        _lower(owner, operator, 0);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        _lower(stranger, operator, 5e6);
        vm.expectRevert(ITMPProject.GrantNotFound.selector);
        _lower(owner, stranger, 5e6);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        vm.expectRevert(ITMPProject.GrantRevoked.selector);
        _lower(owner, operator, 5e6);
    }

    function test_LowerCap_AGrantWithNoCapTakesAnyNonzeroCap() public {
        address op2 = address(0xB3);
        ITMPProject.GrantTerms memory t = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: true,
            revokeRemovesControl: true
        });
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, op2, t)));
        _lower(owner, op2, 7e6);
        assertEq(projects.getGrant(id, op2).terms.cap, 7e6);
    }

    // -------------------------------------------------------------------------
    // GrantCommitted
    // -------------------------------------------------------------------------

    function test_GrantCommitted_EmittedAfterEveryDrawAndRefund() public {
        _accept();
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.GrantCommitted(id, operator, 2e6);
        bytes32 t = _task(operator, 2e6);

        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.GrantCommitted(id, operator, 3e6);
        _relay(operator, 0, abi.encodeCall(market.updateTask, (t, 3e6, 0, 0, 0)));

        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.GrantCommitted(id, operator, 0);
        _cancel(t);
    }

    function test_GrantCommitted_NotEmittedForAnOwnerTask() public {
        vm.recordLogs();
        _task(owner, REWARD);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ITMPProject.GrantCommitted.selector);
        }
    }

    function test_Regrant_KeepsTheLimitsAndTheMeter() public {
        _accept();
        _set(_limits(0, 1, 0, 7 days, 8e6));
        _task(operator, 3e6);
        _relay(owner, 0, abi.encodeCall(projects.revokeOperator, (id, operator)));
        ITMPProject.GrantTerms memory t = ITMPProject.GrantTerms({
            cap: 20e6,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: true,
            revokeRemovesControl: true
        });
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, t)));
        ITMPProject.GrantLimits memory l = projects.getGrantLimits(id, operator);
        assertEq(l.allowedModesMask, 1);
        assertEq(l.periodSpent, 3e6);
    }
}
