// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";

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
        return LibTaskMarket._buildContext(taskId, LibAppStorage.appStorage());
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
        return LibTaskMarket._resolveHooks(taskId, LibAppStorage.appStorage());
    }
}
