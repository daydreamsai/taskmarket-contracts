// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title LibTerms -- rev025 settlement terms: the single reader, normalization and validation
/// @dev Settlement code reads terms only through `terms`, which writes a version 1 record for a
///      non-terminal task created before rev025 the first time it is read. A terminal pre-rev025
///      task is never normalized and keeps reading as all zeros.
library LibTerms {
    uint8 internal constant TERMS_VERSION = 1;

    uint32 internal constant DEFAULT_REVIEW_WINDOW_SECS = 72 hours;
    uint32 internal constant DEFAULT_DECISION_WINDOW_SECS = 7 days;
    uint32 internal constant DEFAULT_REOPEN_EXTENSION_SECS = 72 hours;
    uint16 internal constant DEFAULT_RELEASE_GRACE_BPS = 1000;
    uint16 internal constant DEFAULT_REJECT_FEE_BPS = 2000;
    uint8 internal constant DEFAULT_MAX_REVISIONS = 2;

    uint32 internal constant DEFAULT_MIN_WINDOW_SECS = 24 hours;
    uint32 internal constant DEFAULT_MAX_WINDOW_SECS = 30 days;
    uint16 internal constant DEFAULT_MAX_REJECT_FEE_BPS = 5000;
    uint8 internal constant DEFAULT_MAX_MAX_REVISIONS = 5;

    /// @dev releaseGraceBps is stored as grace + 1, and grace may run to 100% of the claim span.
    uint16 internal constant MAX_STORED_RELEASE_GRACE_BPS = 10001;

    /// @notice Return the task's terms, normalizing a non-terminal pre-rev025 task first.
    function terms(AppStorage storage s, bytes32 taskId) internal returns (ITMPCore.TaskTerms storage t) {
        t = s.taskTerms[taskId];
        if (t.version == 0) _normalize(s, taskId);
    }

    /// @notice Normalize one task if it exists, is not terminal and is still at version 0.
    ///         Does nothing otherwise, so a batch can repeat or include any id.
    function normalize(AppStorage storage s, bytes32 taskId) internal {
        if (s.taskTerms[taskId].version == 0) _normalize(s, taskId);
    }

    /// @dev Writes the record `pendingTerms` describes and seeds the clocks a pre-rev025 task
    ///      never recorded: a delivery awaiting review gets `deliveredAt`, and a bounty or
    ///      benchmark gets `decisionStartAt`, both at the normalization time, so no review window
    ///      or decision deadline has already lapsed at the upgrade.
    function _normalize(AppStorage storage s, bytes32 taskId) private {
        ITMPCore.Task storage task = s.tasks[taskId];
        if (!_normalizable(task)) return;

        ITMPCore.TaskTerms memory t = _legacyDefaults(task);
        s.taskTerms[taskId] = t;

        if (s.taskEvaluatorConfigs[taskId].evaluator == address(0)) {
            bytes4 mode = task.mode;
            if (mode == TMP_BOUNTY || mode == TMP_BENCHMARK) {
                s.taskClocks[taskId].decisionStartAt = uint64(block.timestamp);
            } else if (
                (mode == TMP_CLAIM || mode == TMP_PITCH || mode == TMP_AUCTION) && task.deliverable != bytes32(0)
                    && (task.status == ITMPCore.TaskStatus.Claimed || task.status == ITMPCore.TaskStatus.WorkerSelected)
            ) {
                s.taskClocks[taskId].deliveredAt = uint64(block.timestamp);
            }
        }

        emit ITMPCore.TaskTermsSet(taskId, t);
    }

    /// @notice The record `terms` holds, or would write on first read, for a task. Being a view
    ///         it never writes; a terminal or nonexistent version 0 task reads as stored.
    function pendingTerms(AppStorage storage s, bytes32 taskId) internal view returns (ITMPCore.TaskTerms memory) {
        ITMPCore.TaskTerms memory stored = s.taskTerms[taskId];
        ITMPCore.Task storage task = s.tasks[taskId];
        if (stored.version != 0 || !_normalizable(task)) return stored;
        return _legacyDefaults(task);
    }

    function _normalizable(ITMPCore.Task storage task) private view returns (bool) {
        if (task.requester == address(0)) return false;
        ITMPCore.TaskStatus st = task.status;
        return
            st != ITMPCore.TaskStatus.Accepted && st != ITMPCore.TaskStatus.Expired
                && st != ITMPCore.TaskStatus.Cancelled;
    }

    /// @dev Every term but the stake reads as the protocol default (zero encodings).
    function _legacyDefaults(ITMPCore.Task storage task) private view returns (ITMPCore.TaskTerms memory t) {
        t.version = TERMS_VERSION;
        t.stakeRequired = task.stakeRequired;
        t.stakeBps = task.stakeBps;
    }

    /// @notice The terms the legacy createTask records: protocol defaults with its own stake.
    function defaults(bool stakeRequired, uint16 stakeBps) internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = TERMS_VERSION;
        t.stakeRequired = stakeRequired;
        t.stakeBps = stakeBps;
    }

    /// @notice Revert unless `t` is within the protocol's bounds for a task of `mode`.
    function validate(AppStorage storage s, ITMPCore.TaskTerms memory t, bytes4 mode) internal view {
        if (t.stakeBps > 10000) revert ITMPCore.StakeBpsTooHigh();
        (uint32 minWindow, uint32 maxWindow, uint16 maxRejectFee, uint8 maxRevisions) = bounds(s);
        if (!_windowOk(t.reviewWindowSecs, minWindow, maxWindow)) revert ITMPCore.InvalidTerms();
        if (!_windowOk(t.decisionWindowSecs, minWindow, maxWindow)) revert ITMPCore.InvalidTerms();
        if (!_windowOk(t.reopenExtensionSecs, minWindow, maxWindow)) revert ITMPCore.InvalidTerms();
        if (t.releaseGraceBps > MAX_STORED_RELEASE_GRACE_BPS) revert ITMPCore.InvalidTerms();
        if (t.rejectFeeBps != 0 && t.rejectFeeBps - 1 > maxRejectFee) revert ITMPCore.InvalidTerms();
        if (t.maxRevisions != 0 && t.maxRevisions - 1 > maxRevisions) revert ITMPCore.InvalidTerms();
        if (mode == TMP_AUCTION && t.rejectOutcome == ITMPCore.RejectOutcome.Reopen) revert ITMPCore.InvalidTerms();
    }

    function _windowOk(uint32 secs, uint32 minWindow, uint32 maxWindow) private pure returns (bool) {
        return secs == 0 || (secs >= minWindow && secs <= maxWindow);
    }

    /// @notice The effective bounds: each stored zero reads as its default.
    function bounds(AppStorage storage s)
        internal
        view
        returns (uint32 minWindow, uint32 maxWindow, uint16 maxRejectFee, uint8 maxRevisions)
    {
        ITMPCore.TermsBounds memory b = s.termsBounds;
        minWindow = b.minWindowSecs == 0 ? DEFAULT_MIN_WINDOW_SECS : b.minWindowSecs;
        maxWindow = b.maxWindowSecs == 0 ? DEFAULT_MAX_WINDOW_SECS : b.maxWindowSecs;
        maxRejectFee = b.maxRejectFeeBps == 0 ? DEFAULT_MAX_REJECT_FEE_BPS : b.maxRejectFeeBps - 1;
        maxRevisions = b.maxRevisions == 0 ? DEFAULT_MAX_MAX_REVISIONS : b.maxRevisions - 1;
    }
}
