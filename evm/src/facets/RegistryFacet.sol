// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibReview } from "../libraries/LibReview.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";

/// @title RegistryFacet — all read-only view functions for tasks, workers, and protocol state
contract RegistryFacet {
    // -------------------------------------------------------------------------
    // ITMPCore views
    // -------------------------------------------------------------------------

    /// @notice Get task details.
    function getTask(bytes32 taskId) external view returns (ITMPCore.Task memory) {
        return LibAppStorage.appStorage().tasks[taskId];
    }

    /// @notice Get worker statistics.
    function getWorkerStats(address worker) external view returns (ITMPCore.WorkerStats memory) {
        return LibAppStorage.appStorage().workerStats[worker];
    }

    /// @notice True if a worker has already rated a task.
    function hasWorkerRated(bytes32 taskId, address worker) external view returns (bool) {
        return LibAppStorage.appStorage().taskWorkerRated[taskId][worker];
    }

    /// @notice Returns the current nonce for task ID pre-computation.
    function requesterNonce(address requester) external view returns (uint256) {
        return LibAppStorage.appStorage().requesterNonce[requester];
    }

    // -------------------------------------------------------------------------
    // ITMPRegistry views
    // -------------------------------------------------------------------------

    /// @notice Get current task status.
    function getTaskState(bytes32 taskId) external view returns (ITMPCore.TaskStatus) {
        return LibAppStorage.appStorage().tasks[taskId].status;
    }

    /// @notice Get task context snapshot (for hooks and integrations).
    function getTaskContext(bytes32 taskId) external view returns (ITMPCore.TaskContext memory) {
        return LibHooks._buildContext(taskId, LibAppStorage.appStorage());
    }

    /// @notice Get stored verdict (issued = false until evaluate() is called).
    function getTaskVerdict(bytes32 taskId) external view returns (ITMPCore.Verdict memory) {
        return LibAppStorage.appStorage().taskVerdicts[taskId];
    }

    // -------------------------------------------------------------------------
    // ITMPEvaluator views
    // -------------------------------------------------------------------------

    /// @notice Returns the evaluator assigned to a task (address(0) if none).
    function evaluatorFor(bytes32 taskId) external view returns (address) {
        return LibAppStorage.appStorage().taskEvaluatorConfigs[taskId].evaluator;
    }

    // -------------------------------------------------------------------------
    // ITMPModes views
    // -------------------------------------------------------------------------

    /// @notice Returns the mode selector for a task.
    function taskMode(bytes32 taskId) external view returns (bytes4 mode) {
        return LibAppStorage.appStorage().tasks[taskId].mode;
    }

    // -------------------------------------------------------------------------
    // ITMPFees views
    // -------------------------------------------------------------------------

    /// @notice Default platform fee in basis points.
    function defaultFeeBps() external view returns (uint16) {
        return LibAppStorage.appStorage().defaultFeeBps;
    }

    /// @notice Address that receives platform fees.
    function feeRecipient() external view returns (address) {
        return LibAppStorage.appStorage().feeRecipient;
    }

    /// @notice Cumulative platform fees collected since deployment.
    function totalFeesCollected() external view returns (uint256) {
        return LibAppStorage.appStorage().totalFeesCollected;
    }

    /// @notice Per-task fee in basis points stamped at task creation.
    function feeForTask(bytes32 taskId) external view returns (uint16) {
        return LibAppStorage.appStorage().tasks[taskId].feeBps;
    }

    // -------------------------------------------------------------------------
    // ITMPReputation views
    // -------------------------------------------------------------------------

    /// @notice Address of the ERC-8004 Reputation Registry (address(0) if disabled).
    function reputationRegistry() external view returns (address) {
        return LibAppStorage.appStorage().reputationRegistry;
    }

    // -------------------------------------------------------------------------
    // Extended task data views
    // -------------------------------------------------------------------------

    /// @notice Get evaluator configuration for a task.
    function getTaskEvaluatorConfig(bytes32 taskId) external view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return LibAppStorage.appStorage().taskEvaluatorConfigs[taskId];
    }

    /// @notice Get auction configuration for a task.
    function getTaskAuctionConfig(bytes32 taskId) external view returns (ITMPCore.TaskAuctionConfig memory) {
        return LibAppStorage.appStorage().taskAuctionConfigs[taskId];
    }

    /// @notice Get write-once metadata for a task (createdAt, claimedAt, content hash/URI).
    function getTaskMetadata(bytes32 taskId) external view returns (ITMPCore.TaskMetadata memory) {
        return LibAppStorage.appStorage().taskMetadata[taskId];
    }

    /// @notice Get pitch configuration for a task.
    function getTaskPitchConfig(bytes32 taskId) external view returns (ITMPCore.TaskPitchConfig memory) {
        return LibAppStorage.appStorage().taskPitchConfigs[taskId];
    }

    /// @notice Get all bids for a task.
    function getBids(bytes32 taskId) external view returns (ITMPCore.Bid[] memory) {
        return LibAppStorage.appStorage().taskBids[taskId];
    }

    /// @notice Amount of stake locked as forfeit for a task (Claim mode).
    function stakeForfeit(bytes32 taskId) external view returns (uint256) {
        return LibAppStorage.appStorage().stakeForfeit[taskId];
    }

    /// @notice The USDC token used for payments and escrow.
    function usdcToken() external view returns (address) {
        return address(LibAppStorage.appStorage().usdcToken);
    }

    // -------------------------------------------------------------------------
    // Submission state views
    // -------------------------------------------------------------------------

    /// @notice Returns one pitch hash submitted for a task, by index.
    function taskPitchHashes(bytes32 taskId, uint256 index) external view returns (bytes32) {
        return LibAppStorage.appStorage().taskPitchHashes[taskId][index];
    }

    /// @notice Returns one proof hash submitted for a task, by index.
    function taskProofHashes(bytes32 taskId, uint256 index) external view returns (bytes32) {
        return LibAppStorage.appStorage().taskProofHashes[taskId][index];
    }

    /// @notice Returns all deliverable hashes committed by a worker via submitWork for a given task.
    function taskSubmissionHashes(bytes32 taskId, address worker) external view returns (bytes32[] memory) {
        return LibAppStorage.appStorage().taskSubmissionHashes[taskId][worker];
    }

    /// @notice True if a specific deliverable hash was committed by a worker via submitWork.
    function taskSubmissionHashExists(bytes32 taskId, address worker, bytes32 hash) external view returns (bool) {
        return LibAppStorage.appStorage().taskSubmissionHashExists[taskId][worker][hash];
    }

    /// @notice Number of active (non-rejected) submissions for a task.
    function taskActiveSubmissionCount(bytes32 taskId) external view returns (uint256) {
        return LibAppStorage.appStorage().taskActiveSubmissionCount[taskId];
    }

    /// @notice True if any submission was ever made on a task.
    function taskHasSubmissions(bytes32 taskId) external view returns (bool) {
        return LibAppStorage.appStorage().taskHasSubmissions[taskId];
    }

    /// @notice True if a worker has been rejected on a task.
    function taskRejectedWorkers(bytes32 taskId, address worker) external view returns (bool) {
        return LibAppStorage.appStorage().taskRejectedWorkers[taskId][worker];
    }

    // -------------------------------------------------------------------------
    // Hook views
    // -------------------------------------------------------------------------

    /// @notice Returns the hook list stored for a task. Hooks are committed at creation
    ///         time with protocol default hooks prepended before any requester-supplied hooks.
    function getTaskHooks(bytes32 taskId) external view returns (address[] memory) {
        return LibHooks._resolveHooks(taskId, LibAppStorage.appStorage());
    }

    // -------------------------------------------------------------------------
    // Escrow views (Rev026)
    // -------------------------------------------------------------------------

    /// @notice What the diamond's pooled escrow owes across every booked task.
    function totalLiabilities() external view returns (uint256) {
        return LibAppStorage.appStorage().totalLiabilities;
    }

    /// @notice A task's booked amount, and whether it is booked at all (false for a pre-rev026
    ///         task the upgrade has not booked).
    function escrowRecord(bytes32 taskId) external view returns (uint256 booked, bool tracked) {
        ITMPEscrow.EscrowRecord storage rec = LibAppStorage.appStorage().escrowRecords[taskId];
        return (rec.booked, rec.tracked);
    }

    /// @notice True once every live task is booked; the surplus sweep stays closed until then.
    function liabilitiesInitialised() external view returns (bool) {
        return LibAppStorage.appStorage().liabilitiesInitialised;
    }

    // -------------------------------------------------------------------------
    // Settlement views (rev028: moved from SettlementFacet, selectors unchanged, to keep that
    // facet under the contract size limit)
    // -------------------------------------------------------------------------

    /// @notice Get a task's settlement terms. A task created before rev025 that was terminal at
    ///         the rev025 cut was never normalized and reads as version 0.
    function getTaskTerms(bytes32 taskId) external view returns (ITMPCore.TaskTerms memory) {
        return LibAppStorage.appStorage().taskTerms[taskId];
    }

    /// @notice Get a task's delivery and review clock: when the current delivery landed
    ///         (deliveredAt, zero while none is under review), when the decision clock started
    ///         (decisionStartAt), how many revisions the requester has used, and the resubmission
    ///         deadline of an open revision request (revisionDueAt, zero when none is open).
    ///         All fields read zero for a task with no clock record.
    function getTaskClock(bytes32 taskId) external view returns (ITMPCore.TaskClock memory) {
        return LibAppStorage.appStorage().taskClocks[taskId];
    }

    /// @notice Return the effective bounds on requester-chosen settlement terms. Each reads as
    ///         its compiled default until the owner sets it.
    function termsBounds()
        external
        view
        returns (uint32 minWindowSecs, uint32 maxWindowSecs, uint16 maxRejectFeeBps, uint8 maxRevisions)
    {
        (minWindowSecs, maxWindowSecs, maxRejectFeeBps, maxRevisions) = LibTerms.bounds(LibAppStorage.appStorage());
    }

    /// @notice A task's reserved worker and accept-by time; both zero for a task without one.
    function getReservation(bytes32 taskId) external view returns (address worker, uint256 acceptBy) {
        AppStorage storage s = LibAppStorage.appStorage();
        return (s.reservedWorkers[taskId], LibTerms.acceptBy(s, taskId));
    }

    /// @notice Whether the diamond is inside a state-changing call (its reentrancy lock is held), as
    ///         during settlement while hooks are dispatched. Lets a hook tell a settlement in
    ///         progress from one that finished.
    function isSettling() external view returns (bool) {
        return LibAppStorage.appStorage().reentrancyStatus == LibGuards.ENTERED;
    }

    /// @notice Most winners one Bounty or Benchmark settlement may pay.
    // solhint-disable-next-line func-name-mixedcase
    function MAX_SUBMISSION_WINNERS() external pure returns (uint256) {
        return LibTaskMarket.MAX_SUBMISSION_WINNERS;
    }

    /// @notice End of the current review window, or zero when no delivery awaits review. While a
    ///         revision is open, the deadline the superseded delivery gets if none is resubmitted.
    function reviewDeadline(bytes32 taskId) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
        uint256 start = clock.deliveredAt != 0 ? clock.deliveredAt : clock.revisionDueAt;
        if (start == 0) return 0;
        return start + LibReview.reviewWindow(s.taskTerms[taskId]);
    }
}
