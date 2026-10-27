// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";

/// @title ITMPReservation -- rev027: a Claim task with a reserved worker
/// @notice A Claim task may name a reserved worker at creation. Until the accept-by time (creation
///         plus TaskTerms.acceptWindowSecs, 72 hours by default) only that worker may claim it,
///         which accepts it, or decline it, which refunds the requester and ends it. After the
///         accept-by time an unclaimed task can be refunded by anyone through refundExpired. The
///         requester may withdraw it with cancelTask while it is open. Once claimed it runs the
///         claim lifecycle, except that it never reopens: a rejection, a hand-back (releaseClaim)
///         and a forfeit all end it with a refund. Hooks run exactly as on any Claim task. While the
///         offer is pending, updateTask reverts; to change it the requester cancels and re-offers.
interface ITMPReservation {
    /// @notice createTask with a reserved worker; reservedWorker zero creates an ordinary task.
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms,
        address reservedWorker
    ) external returns (bytes32 taskId);

    /// @notice claimTask that, when the caller is the reserved worker accepting, also binds the
    ///         worker's agent ID for reservation feedback in the same transaction.
    /// @param workerAgentId ERC-8004 agent ID of the worker (0 if unknown), bound only when a
    ///                      trusted forwarder relays the worker's own call.
    function claimTask(bytes32 taskId, uint256 stakeAmount, uint256 workerAgentId) external;

    /// @notice The reserved worker declines the open task by its accept-by time. The task is
    ///         Cancelled and the reward and any evaluator stake go back to the requester.
    /// @param workerAgentId ERC-8004 agent ID of the worker (0 if unknown), bound to the worker
    ///                      address for reservation feedback when a trusted forwarder relays the
    ///                      worker's own call.
    function declineReservation(bytes32 taskId, uint256 workerAgentId) external;

    /// @notice A task's reserved worker and accept-by time; both zero for a task without one.
    function getReservation(bytes32 taskId) external view returns (address worker, uint256 acceptBy);
}
