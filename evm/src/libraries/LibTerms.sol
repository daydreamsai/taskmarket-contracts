// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { TMP_AUCTION, TMP_CLAIM } from "../interfaces/ITMPModes.sol";
import { LibProject } from "./LibProject.sol";

/// @title LibTerms -- rev025 settlement terms: the single reader and validation
/// @dev Every task created since rev025 records version 1 terms at creation, and every task live
///      at the rev025 cut was normalized to version 1 then. A task terminal at the cut was never
///      normalized and keeps reading as all zeros, which no settlement path reaches.
library LibTerms {
    /// @notice Reverts TermsFrozen once a worker is committed (claimed, selected, or past
    ///         delivery) or a Bounty or Benchmark submission is active. A bid alone commits no one.
    function requireTermsOpen(AppStorage storage s, bytes32 taskId, ITMPCore.Task storage task) internal view {
        ITMPCore.TaskStatus st = task.status;
        if (
            st == ITMPCore.TaskStatus.Claimed || st == ITMPCore.TaskStatus.WorkerSelected
                || st == ITMPCore.TaskStatus.PendingApproval || st == ITMPCore.TaskStatus.Review
                || st == ITMPCore.TaskStatus.Appealing || st == ITMPCore.TaskStatus.Disputed
                || s.taskActiveSubmissionCount[taskId] > 0
        ) revert ITMPCore.TermsFrozen();
    }

    /// @dev Rev027: version 2 adds acceptWindowSecs. A task created before rev027 keeps reading 1,
    ///      with acceptWindowSecs zero, which is exactly what version 2 means for a task with no
    ///      reserved worker.
    uint8 internal constant TERMS_VERSION = 2;

    uint32 internal constant DEFAULT_REVIEW_WINDOW_SECS = 72 hours;
    uint32 internal constant DEFAULT_DECISION_WINDOW_SECS = 7 days;
    uint32 internal constant DEFAULT_REOPEN_EXTENSION_SECS = 72 hours;
    uint32 internal constant DEFAULT_RESOLUTION_WINDOW_SECS = 72 hours;
    uint16 internal constant DEFAULT_RELEASE_GRACE_BPS = 1000;
    uint16 internal constant DEFAULT_REJECT_FEE_BPS = 2000;
    uint8 internal constant DEFAULT_MAX_REVISIONS = 2;

    uint32 internal constant DEFAULT_MIN_WINDOW_SECS = 24 hours;
    uint32 internal constant DEFAULT_MAX_WINDOW_SECS = 30 days;
    uint16 internal constant DEFAULT_MAX_REJECT_FEE_BPS = 5000;
    uint8 internal constant DEFAULT_MAX_MAX_REVISIONS = 5;
    uint16 internal constant MAX_STAKE_BPS = 5000;

    // Rev027: a reserved worker's accept window. The default matches the other 72-hour window
    // defaults above; the bounds are compiled in, not owner-set.
    uint32 internal constant DEFAULT_ACCEPT_WINDOW_SECS = 72 hours;
    uint32 internal constant MIN_ACCEPT_WINDOW_SECS = 1 hours;
    uint32 internal constant MAX_ACCEPT_WINDOW_SECS = 30 days;

    /// @dev releaseGraceBps is stored as grace + 1, and grace may run to 100% of the claim span.
    uint16 internal constant MAX_STORED_RELEASE_GRACE_BPS = 10001;

    /// @notice Return the task's terms.
    function terms(AppStorage storage s, bytes32 taskId) internal view returns (ITMPCore.TaskTerms storage) {
        return s.taskTerms[taskId];
    }

    /// @notice Send a worker-stake penalty to the task's penaltyTo destination: the requester, or
    ///         the fee recipient booked as protocol fees. Worker stakes only; evaluator stakes keep
    ///         their own destinations. The caller clears the stake and emits its event.
    function payWorkerPenalty(AppStorage storage s, bytes32 taskId, uint256 amount) internal {
        if (amount == 0) return;
        bool ok;
        if (terms(s, taskId).penaltyTo == ITMPCore.PenaltyTo.Protocol) {
            s.totalFeesCollected += amount;
            ok = s.usdcToken.transfer(s.feeRecipient, amount);
        } else {
            // Rev028: a project task's penalty goes to its project, like any other requester money.
            ok = LibProject.payRequester(s, taskId, amount);
        }
        if (!ok) revert ITMPCore.ForfeitTransferFailed();
    }

    /// @notice expiryTime = max(expiryTime, now + resolutionWindowSecs) when a verdict is appealed, so
    ///         the dispute resolver has the whole window before refundExpired can lapse the dispute.
    function extendOnAppeal(AppStorage storage s, bytes32 taskId) internal {
        uint32 secs = terms(s, taskId).resolutionWindowSecs;
        uint256 newExpiry = block.timestamp + (secs == 0 ? DEFAULT_RESOLUTION_WINDOW_SECS : secs);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.expiryTime < newExpiry) {
            task.expiryTime = newExpiry;
            emit ITMPCore.TaskExpiryExtended(taskId, newExpiry);
        }
    }

    /// @notice expiryTime = max(expiryTime, now + reopenExtensionSecs), so a reopened task can be claimed.
    function extendOnReopen(AppStorage storage s, bytes32 taskId) internal {
        uint32 secs = terms(s, taskId).reopenExtensionSecs;
        uint256 ext = secs == 0 ? DEFAULT_REOPEN_EXTENSION_SECS : secs;
        ITMPCore.Task storage task = s.tasks[taskId];
        uint256 newExpiry = block.timestamp + ext;
        if (task.expiryTime < newExpiry) {
            task.expiryTime = newExpiry;
            emit ITMPCore.TaskExpiryExtended(taskId, newExpiry);
        }
    }

    /// @notice Smallest stake a claim must post under `terms`: ceil(reward * stakeBps / 10000).
    function minStake(ITMPCore.TaskTerms memory terms, uint256 reward) internal pure returns (uint256) {
        if (!terms.stakeRequired) return 0;
        return (reward * terms.stakeBps + 9999) / 10000;
    }

    /// @notice Rev027: the effective accept window of terms `t` on a task with a reserved worker.
    function acceptWindow(ITMPCore.TaskTerms memory t) internal pure returns (uint256) {
        return t.acceptWindowSecs == 0 ? DEFAULT_ACCEPT_WINDOW_SECS : t.acceptWindowSecs;
    }

    /// @notice Rev027: the accept-by time of a task with a reserved worker: its creation time plus
    ///         its accept window. Zero for a task with no reserved worker.
    function acceptBy(AppStorage storage s, bytes32 taskId) internal view returns (uint256) {
        if (s.reservedWorkers[taskId] == address(0)) return 0;
        return s.taskMetadata[taskId].createdAt + acceptWindow(s.taskTerms[taskId]);
    }

    /// @notice Revert unless `t` is within the protocol's bounds for a task of `mode`.
    /// @dev Rev027: `reserved` is whether the task is being created with a reserved worker. Only a
    ///      Claim task may have one; its accept window is 0 (the default) or within the bounds,
    ///      and a rejected delivery refunds, so a Reopen reject outcome is refused. A task without
    ///      a reserved worker must leave acceptWindowSecs at 0.
    function validate(AppStorage storage s, ITMPCore.TaskTerms memory t, bytes4 mode, bool reserved) internal view {
        if (reserved) {
            if (mode != TMP_CLAIM) revert ITMPCore.InvalidMode();
            uint32 w = t.acceptWindowSecs;
            if (w != 0 && (w < MIN_ACCEPT_WINDOW_SECS || w > MAX_ACCEPT_WINDOW_SECS)) revert ITMPCore.InvalidTerms();
            if (t.rejectOutcome == ITMPCore.RejectOutcome.Reopen) revert ITMPCore.InvalidTerms();
        } else if (t.acceptWindowSecs != 0) {
            revert ITMPCore.InvalidTerms();
        }
        if (t.stakeBps > MAX_STAKE_BPS) revert ITMPCore.StakeBpsTooHigh();
        (uint32 minWindow, uint32 maxWindow, uint16 maxRejectFee, uint8 maxRevisions) = bounds(s);
        if (!_windowOk(t.reviewWindowSecs, minWindow, maxWindow)) revert ITMPCore.InvalidTerms();
        if (!_windowOk(t.decisionWindowSecs, minWindow, maxWindow)) revert ITMPCore.InvalidTerms();
        if (!_windowOk(t.reopenExtensionSecs, minWindow, maxWindow)) revert ITMPCore.InvalidTerms();
        if (!_windowOk(t.resolutionWindowSecs, minWindow, maxWindow)) revert ITMPCore.InvalidTerms();
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
