// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_BOUNTY, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev030 settlement fixes: the dispute window outlives a clamped project expiry, the
///      acting-party guards hold at use time, a promoted owner tops up and leaves its own tasks, a
///      transforming hook's awards drive the self-award signals, and the winner cap covers every
///      mode.
contract Rev030SettlementFixesTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    FundingPool internal mockPool;

    address internal admin = address(0xA0);
    address internal owner = address(0xB0);
    address internal operator = address(0xB1);
    address internal requester = address(0xB2);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC1);
    address internal stranger = address(0xC2);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);

    uint256 internal constant BUDGET = 10e6;
    uint256 internal constant REWARD = 4e6;
    bytes32 internal constant WORK = keccak256("work");

    uint256 internal t0;
    uint64 internal endsAt;
    uint256 internal pid;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        market = deployDiamond(admin, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        projects = ITMPProject(address(market));
        mockPool = initMockPool(address(market), admin);
        usdc.mint(address(forwarder), 1_000_000e6);
        usdc.mint(worker, 100e6);
        t0 = block.timestamp;
        endsAt = uint64(t0 + 6 days);
        pid = abi.decode(
            _relay(owner, BUDGET, abi.encodeCall(projects.createProject, (address(usdc), BUDGET, endsAt, 12 hours))),
            (uint256)
        );
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _ev(address ev, address dr) internal pure returns (ITMPCore.TaskEvaluatorConfig memory c) {
        c.evaluator = ev;
        c.evaluationWindow = 2 days;
        c.appealWindow = 3 days;
        c.disputeResolver = dr;
    }

    function _pTask(address who, uint256 duration, ITMPCore.TaskEvaluatorConfig memory ev, ITMPCore.TaskTerms memory t)
        internal
        returns (bytes32)
    {
        return abi.decode(
            _relay(
                who,
                0,
                abi.encodeCall(
                    projects.createProjectTask,
                    (
                        pid,
                        taskConfig(REWARD, duration, TMP_CLAIM),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        ev,
                        t,
                        address(0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _v2() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 2;
    }

    function _transferOwner(address to) internal {
        _relay(owner, 0, abi.encodeCall(projects.proposeProjectOwner, (pid, to)));
        _relay(to, 0, abi.encodeCall(projects.acceptProjectOwner, (pid)));
    }

    function _awards(address to, uint256 amount) internal pure returns (ITMPCore.Award[] memory a) {
        a = new ITMPCore.Award[](1);
        a[0] = ITMPCore.Award({ worker: to, amount: amount, rank: 1 });
    }

    function _evaluate(bytes32 taskId) internal {
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate,
                (taskId, ITMPCore.VerdictType.APPROVE, uint16(9000), uint16(9000), WORK, _awards(worker, REWARD))
            )
        );
    }

    /// @dev A project Claim task delivered at day 2 and evaluated at once; the appeal window runs
    ///      to day 5, the task's expiry.
    function _evaluatedProjectTask() internal returns (bytes32 taskId) {
        taskId = _pTask(owner, 5 days, _ev(evaluator, resolver), _v2());
        vm.warp(t0 + 2 days);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _evaluate(taskId);
    }

    /// @dev Appealed late in the window: the resolution window (72h) would end on day 7.9, but a
    ///      project task's expiry is held to the project's latest expiry, day 6.5.
    function _disputedProjectTask() internal returns (bytes32 taskId) {
        taskId = _evaluatedProjectTask();
        vm.warp(t0 + 4 days + 22 hours);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Disputed));
        assertEq(market.getTask(taskId).expiryTime, uint256(endsAt) + 12 hours, "expiry clamped to the project");
    }

    // -------------------------------------------------------------------------
    // The dispute window outlives a clamped project expiry
    // -------------------------------------------------------------------------

    function test_Dispute_RefundExpiredWaitsForTheResolutionWindow() public {
        bytes32 taskId = _disputedProjectTask();
        uint256 resolveBy = block.timestamp + 72 hours;
        vm.warp(uint256(endsAt) + 12 hours + 1);
        vm.expectRevert(ITMPCore.DisputeWindowStillOpen.selector);
        vm.prank(stranger);
        market.refundExpired(taskId, 0);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Disputed), "still disputed");

        // The resolver can still rule inside the window.
        vm.warp(resolveBy);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, _awards(worker, REWARD / 2));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_Dispute_LapsesOnceTheResolutionWindowEnds() public {
        bytes32 taskId = _disputedProjectTask();
        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(stranger);
        market.refundExpired(taskId, 0);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted), "verdict finalized");
    }

    // -------------------------------------------------------------------------
    // Acting-party guards at use time
    // -------------------------------------------------------------------------

    function test_Evaluate_RefusedForAnEvaluatorWhoBecameTheOwner() public {
        bytes32 taskId = _pTask(owner, 5 days, _ev(evaluator, resolver), _v2());
        vm.warp(t0 + 1 days);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _transferOwner(evaluator);
        vm.expectRevert(ITMPCore.EvaluatorCannotBeRequester.selector);
        _evaluate(taskId);
    }

    function test_ResolveDispute_RefusedForAResolverWhoBecameTheOwner() public {
        bytes32 taskId = _disputedProjectTask();
        _transferOwner(resolver);
        vm.expectRevert(ITMPCore.DisputeResolverCannotBeRequester.selector);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, _awards(worker, REWARD / 2));
    }

    function test_Appeal_RefusedForAWorkerWhoBecameTheOwner() public {
        bytes32 taskId = _evaluatedProjectTask();
        _transferOwner(worker);
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
    }

    // -------------------------------------------------------------------------
    // A promoted owner tops up its own operator-created task
    // -------------------------------------------------------------------------

    function test_PromotedOwner_TopsUpItsOwnOperatorCreatedTask() public {
        ITMPProject.GrantTerms memory gt = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Operator,
            ownerOverride: false,
            revokeRemovesControl: false
        });
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (pid, operator, gt)));
        _relay(
            operator,
            0,
            abi.encodeCall(projects.acceptGrant, (pid, keccak256(abi.encode(projects.getGrant(pid, operator).terms))))
        );
        bytes32 taskId = _pTask(operator, 5 days, noEvaluatorConfig(), _v2());
        _transferOwner(operator);
        assertTrue(projects.getGrant(pid, operator).revoked, "the promotion revoked the old grant");

        uint256 drawnBefore = projects.getProject(pid).available;
        // Assigning an evaluator with a stake draws the stake from the pool, as a top-up does.
        _relay(
            operator, 0, abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 1e6, 0, 2 days, 1 days, resolver))
        );
        assertEq(projects.getProject(pid).available, drawnBefore - 1e6, "the stake came from the pool");
    }

    // -------------------------------------------------------------------------
    // A worker mid-claim who becomes the owner can leave without a penalty
    // -------------------------------------------------------------------------

    function test_ReleaseClaim_ActingPartyWorkerLeavesWithoutPenalty() public {
        ITMPCore.TaskTerms memory t = _v2();
        t.stakeRequired = true;
        t.stakeBps = 1000;
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Disallowed;
        bytes32 taskId = _pTask(owner, 5 days, noEvaluatorConfig(), t);
        _relay(worker, REWARD / 10, abi.encodeCall(market.claimTask, (taskId, REWARD / 10)));
        _transferOwner(worker);

        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));

        // Late in the claim the penalty would be most of the stake.
        vm.warp(t0 + 4 days + 12 hours);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.ClaimReleased(taskId, worker, 0, REWARD / 10);
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open));
        assertEq(usdc.balanceOf(worker), 100e6 + REWARD / 10, "the whole stake came back");
    }

    // -------------------------------------------------------------------------
    // Self-award signals follow the awards a transforming hook paid
    // -------------------------------------------------------------------------

    function test_Accept_SelfAwardFollowsTheAwardsPaid() public {
        MockTaskHookV2 h = new MockTaskHookV2(address(market), (uint32(1) << 13) | (uint32(1) << 26));
        address[] memory hooks = new address[](1);
        hooks[0] = address(h);
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, 7 days, TMP_BOUNTY),
                        ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(requester, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        // The hook pays the whole reward to the requester's own submission instead of the accepted worker.
        h.setResult(_awards(requester, REWARD), 0, false);

        vm.expectEmit(true, true, true, true, address(market));
        emit ITMPCore.SelfAward(taskId, requester, requester);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.RequesterReputation(taskId, requester, keccak256("completed"), REWARD, 2, true);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }

    // -------------------------------------------------------------------------
    // The winner cap covers every mode
    // -------------------------------------------------------------------------

    function test_Evaluate_WinnerCapAppliesToAClaimTask() public {
        ITMPCore.TaskEvaluatorConfig memory ev = _ev(evaluator, address(0));
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, 7 days, TMP_CLAIM),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        ev,
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        ITMPCore.Award[] memory many = new ITMPCore.Award[](51);
        many[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        vm.expectRevert(ITMPCore.TooManyWinners.selector);
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate, (taskId, ITMPCore.VerdictType.APPROVE, uint16(9000), uint16(9000), WORK, many)
            )
        );
    }
}
