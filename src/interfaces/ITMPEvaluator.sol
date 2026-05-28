// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPCore } from "./ITMPCore.sol";

/// @title ITMPEvaluator — ERC-8195 evaluator extension interface
/// @notice Optional evaluator role for tasks requiring third-party assessment.
///         Activated by calling assignEvaluator() on an open task. When an evaluator
///         is assigned, work submission routes through Review/Appealing/Disputed states
///         instead of the direct-acceptance flow.
///
///         All functions MUST be gated to tasks that have an evaluator assigned.
///         Tasks without an evaluator follow the standard ITMPCore acceptance flow unchanged.
interface ITMPEvaluator is IERC165 {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when an evaluator is assigned to a task.
    event EvaluatorAssigned(bytes32 indexed taskId, address indexed evaluator, uint256 stakeAmount);

    /// @notice Emitted when an evaluator submits a verdict.
    event TaskEvaluated(bytes32 indexed taskId, address indexed evaluator, uint8 verdictType, uint16 score);

    /// @notice Emitted when a worker appeals a verdict.
    event TaskAppealed(bytes32 indexed taskId, address indexed appellant);

    /// @notice Emitted when an appeal escalates to a dispute.
    event TaskDisputed(bytes32 indexed taskId, address indexed disputeResolver);

    /// @notice Emitted when an evaluator fails to evaluate within the window.
    event EvaluatorTimedOut(bytes32 indexed taskId, address indexed evaluator, uint256 forfeitedStake);

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @notice Assign an evaluator to an open task.
    ///         Only the requester may call this, only while the task is Open.
    ///         If stakeAmount > 0, the contract pulls that amount from the requester
    ///         via transferFrom at assignment time. The requester must have approved
    ///         the contract for at least stakeAmount before calling.
    ///         The stake is returned to the evaluator upon calling evaluate(), or
    ///         forfeited to the fee recipient if evaluatorTimeout() is called.
    function assignEvaluator(
        bytes32 taskId,
        address evaluator,
        uint256 stakeAmount,
        uint16 feeBps,
        uint32 evaluationWindowSecs,
        uint32 appealWindowSecs,
        address disputeResolver
    ) external;

    /// @notice Submit an evaluation verdict.
    ///         Only task.evaluator may call this.
    ///         For CLAIM/PITCH/AUCTION: task must be in Review status.
    ///         For BOUNTY/BENCHMARK: task must be Open (evaluator selects winners via awards).
    ///         Transitions the task to Appealing and starts the appeal window.
    function evaluate(
        bytes32 taskId,
        ITMPCore.VerdictType verdictType,
        uint16 score,
        uint16 confidence,
        bytes32 evidenceHash,
        ITMPCore.Award[] calldata awards
    ) external;

    /// @notice Appeal the evaluator's verdict.
    ///         Only task.worker may call this, only while status == Appealing
    ///         and block.timestamp < appeal deadline.
    ///         Transitions to Disputed.
    function appeal(bytes32 taskId) external;

    /// @notice Finalize the verdict after the appeal window has expired.
    ///         Anyone may call this once block.timestamp >= appeal deadline.
    ///         APPROVE/PARTIAL: pays workers per stored awards, transitions to Accepted.
    ///         REJECT: refunds requester, reopens task (transitions to Open).
    function finalizeVerdict(bytes32 taskId) external;

    /// @notice Resolve a disputed task.
    ///         Only task.disputeResolver may call this while status == Disputed.
    ///         Pays workers per the provided awards and transitions to Accepted.
    function resolveDispute(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] calldata awards) external;

    /// @notice Trigger evaluator timeout after the evaluation window expires.
    ///         Only the requester may call this.
    ///         Forfeits the evaluator stake to the fee recipient and transitions
    ///         the task to PendingApproval so the requester can call acceptSubmission.
    function evaluatorTimeout(bytes32 taskId) external;

    /// @notice Returns the evaluator assigned to a task (address(0) if none).
    /// @param taskId Task identifier
    function evaluatorFor(bytes32 taskId) external view returns (address);
}
