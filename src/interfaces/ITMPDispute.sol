// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ITMPDispute
/// @notice Optional dispute resolution extension to TMP (ERC-8195).
///         The core ITMP interface intentionally omits TaskStatus.Disputed;
///         dispute semantics are implementation-specific and belong here.
///
///         Implementations that support dispute resolution SHOULD implement
///         this interface and return true from
///         supportsInterface(type(ITMPDispute).interfaceId).
///
///         Security: Dispute resolution MUST NOT block refundExpired().
///         Expired tasks MUST always be refundable regardless of dispute state.
interface ITMPDispute is IERC165 {
    enum DisputeStatus { None, Open, Resolved }

    /// @notice Returns dispute status for a task.
    function disputeStatus(bytes32 taskId) external view returns (DisputeStatus);

    /// @notice Returns the arbitrator for a task (zero if no dispute).
    function arbitratorFor(bytes32 taskId) external view returns (address);

    /// @notice Open a dispute for a task in PendingApproval or Accepted state.
    /// @param taskId   Task identifier
    /// @param initiator Address opening the dispute
    /// @param reason   Human-readable reason for the dispute
    function openDispute(bytes32 taskId, address initiator, string calldata reason) external;

    /// @notice Resolve a dispute. Only callable by arbitratorFor(taskId).
    ///         workerShare + requesterShare MUST equal 100.
    /// @param taskId          Task identifier
    /// @param workerShare     Percentage of reward sent to worker (0-100)
    /// @param requesterShare  Percentage of reward refunded to requester (0-100)
    function resolveDispute(bytes32 taskId, uint8 workerShare, uint8 requesterShare) external;

    /// @notice Emitted when a dispute is opened.
    event DisputeOpened(bytes32 indexed taskId, address indexed initiator);

    /// @notice Emitted when a dispute is resolved.
    event DisputeResolved(bytes32 indexed taskId, uint8 workerShare, uint8 requesterShare);
}
