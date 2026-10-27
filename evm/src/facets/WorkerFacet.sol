// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibReview } from "../libraries/LibReview.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { LibFeedback } from "../libraries/LibFeedback.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title WorkerFacet -- taking on a task and delivering it: claim, worker selection, pitch,
///        proof and work submission
/// @notice Rev027: these entrypoints moved here from CoreFacet unchanged, with the same selectors,
///         so CoreFacet keeps room under the contract size limit. CoreFacet keeps task creation
///         and updates.
contract WorkerFacet {
    /// @notice Claim a Claim-mode task. The worker is the authenticated actor (pgtrSender).
    /// @param taskId      Task identifier
    /// @param stakeAmount USDC stake amount (0 = no stake required)
    function claimTask(bytes32 taskId, uint256 stakeAmount) external {
        _claimTask(taskId, stakeAmount, 0);
    }

    /// @notice Rev027: claimTask that also binds the worker's ERC-8004 agent ID when it accepts a
    ///         reservation, so a later forfeit's feedback reaches the worker. The ID is bound only
    ///         when a trusted forwarder relays the worker's own call; 0 binds nothing.
    /// @param workerAgentId ERC-8004 agent ID of the worker (0 if unknown)
    function claimTask(bytes32 taskId, uint256 stakeAmount, uint256 workerAgentId) external {
        _claimTask(taskId, stakeAmount, workerAgentId);
    }

    function _claimTask(bytes32 taskId, uint256 stakeAmount, uint256 workerAgentId) private {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (worker == address(0)) revert ITMPCore.InvalidWorker();
        if (task.mode != TMP_CLAIM) revert ITMPCore.NotAClaimTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (s.taskRejectedWorkers[taskId][worker]) revert ITMPCore.SubmissionAlreadyRejected();
        if (s.reservedWorkers[taskId] != address(0)) {
            _acceptReservation(taskId, task, worker, s);
            LibFeedback.bindWorker(s, worker, workerAgentId);
        }
        LibGuards._requireStakePayment(stakeAmount);
        if (stakeAmount < LibTerms.minStake(s.taskTerms[taskId], task.reward)) {
            revert ITMPCore.StakePaymentMismatch();
        }

        task.worker = worker;
        task.stakeAmount = stakeAmount;
        task.status = ITMPCore.TaskStatus.Claimed;
        s.taskMetadata[taskId].claimedAt = block.timestamp;

        LibHooks._checkClaimHooks(taskId, worker, s);

        emit ITMPCore.TaskClaimed(taskId, worker, stakeAmount);
        LibEscrow.book(s, taskId, worker, ITMPEscrow.Component.WorkerStake, false);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev Rev027: a task with a reserved worker is claimed only by that worker, by the accept-by
    ///      time, and its delivery period (the span from creation to expiry) restarts at the claim,
    ///      so time spent deciding never shortens it.
    function _acceptReservation(bytes32 taskId, ITMPCore.Task storage task, address worker, AppStorage storage s)
        private
    {
        if (worker != s.reservedWorkers[taskId]) revert ITMPCore.NotReservedWorker();
        if (block.timestamp > LibTerms.acceptBy(s, taskId)) revert ITMPCore.AcceptWindowClosed();
        uint256 newExpiry = block.timestamp + (task.expiryTime - s.taskMetadata[taskId].createdAt);
        if (newExpiry != task.expiryTime) {
            task.expiryTime = newExpiry;
            emit ITMPCore.TaskExpiryExtended(taskId, newExpiry);
        }
    }

    /// @notice Select a worker for Pitch mode. The requester is the authenticated actor (pgtrSender).
    /// @param taskId Task identifier
    /// @param worker Selected worker address
    function selectWorker(bytes32 taskId, address worker) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        LibGuards._requireRequester(s, taskId, requester);
        if (task.mode != TMP_PITCH) revert ITMPCore.NotAPitchTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        // pitchDeadline closes new submissions but does not block worker selection;
        // the requester may review and select from received pitches after the window closes.
        if (s.taskRejectedWorkers[taskId][worker]) revert ITMPCore.SubmissionAlreadyRejected();

        task.worker = worker;
        task.status = ITMPCore.TaskStatus.WorkerSelected;

        LibHooks._checkSelectWorkerHooks(taskId, worker, s);

        emit ITMPCore.TaskWorkerSelected(taskId, worker);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Anchor a pitch-content hash on-chain. The worker is the authenticated actor.
    /// @param taskId    Task identifier
    /// @param pitchHash Content hash (typically keccak256(abi.encode(taskId, worker, pitchText)))
    function submitPitch(bytes32 taskId, bytes32 pitchHash) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != TMP_PITCH) revert ITMPCore.NotAPitchTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > s.taskPitchConfigs[taskId].pitchDeadline) revert ITMPCore.PitchDeadlinePassed();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (pitchHash == bytes32(0)) revert ITMPCore.EmptyPitchHash();

        s.taskPitchHashes[taskId].push(pitchHash);

        emit ITMPCore.PitchSubmitted(taskId, worker, pitchHash);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Anchor a benchmark-proof hash on-chain. The worker is the authenticated actor.
    /// @param taskId      Task identifier
    /// @param proofHash   Content hash (typically keccak256(abi.encode(taskId, worker, proofData)))
    /// @param proofType   bytes32 selector identifying the proof scheme
    /// @param metricValue Task-specific numeric score
    function submitProof(bytes32 taskId, bytes32 proofHash, bytes32 proofType, uint256 metricValue) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != TMP_BENCHMARK) revert ITMPCore.NotABenchmarkTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (proofHash == bytes32(0)) revert ITMPCore.EmptyProofHash();

        s.taskProofHashes[taskId].push(proofHash);

        emit ITMPCore.ProofSubmitted(taskId, worker, proofHash, proofType, metricValue);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Record that a worker has submitted deliverable work.
    ///         State change is mode-dependent. The worker is the authenticated actor.
    /// @param taskId      Task identifier
    /// @param deliverable Content hash (keccak256, IPFS CID, or ZK commitment)
    // Complexity is inherent: five task modes each require distinct state-transition branches.
    // solhint-disable-next-line code-complexity
    function submitWork(bytes32 taskId, bytes32 deliverable) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();

        if (task.mode == TMP_BOUNTY || task.mode == TMP_BENCHMARK) {
            // Bounty and Benchmark are open contests: the task stays Open and keeps
            // accepting submissions until the requester accepts one (which moves it to
            // Accepted) or it expires. There is no status flip on submit.
            if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
            if (s.taskRejectedWorkers[taskId][worker]) revert ITMPCore.SubmissionAlreadyRejected();
            // Track on-chain that at least one submission exists. Used to protect workers
            // by blocking cancelTask and refundExpired once work has been submitted.
            s.taskHasSubmissions[taskId] = true;
            s.taskActiveSubmissionCount[taskId]++;
            // Append to version history so AcceptanceFacet can verify the hash was committed.
            s.taskSubmissionHashes[taskId][worker].push(deliverable);
            s.taskSubmissionHashExists[taskId][worker][deliverable] = true;
        } else if (task.mode == TMP_CLAIM) {
            if (task.status != ITMPCore.TaskStatus.Claimed) revert ITMPCore.TaskNotClaimed();
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            _recordDelivery(taskId, task, deliverable, s);
        } else if (task.mode == TMP_PITCH || task.mode == TMP_AUCTION) {
            if (task.status != ITMPCore.TaskStatus.WorkerSelected && task.status != ITMPCore.TaskStatus.Claimed) {
                revert ITMPCore.WorkerNotSelected();
            }
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            _recordDelivery(taskId, task, deliverable, s);
        }

        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (
            evalCfg.evaluator != address(0)
                && (task.mode == TMP_CLAIM || task.mode == TMP_PITCH || task.mode == TMP_AUCTION)
        ) {
            task.status = ITMPCore.TaskStatus.Review;
            uint256 reviewDeadline = block.timestamp + evalCfg.evaluationWindow;
            s.phaseDeadline[taskId] = reviewDeadline;
            if (reviewDeadline > task.expiryTime) {
                task.expiryTime = reviewDeadline;
            }
        }

        LibHooks._checkSubmitHooks(taskId, worker, deliverable, s);

        emit ITMPCore.TaskSubmitted(taskId, worker, deliverable);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev A single-payee task without an evaluator opens its review window at delivery; a
    ///      resubmission is allowed only while a revision request is open.
    function _recordDelivery(bytes32 taskId, ITMPCore.Task storage task, bytes32 deliverable, AppStorage storage s)
        private
    {
        ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
        if (task.deliverable != bytes32(0) && !LibReview.revisionOpen(clock)) revert ITMPCore.DeliverableAlreadySet();
        task.deliverable = deliverable;
        if (s.taskEvaluatorConfigs[taskId].evaluator == address(0)) {
            clock.deliveredAt = uint64(block.timestamp);
            clock.revisionDueAt = 0;
        }
    }
}
