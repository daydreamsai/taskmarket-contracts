// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import {
    TMP_BOUNTY,
    TMP_CLAIM,
    TMP_PITCH,
    TMP_AUCTION,
    TMP_AUCTION_DUTCH,
    TMP_AUCTION_ENGLISH
} from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { noGrantLimits, storedGrantHash } from "./helpers/GrantHelper.sol";

/// @dev rev031 conflicts of role: a task's evaluator and dispute resolver never work on, submit
///      to, appeal or take an award from the task they judge; a rejected contest entry stays
///      rejected under a verdict; an empty contest cannot be judged; a single-payee acceptance
///      names delivered work; the self-award signals agree; a lowest bidder that came to act for
///      the task is refused; and a co-winner may appeal.
contract Rev031RoleConflictsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

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

    uint256 internal pid;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        market = deployDiamond(admin, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        projects = ITMPProject(address(market));
        initMockPool(address(market), admin);
        usdc.mint(address(forwarder), 1_000_000e6);
        pid = abi.decode(
            _relay(
                owner,
                BUDGET,
                abi.encodeCall(
                    projects.createProject, (address(usdc), BUDGET, uint64(block.timestamp + 6 days), 12 hours)
                )
            ),
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

    function _task(ITMPCore.TaskConfig memory cfg, ITMPCore.TaskEvaluatorConfig memory ev) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        cfg,
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        ev,
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _bounty(ITMPCore.TaskEvaluatorConfig memory ev) internal returns (bytes32) {
        return _task(taskConfig(REWARD, 5 days, TMP_BOUNTY), ev);
    }

    function _pTask(address who, ITMPCore.TaskConfig memory cfg) internal returns (bytes32) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.decode(
            _relay(
                who,
                0,
                abi.encodeCall(
                    projects.createProjectTask,
                    (
                        pid,
                        cfg,
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        t,
                        address(0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _transferOwner(address to) internal {
        _relay(owner, 0, abi.encodeCall(projects.proposeProjectOwner, (pid, to)));
        _relay(to, 0, abi.encodeCall(projects.acceptProjectOwner, (pid)));
    }

    function _submit(bytes32 taskId, address who) internal {
        _relay(who, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    function _assign(bytes32 taskId) internal {
        _relay(
            requester, 0, abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, 2 days, 3 days, resolver))
        );
    }

    function _awards(address to, uint256 amount) internal pure returns (ITMPCore.Award[] memory a) {
        a = new ITMPCore.Award[](1);
        a[0] = ITMPCore.Award({ worker: to, amount: amount, rank: 1 });
    }

    function _evaluate(bytes32 taskId, ITMPCore.VerdictType vt, ITMPCore.Award[] memory awards) internal {
        _relay(evaluator, 0, abi.encodeCall(market.evaluate, (taskId, vt, uint16(9000), uint16(9000), WORK, awards)));
    }

    function _status(bytes32 taskId) internal view returns (uint8) {
        return uint8(market.getTask(taskId).status);
    }

    // -------------------------------------------------------------------------
    // A judge cannot work on the task it judges (Cantina TASK-9)
    // -------------------------------------------------------------------------

    function test_Claim_RefusedForTheEvaluatorAndTheResolver() public {
        bytes32 taskId = _task(taskConfig(REWARD, 5 days, TMP_CLAIM), _ev(evaluator, resolver));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(evaluator, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(resolver, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Claimed));
    }

    function test_SubmitWork_RefusedForTheEvaluatorAndTheResolver() public {
        bytes32 taskId = _bounty(_ev(evaluator, resolver));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _submit(taskId, evaluator);
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _submit(taskId, resolver);
        _submit(taskId, worker);
    }

    function test_SelectWorker_RefusesTheEvaluator() public {
        bytes32 taskId = _task(taskConfig(REWARD, 5 days, TMP_PITCH, 1 days, 0, bytes4(0)), _ev(evaluator, resolver));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, evaluator)));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, resolver)));
    }

    function test_Auction_RefusesTheEvaluatorAsBidderOrWinner() public {
        bytes32 english =
            _task(taskConfig(REWARD, 5 days, TMP_AUCTION, 0, 1 days, TMP_AUCTION_ENGLISH), _ev(evaluator, resolver));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(evaluator, 0, abi.encodeCall(market.submitBid, (english, REWARD)));

        bytes32 dutch =
            _task(taskConfig(REWARD, 5 days, TMP_AUCTION, 0, 1 days, TMP_AUCTION_DUTCH), _ev(evaluator, resolver));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(resolver, 0, abi.encodeCall(market.acceptAuction, (dutch, REWARD)));
    }

    function test_SelectLowestBidder_RefusesABidderLaterNamedEvaluator() public {
        bytes32 taskId =
            _task(taskConfig(REWARD, 5 days, TMP_AUCTION, 0, 1 days, TMP_AUCTION_ENGLISH), noEvaluatorConfig());
        _relay(evaluator, 0, abi.encodeCall(market.submitBid, (taskId, REWARD)));
        _assign(taskId);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(stranger, 0, abi.encodeCall(market.selectLowestBidder, (taskId)));
    }

    // -------------------------------------------------------------------------
    // A judge takes no award, and the resolver cannot appeal (Cantina TASK-9, TASK-27)
    // -------------------------------------------------------------------------

    /// @dev assignEvaluator needs no live entry, so a judge holds a submission only once the
    ///      requester rejected it (or on a task in flight at the upgrade).
    function _judgeSubmittedThenAssigned(address judge) internal returns (bytes32 taskId) {
        taskId = _bounty(noEvaluatorConfig());
        _submit(taskId, judge);
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, judge)));
        _assign(taskId);
        _submit(taskId, worker);
    }

    function test_Evaluate_RefusesAnAwardToTheEvaluator() public {
        bytes32 taskId = _judgeSubmittedThenAssigned(evaluator);
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _evaluate(taskId, ITMPCore.VerdictType.APPROVE, _awards(evaluator, REWARD));
        _evaluate(taskId, ITMPCore.VerdictType.APPROVE, _awards(worker, REWARD));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Appealing));
    }

    function test_Dispute_ResolverCannotAppealOrAwardItself() public {
        bytes32 taskId = _judgeSubmittedThenAssigned(resolver);
        _evaluate(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));

        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(resolver, 0, abi.encodeCall(market.appeal, (taskId)));

        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Disputed));

        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _awards(resolver, REWARD));

        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _awards(worker, REWARD));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Accepted));
    }

    // -------------------------------------------------------------------------
    // A rejected contest entry stays rejected under a verdict (Cantina TASK-18)
    // -------------------------------------------------------------------------

    function test_Evaluate_RefusesAnAwardToARejectedWorker() public {
        bytes32 taskId = _bounty(noEvaluatorConfig());
        _submit(taskId, worker);
        _submit(taskId, worker2);
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker)));
        _relay(requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker2)));
        _assign(taskId);
        _submit(taskId, stranger);
        vm.expectRevert(ITMPCore.SubmissionAlreadyRejected.selector);
        _evaluate(taskId, ITMPCore.VerdictType.APPROVE, _awards(worker, REWARD));
        _evaluate(taskId, ITMPCore.VerdictType.APPROVE, _awards(stranger, REWARD));
    }

    // -------------------------------------------------------------------------
    // An empty contest cannot be judged (Cantina TASK-100)
    // -------------------------------------------------------------------------

    function test_Evaluate_RefusesAContestWithNoLiveSubmission() public {
        bytes32 taskId = _bounty(_ev(evaluator, resolver));
        vm.expectRevert(ITMPCore.NoActiveSubmissions.selector);
        _evaluate(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Open));
    }

    // -------------------------------------------------------------------------
    // A single-payee acceptance names delivered work (Cantina TASK-107)
    // -------------------------------------------------------------------------

    function test_AcceptSubmission_RefusesAnUndeliveredClaim() public {
        bytes32 taskId = _task(taskConfig(REWARD, 5 days, TMP_CLAIM), noEvaluatorConfig());
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        vm.expectRevert(ITMPCore.DeliverableRequired.selector);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, bytes32(0), 0)));
        _submit(taskId, worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Accepted));
    }

    // -------------------------------------------------------------------------
    // selfPaid follows isActingParty, as SelfAward does (Cyclops 7650)
    // -------------------------------------------------------------------------

    function test_Accept_SelfPaidMatchesSelfAwardForAnOwnerWorker() public {
        ITMPProject.GrantTerms memory gt = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Operator,
            ownerOverride: false,
            revokeRemovesControl: false
        });
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (pid, operator, gt, noGrantLimits())));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (pid, storedGrantHash(projects, pid, operator))));
        bytes32 taskId = _pTask(operator, taskConfig(REWARD, 5 days, TMP_BOUNTY));
        _submit(taskId, worker);
        _transferOwner(worker);

        vm.expectEmit(true, true, true, true, address(market));
        emit ITMPCore.SelfAward(taskId, operator, worker);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.RequesterReputation(taskId, operator, keccak256("completed"), REWARD, 1, true);
        _relay(operator, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }

    // -------------------------------------------------------------------------
    // A lowest bidder that came to act for the task is refused (Cyclops 7616)
    // -------------------------------------------------------------------------

    function test_SelectLowestBidder_RefusesABidderWhoBecameTheOwner() public {
        bytes32 taskId = _pTask(owner, taskConfig(REWARD, 5 days, TMP_AUCTION, 0, 1 days, TMP_AUCTION_ENGLISH));
        _relay(worker, 0, abi.encodeCall(market.submitBid, (taskId, REWARD)));
        _transferOwner(worker);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(stranger, 0, abi.encodeCall(market.selectLowestBidder, (taskId)));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Open), "the auction lapses at expiry");
    }

    // -------------------------------------------------------------------------
    // A co-winner may appeal; a submitter with no award still may not (Cyclops 7666)
    // -------------------------------------------------------------------------

    function test_Appeal_OpenToACoWinnerNotToAnUnawardedSubmitter() public {
        bytes32 taskId = _bounty(_ev(evaluator, resolver));
        _submit(taskId, worker);
        _submit(taskId, worker2);
        _submit(taskId, stranger);
        ITMPCore.Award[] memory a = new ITMPCore.Award[](2);
        a[0] = ITMPCore.Award({ worker: worker, amount: REWARD / 2, rank: 1 });
        a[1] = ITMPCore.Award({ worker: worker2, amount: REWARD / 4, rank: 2 });
        _evaluate(taskId, ITMPCore.VerdictType.PARTIAL, a);

        vm.expectRevert(ITMPCore.NotWorker.selector);
        _relay(stranger, 0, abi.encodeCall(market.appeal, (taskId)));

        _relay(worker2, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(_status(taskId), uint8(ITMPCore.TaskStatus.Disputed));
    }
}
