// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { ITMPReservation } from "../src/interfaces/ITMPReservation.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { LibDiamond } from "../src/libraries/LibDiamond.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev028 facet validation, guards and abuse paths: each test fails on the rev027 facets and
///      passes on rev028.
contract Rev028FacetGuardsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);

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

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _plainTerms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 2;
    }

    function _eval(address who) internal pure returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: who,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: 24 hours,
            appealWindow: 1 hours,
            disputeResolver: address(0)
        });
    }

    function _createCall(
        bytes4 mode,
        ITMPCore.TaskEvaluatorConfig memory evalCfg,
        ITMPCore.TaskTerms memory t,
        address reserved
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ITMPReservation.createTask,
            (
                taskConfig(REWARD, DURATION, mode, DURATION, DURATION, bytes4(0)),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                evalCfg,
                t,
                reserved
            )
        );
    }

    function _create(bytes4 mode) internal returns (bytes32) {
        return abi.decode(
            _relay(requester, REWARD, _createCall(mode, noEvaluatorConfig(), _plainTerms(), address(0))), (bytes32)
        );
    }

    function _createClaimWithStake() internal returns (bytes32 taskId) {
        taskId = abi.decode(
            _relay(requester, REWARD, _createCall(TMP_CLAIM, noEvaluatorConfig(), stakeTerms(true, 1000), address(0))),
            (bytes32)
        );
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
    }

    // -------------------------------------------------------------------------
    // Zero deliverable hash (submitWork / _recordDelivery)
    // -------------------------------------------------------------------------

    function test_RevertWhen_SubmitWork_ZeroDeliverable_Claim() public {
        bytes32 taskId = _createClaimWithStake();
        vm.expectRevert(ITMPCore.EmptyDeliverable.selector);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, bytes32(0))));
    }

    function test_RevertWhen_SubmitWork_ZeroDeliverable_Bounty() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        vm.expectRevert(ITMPCore.EmptyDeliverable.selector);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, bytes32(0))));
    }

    // -------------------------------------------------------------------------
    // assignEvaluator while a reservation is pending
    // -------------------------------------------------------------------------

    function test_RevertWhen_AssignEvaluator_ReservationPending() public {
        bytes32 taskId = abi.decode(
            _relay(requester, REWARD, _createCall(TMP_CLAIM, noEvaluatorConfig(), _plainTerms(), worker)), (bytes32)
        );
        vm.expectRevert(ITMPCore.ReservationPending.selector);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(24 hours), uint32(1 hours), address(0))
            )
        );
    }

    // -------------------------------------------------------------------------
    // forfeitAndReopen bars the forfeiter
    // -------------------------------------------------------------------------

    function test_ForfeitAndReopen_BarsTheForfeitedWorker() public {
        bytes32 taskId = _createClaimWithStake();
        vm.warp(block.timestamp + DURATION + 1);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        assertTrue(RegistryFacetView(address(market)).taskRejectedWorkers(taskId, worker));

        vm.expectRevert(ITMPCore.SubmissionAlreadyRejected.selector);
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
    }

    // -------------------------------------------------------------------------
    // Duplicate evaluator awards count one completed task
    // -------------------------------------------------------------------------

    function test_DuplicateAwards_CountOneCompletedTask() public {
        bytes32 taskId = abi.decode(
            _relay(requester, REWARD, _createCall(TMP_BOUNTY, _eval(evaluator), _plainTerms(), address(0))), (bytes32)
        );
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD / 2, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: worker, amount: REWARD / 2, rank: 2 });
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.APPROVE, 900, 900, bytes32(0), awards))
        );
        vm.warp(block.timestamp + 1 hours + 1);
        market.finalizeVerdict(taskId);

        assertEq(market.getWorkerStats(worker).completedTasks, 1);
    }

    // -------------------------------------------------------------------------
    // Non-funding relayed entrypoints take no payment
    // -------------------------------------------------------------------------

    function test_RevertWhen_NonFundingEntrypoint_ReceivesPayment() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(requester, 1, abi.encodeCall(market.cancelTask, (taskId, 0)));

        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(worker, 1, abi.encodeCall(market.submitWork, (taskId, WORK)));

        // Zero payment still works.
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_RevertWhen_PermissionlessEntrypoint_RelayedWithPayment() public {
        bytes32 taskId = _create(TMP_BOUNTY);
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(worker, 1, abi.encodeCall(market.finalizeVerdict, (taskId)));
    }

    // -------------------------------------------------------------------------
    // The diamond refuses native ETH
    // -------------------------------------------------------------------------

    function test_Diamond_RejectsNativeEth() public {
        vm.deal(address(this), 2 ether);
        (bool plain,) = address(market).call{ value: 1 ether }("");
        assertFalse(plain, "plain transfer reverts");
        (bool withCall,) = address(market).call{ value: 1 ether }(abi.encodeCall(market.pause, ()));
        assertFalse(withCall, "call with value reverts");
        assertEq(address(market).balance, 0);
    }

    // -------------------------------------------------------------------------
    // diamondCut init calldata without an init address
    // -------------------------------------------------------------------------

    function test_RevertWhen_DiamondCut_CalldataWithoutInit() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(owner);
        vm.expectRevert(LibDiamond.InitCalldataWithoutInit.selector);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), hex"deadbeef");

        // No init address and no calldata stays a plain cut.
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
    }

    // -------------------------------------------------------------------------
    // selectWorker rejects the zero worker
    // -------------------------------------------------------------------------

    function test_RevertWhen_SelectWorker_Zero() public {
        bytes32 taskId = _create(TMP_PITCH);
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, address(0))));
    }

    // -------------------------------------------------------------------------
    // A very long claim period does not block releaseClaim
    // -------------------------------------------------------------------------

    function test_ReleaseClaim_LongestDuration_Releases() public {
        ITMPCore.TaskTerms memory t = stakeTerms(true, 1000);
        t.version = 2;
        // Creation caps the duration (365 days), so the longest claim period is the cap; the release
        // math itself no longer multiplies the raw span.
        uint256 huge = 365 days;
        bytes memory data = abi.encodeCall(
            ITMPReservation.createTask,
            (
                taskConfig(REWARD, huge, TMP_CLAIM, huge, huge, bytes4(0)),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
        bytes32 taskId = abi.decode(_relay(requester, REWARD, data), (bytes32));
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));
        assertEq(usdc.balanceOf(worker), STAKE, "the whole stake comes back inside the grace period");
    }

    // -------------------------------------------------------------------------
    // Stake terms only on a mode that collects a stake
    // -------------------------------------------------------------------------

    function test_RevertWhen_StakeTerms_OnNonClaimMode() public {
        vm.expectRevert(ITMPCore.InvalidTerms.selector);
        _relay(requester, REWARD, _createCall(TMP_BOUNTY, noEvaluatorConfig(), stakeTerms(true, 1000), address(0)));
        vm.expectRevert(ITMPCore.InvalidTerms.selector);
        _relay(requester, REWARD, _createCall(TMP_PITCH, noEvaluatorConfig(), stakeTerms(true, 1000), address(0)));
        // A stakeBps with no stakeRequired flag is refused too.
        vm.expectRevert(ITMPCore.InvalidTerms.selector);
        _relay(requester, REWARD, _createCall(TMP_BOUNTY, noEvaluatorConfig(), stakeTerms(false, 500), address(0)));
        // A Claim task keeps its stake terms.
        _createClaimWithStake();
    }
}

interface RegistryFacetView {
    function taskRejectedWorkers(bytes32 taskId, address worker) external view returns (bool);
}

/// @dev Project-side rev028 guards: self-dealing across the requester of record, the operator and
///      the owner; delegated acceptance credits the requester of record; grants are forwarder-only.
contract Rev028ProjectGuardsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    FundingPool internal mockPool;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal owner = address(0xB0);
    address internal operator = address(0xB1);
    address internal worker = address(0xC0);
    address internal other = address(0xC1);

    uint256 internal constant BUDGET = 10e6;
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
        mockPool = initMockPool(address(market), admin);
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
        ITMPProject.GrantTerms memory g = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: true,
            revokeRemovesControl: true
        });
        _relay(owner, 0, abi.encodeCall(projects.grantOperator, (id, operator, g)));
        _relay(operator, 0, abi.encodeCall(projects.acceptGrant, (id, keccak256(abi.encode(g)))));
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _taskCall(ITMPCore.TaskEvaluatorConfig memory evalCfg, address reserved)
        internal
        view
        returns (bytes memory)
    {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(REWARD, 7 days, reserved == address(0) ? TMP_BOUNTY : TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                evalCfg,
                t,
                reserved
            )
        );
    }

    function _evalCfg(address ev, address resolver) internal pure returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: ev,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: 24 hours,
            appealWindow: 1 hours,
            disputeResolver: resolver
        });
    }

    function test_RevertWhen_OperatorTask_NamesAPartyAsEvaluatorOrResolverOrWorker() public {
        // The requester of record is the owner; the operator creates and acts for the task.
        vm.expectRevert(ITMPCore.EvaluatorCannotBeRequester.selector);
        _relay(operator, 0, _taskCall(_evalCfg(operator, address(0)), address(0)));
        vm.expectRevert(ITMPCore.EvaluatorCannotBeRequester.selector);
        _relay(operator, 0, _taskCall(_evalCfg(owner, address(0)), address(0)));
        vm.expectRevert(ITMPCore.DisputeResolverCannotBeRequester.selector);
        _relay(operator, 0, _taskCall(_evalCfg(other, operator), address(0)));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(operator, 0, _taskCall(noEvaluatorConfig(), operator));

        // An unrelated evaluator is fine.
        _relay(operator, 0, _taskCall(_evalCfg(other, address(0)), address(0)));
    }

    function test_RevertWhen_AssignEvaluator_OnOperatorTask_NamesAParty() public {
        bytes32 taskId = abi.decode(_relay(operator, 0, _taskCall(noEvaluatorConfig(), address(0))), (bytes32));
        vm.expectRevert(ITMPCore.EvaluatorCannotBeRequester.selector);
        _relay(
            operator,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, owner, 0, 0, uint32(24 hours), uint32(1 hours), address(0)))
        );
        vm.expectRevert(ITMPCore.DisputeResolverCannotBeRequester.selector);
        _relay(
            operator,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, other, 0, 0, uint32(24 hours), uint32(1 hours), operator))
        );
    }

    function test_DelegatedAcceptance_CreditsTheRequesterOfRecord() public {
        bytes32 taskId = abi.decode(_relay(operator, 0, _taskCall(noEvaluatorConfig(), address(0))), (bytes32));
        bytes32 work = keccak256("work");
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, work)));

        // The reputation signal names the owner (task.requester), not the operator who accepted.
        vm.expectEmit(true, true, false, false, address(market));
        emit ITMPCore.RequesterReputation(taskId, owner, bytes32(0), 0, 0, false);
        _relay(operator, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, work, 0)));
    }

    function test_RevertWhen_OperatorOrOwner_IsTheWorkerOnAProjectTask() public {
        // An operator-created bounty: neither the operator nor the owner may submit work to it.
        bytes32 taskId = abi.decode(_relay(operator, 0, _taskCall(noEvaluatorConfig(), address(0))), (bytes32));
        bytes32 work = keccak256("self-work");
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(operator, 0, abi.encodeCall(market.submitWork, (taskId, work)));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(owner, 0, abi.encodeCall(market.submitWork, (taskId, work)));
        // An unrelated worker still can.
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, work)));
    }

    function test_RevertWhen_OperatorClaimsItsOwnProjectTask() public {
        // A claim task reserved for another worker is created, then an acting party tries to claim a
        // second, unreserved claim task: build one directly through the project.
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        bytes32 taskId = abi.decode(
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
                        t,
                        address(0)
                    )
                )
            ),
            (bytes32)
        );
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(operator, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        vm.expectRevert(ITMPCore.InvalidWorker.selector);
        _relay(owner, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    function test_RevertWhen_GrantEntrypoints_CalledDirectly() public {
        ITMPProject.GrantTerms memory g = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: true,
            revokeRemovesControl: true
        });
        vm.startPrank(owner);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        projects.grantOperator(id, other, g);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        projects.revokeOperator(id, operator);
        vm.stopPrank();
        vm.prank(other);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        projects.acceptGrant(id, bytes32(0));
    }
}
