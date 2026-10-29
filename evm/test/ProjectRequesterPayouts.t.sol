// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { TMP_BOUNTY, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev027: every payout owed to a project task's requester goes through LibProject.payRequester.
///      The tasks here are created by an operator that is the requester of record, so a payout that
///      skipped payRequester would land in the operator's wallet. Each test asserts the money came
///      back to the project's available budget while it is open (or to the backers' pot once it is
///      closed or past its end date), the operator's wallet is untouched and its committed cap is
///      released.
///      Covers the payouts Project.t.sol and ProjectGrants.t.sol do not: the evaluator fee refunded
///      when a dispute overturns the verdict, the evaluator reject refund, the updateTask reward
///      decrease, the acceptSubmissions split remainder and a worker-stake penalty to the requester.
///      ProjectPayRequesterScan.t.sol guards the source against a new direct transfer.
contract ProjectRequesterPayoutsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    ITMPFundingPool internal pools;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal owner = address(0xB0);
    address internal operator = address(0xB1);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC2);
    address internal evaluator = address(0xD0);
    address internal resolver = address(0xE0);

    uint256 internal constant BUDGET = 100e6;
    uint256 internal constant REWARD = 20e6;
    uint16 internal constant EVAL_FEE_BPS = 1000;
    uint256 internal constant EVAL_FEE = (REWARD * EVAL_FEE_BPS) / 10000;
    uint256 internal constant STAKE = 1e6;
    uint256 internal constant DURATION = 7 days;
    uint64 internal constant LIFETIME = 30 days;
    bytes32 internal constant WORK = keccak256("work");

    uint256 internal id;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        market = deployDiamond(admin, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        projects = ITMPProject(address(market));
        pools = ITMPFundingPool(address(market));
        usdc.mint(address(forwarder), 1_000_000e6);

        uint64 endsAt = uint64(block.timestamp) + LIFETIME;
        id = abi.decode(
            _relay(owner, BUDGET, abi.encodeCall(projects.createProject, (address(usdc), BUDGET, endsAt, 30 days))),
            (uint256)
        );
        ITMPProject.GrantTerms memory terms = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Operator,
            ownerOverride: true,
            revokeRemovesControl: true
        });
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, terms)));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id)));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _evalConfig() internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: EVAL_FEE_BPS,
            evaluationWindow: 2 days,
            appealWindow: 1 days,
            disputeResolver: resolver
        });
    }

    function _opTask(
        ITMPCore.TaskConfig memory cfg,
        ITMPCore.TaskEvaluatorConfig memory ev,
        ITMPCore.TaskTerms memory t
    ) internal returns (bytes32 taskId) {
        bytes memory data = abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                cfg,
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                ev,
                t,
                address(0)
            )
        );
        taskId = abi.decode(_relay(operator, 0, data), (bytes32));
        assertEq(market.getTask(taskId).requester, operator, "the operator is the requester of record");
    }

    function _v2Terms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 2;
    }

    function _award(uint256 amount) internal view returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: amount, rank: 1 });
    }

    /// @dev A bounty with an evaluator fee, evaluated and appealed into a dispute.
    function _disputed(ITMPCore.VerdictType verdict, uint256 award) internal returns (bytes32 taskId) {
        taskId = _opTask(taskConfig(REWARD, DURATION, TMP_BOUNTY), _evalConfig(), _v2Terms());
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        ITMPCore.Award[] memory awards = award == 0 ? new ITMPCore.Award[](0) : _award(award);
        _relay(evaluator, 0, abi.encodeCall(market.evaluate, (taskId, verdict, 900, 1000, bytes32(0), awards)));
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Disputed));
    }

    function _available() internal view returns (uint256) {
        return projects.getProject(id).available;
    }

    function _committed() internal view returns (uint256) {
        return projects.getGrant(id, operator).committed;
    }

    /// @dev Nothing reached the operator and the diamond holds exactly what it owes.
    function _assertRouted() internal view {
        assertEq(usdc.balanceOf(operator), 0, "nothing reached the operator's wallet");
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities(), "balance equals liabilities");
    }

    // -------------------------------------------------------------------------
    // Evaluator fee on an overturned verdict
    // -------------------------------------------------------------------------

    function test_DisputeOverturnsApprove_FeeAndRemainderReturnToTheProject() public {
        bytes32 taskId = _disputed(ITMPCore.VerdictType.APPROVE, REWARD - EVAL_FEE);
        uint256 award = 6e6;
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, taskId, EVAL_FEE);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, _award(award));

        assertEq(usdc.balanceOf(evaluator), 0, "an overturned verdict earns no fee");
        assertEq(_available(), BUDGET - award, "the remainder and the fee came back to the project");
        assertEq(_committed(), award, "the operator's cap keeps only what was spent");
        assertEq(usdc.balanceOf(owner), 0);
        _assertRouted();
    }

    function test_DisputeOverturnsReject_FeeReturnsToTheProject() public {
        bytes32 taskId = _disputed(ITMPCore.VerdictType.REJECT, 0);
        uint256 award = REWARD - EVAL_FEE;
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, taskId, EVAL_FEE);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _award(award));

        assertEq(usdc.balanceOf(evaluator), 0, "an overturned verdict earns no fee");
        assertEq(_available(), BUDGET - award, "the fee came back to the project");
        assertEq(_committed(), award);
        _assertRouted();
    }

    function test_DisputeUpheld_PaysTheEvaluator() public {
        uint256 award = REWARD - EVAL_FEE;
        bytes32 taskId = _disputed(ITMPCore.VerdictType.APPROVE, award);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _award(award));

        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(_available(), BUDGET - REWARD);
        _assertRouted();
    }

    function test_DisputeOverturned_AfterClose_FeeGoesToThePot() public {
        bytes32 taskId = _disputed(ITMPCore.VerdictType.REJECT, 0);
        vm.prank(owner);
        projects.closeProject(id);
        assertEq(_available(), BUDGET - REWARD, "the unspent budget stays, now as the pot");
        assertEq(usdc.balanceOf(owner), 0);

        uint256 award = REWARD - EVAL_FEE;
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _award(award));

        assertEq(_available(), BUDGET - REWARD + EVAL_FEE, "the fee went to the pot");
        assertEq(_committed(), award, "the operator's cap keeps only what was spent");
        assertEq(market.totalLiabilities(), BUDGET - REWARD + EVAL_FEE, "the pot stays booked");
        _assertRouted();

        pools.claim(projects.projectPoolId(id), owner);
        assertEq(usdc.balanceOf(owner), BUDGET - REWARD + EVAL_FEE, "the sole backer claims it all");
        assertEq(market.totalLiabilities(), 0);
        _assertRouted();
    }

    function test_DisputeOverturned_AfterTheEndDate_FeeGoesToThePot() public {
        bytes32 taskId = _disputed(ITMPCore.VerdictType.REJECT, 0);
        vm.warp(projects.getProject(id).endsAt);

        uint256 award = REWARD - EVAL_FEE;
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _award(award));

        assertEq(usdc.balanceOf(owner), 0);
        assertEq(_available(), BUDGET - REWARD + EVAL_FEE, "the fee went to the pot");
        _assertRouted();
    }

    // -------------------------------------------------------------------------
    // Other requester payouts
    // -------------------------------------------------------------------------

    function test_EvaluatorReject_RefundsTheProject() public {
        bytes32 taskId = _opTask(taskConfig(REWARD, DURATION, TMP_BOUNTY), _evalConfig(), _v2Terms());
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate, (taskId, ITMPCore.VerdictType.REJECT, 0, 1000, bytes32(0), new ITMPCore.Award[](0))
            )
        );
        vm.warp(block.timestamp + 1 days);
        market.finalizeVerdict(taskId);

        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Cancelled));
        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(_available(), BUDGET - EVAL_FEE, "the reward less the fee came back");
        assertEq(_committed(), EVAL_FEE);
        _assertRouted();
    }

    function test_UpdateTask_LowerReward_RefundsTheProject() public {
        bytes32 taskId = _opTask(taskConfig(REWARD, DURATION, TMP_BOUNTY), noEvaluatorConfig(), _v2Terms());
        uint256 lower = 15e6;
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, taskId, REWARD - lower);
        _relay(operator, 0, abi.encodeCall(market.updateTask, (taskId, lower, 0, 0, 0)));

        assertEq(market.getTask(taskId).reward, lower);
        assertEq(_available(), BUDGET - lower);
        assertEq(_committed(), lower);
        _assertRouted();
    }

    function test_AcceptSubmissions_SplitRemainderReturnsToTheProject() public {
        // An odd reward split in half leaves one unit unawarded.
        uint256 reward = REWARD + 1;
        bytes32 taskId = _opTask(taskConfig(reward, DURATION, TMP_BOUNTY), noEvaluatorConfig(), _v2Terms());
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));

        address[] memory workers = new address[](2);
        workers[0] = worker;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, taskId, 1);
        _relay(operator, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0)));

        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(_available(), BUDGET - reward + 1);
        _assertRouted();
    }

    function test_WorkerStakePenalty_ToTheRequester_GoesToTheProject() public {
        ITMPCore.TaskTerms memory t = _v2Terms();
        t.penaltyTo = ITMPCore.PenaltyTo.Requester;
        bytes32 taskId = _opTask(taskConfig(REWARD, DURATION, TMP_CLAIM), noEvaluatorConfig(), t);
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
        vm.warp(market.getTask(taskId).expiryTime + 1);

        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, taskId, STAKE);
        _relay(operator, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open));
        assertEq(usdc.balanceOf(worker), 0);
        assertEq(_available(), BUDGET - REWARD + STAKE, "the forfeited stake joined the budget");
        assertEq(_committed(), REWARD - STAKE);
        _assertRouted();
    }
}
