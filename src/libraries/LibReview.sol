// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { LibTerms } from "./LibTerms.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { TMP_CLAIM, TMP_PITCH, TMP_AUCTION, TMP_BOUNTY, TMP_BENCHMARK } from "../interfaces/ITMPModes.sol";

/// @title LibReview -- rev025 review window of a single-payee delivery
/// @dev A Claim, Pitch or Auction task without an evaluator holds an undecided delivery from
///      submitWork until accept, rejectDelivery or settleLapsedReview. A revision request
///      supersedes it until `revisionDueAt`; with no resubmission by then, the superseded delivery
///      is back under review with a window starting at `revisionDueAt`.
library LibReview {
    /// @notice Whether the task settles through the review window.
    function singlePayee(AppStorage storage s, bytes32 taskId, ITMPCore.Task storage task)
        internal
        view
        returns (bool)
    {
        bytes4 mode = task.mode;
        return (mode == TMP_CLAIM || mode == TMP_PITCH || mode == TMP_AUCTION)
            && s.taskEvaluatorConfigs[taskId].evaluator == address(0);
    }

    function reviewWindow(ITMPCore.TaskTerms memory t) internal pure returns (uint256) {
        return t.reviewWindowSecs == 0 ? LibTerms.DEFAULT_REVIEW_WINDOW_SECS : t.reviewWindowSecs;
    }

    /// @notice Start of the current review window, or zero when no delivery is under review
    ///         (none recorded, or a revision is still open for resubmission).
    function reviewStart(ITMPCore.TaskClock storage c) internal view returns (uint256) {
        if (c.deliveredAt != 0) return c.deliveredAt;
        uint256 due = c.revisionDueAt;
        if (due != 0 && block.timestamp > due) return due;
        return 0;
    }

    /// @notice Whether a revision request is open and the worker may still resubmit.
    function revisionOpen(ITMPCore.TaskClock storage c) internal view returns (bool) {
        uint256 due = c.revisionDueAt;
        return due != 0 && block.timestamp <= due;
    }

    /// @notice Normalize the task's terms and return the end of its current review window.
    ///         Reverts DeliverableRequired when no delivery is under review.
    function requireUnderReview(AppStorage storage s, bytes32 taskId)
        internal
        returns (ITMPCore.TaskTerms storage t, uint256 deadline)
    {
        t = LibTerms.terms(s, taskId);
        deadline = requireReviewDeadline(s, taskId, t);
    }

    /// @notice End of the current review window under the given terms.
    ///         Reverts DeliverableRequired when no delivery is under review.
    function requireReviewDeadline(AppStorage storage s, bytes32 taskId, ITMPCore.TaskTerms storage t)
        internal
        view
        returns (uint256 deadline)
    {
        uint256 start = reviewStart(s.taskClocks[taskId]);
        if (start == 0) revert ITMPCore.DeliverableRequired();
        deadline = start + reviewWindow(t);
    }

    /// @notice Close the review: the delivery is decided.
    function clear(ITMPCore.TaskClock storage c) internal {
        c.deliveredAt = 0;
        c.revisionDueAt = 0;
    }

    /// @notice Whether a Bounty or Benchmark without an evaluator still has live submissions past
    ///         its decision deadline, `max(expiryTime, decisionStartAt) + decisionWindowSecs`.
    ///         Normalizes a pre-rev025 task first, which seeds `decisionStartAt` at now.
    function decisionLapsed(AppStorage storage s, bytes32 taskId, ITMPCore.Task storage task) internal returns (bool) {
        if (task.mode != TMP_BOUNTY && task.mode != TMP_BENCHMARK) return false;
        if (s.taskEvaluatorConfigs[taskId].evaluator != address(0)) return false;
        if (s.taskActiveSubmissionCount[taskId] == 0) return false;
        ITMPCore.TaskTerms storage t = LibTerms.terms(s, taskId);
        uint256 start = task.expiryTime;
        uint256 seeded = s.taskClocks[taskId].decisionStartAt;
        if (seeded > start) start = seeded;
        uint256 window = t.decisionWindowSecs == 0 ? LibTerms.DEFAULT_DECISION_WINDOW_SECS : t.decisionWindowSecs;
        return block.timestamp > start + window;
    }

    /// @notice Revert DecisionWindowLapsed when `decisionLapsed`.
    function requireDecisionOpen(AppStorage storage s, bytes32 taskId, ITMPCore.Task storage task) internal {
        if (decisionLapsed(s, taskId, task)) revert ITMPCore.DecisionWindowLapsed();
    }
}
