// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title ITMPDispute
/// @notice Optional dispute resolution extension to TMP.
///         The core ITMP interface intentionally omits TaskStatus.Disputed;
///         dispute semantics are implementation-specific and belong here.
///
///         Implementations that support dispute resolution SHOULD implement
///         this interface and return true from
///         supportsInterface(type(ITMPDispute).interfaceId).
///
///         Security: Dispute resolution MUST NOT block refundExpired().
///         Expired tasks MUST always be refundable regardless of dispute state.
interface ITMPDispute {
    /// @notice Returns the arbitrator address for a given task.
    ///         address(0) indicates no arbitrator is assigned.
    /// @param taskId Task identifier
    function arbitratorFor(bytes32 taskId) external view returns (address);

    /// @notice Open a dispute for a task.
    ///         Only callable while the task is in an active (non-terminal) state.
    /// @param taskId Task identifier
    /// @param reason  Human-readable reason for the dispute
    function openDispute(bytes32 taskId, string calldata reason) external;

    /// @notice Resolve an open dispute.
    ///         Only callable by the task arbitrator.
    /// @param taskId    Task identifier
    /// @param worker    Worker address to receive payment (or address(0) to refund requester)
    function resolveDispute(bytes32 taskId, address worker) external;

    /// @notice Emitted when a dispute is opened.
    event DisputeOpened(bytes32 indexed taskId, address indexed opener, string reason);

    /// @notice Emitted when a dispute is resolved.
    event DisputeResolved(bytes32 indexed taskId, address indexed arbitrator, address winner);
}
