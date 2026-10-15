// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { IReputationRegistry } from "../interfaces/IReputationRegistry.sol";
import { ITMPReputation } from "../interfaces/ITMPReputation.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title SettlementFacet -- rev025 settlement terms and the settlement calls that read them
/// @notice Holds the per-task settlement terms surface (normalization of pre-rev025 tasks and the
///         terms views) and the settlement calls: rejectSubmission, forfeitAndReopen, cancelTask
///         and refundExpired. Task creation, including the createTask overload taking TaskTerms,
///         stays on CoreFacet; the owner-only bounds setter stays on AdminFacet.
contract SettlementFacet {
    // Private: CoreFacet already serves the public mode getters through the Diamond.
    bytes4 private constant BOUNTY = TMP_BOUNTY;
    bytes4 private constant CLAIM = TMP_CLAIM;
    bytes4 private constant PITCH = TMP_PITCH;
    bytes4 private constant BENCHMARK = TMP_BENCHMARK;
    bytes4 private constant AUCTION = TMP_AUCTION;

    // -------------------------------------------------------------------------
    // Terms
    // -------------------------------------------------------------------------

    /// @notice Normalize the settlement terms of pre-rev025 tasks (permissionless). An id that
    ///         is already normalized, terminal or nonexistent is skipped, so a batch may repeat.
    function normalizeTerms(bytes32[] calldata taskIds) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        for (uint256 i; i < taskIds.length; ++i) {
            LibTerms.normalize(s, taskIds[i]);
        }
    }

    /// @notice Get a task's settlement terms. For a non-terminal task created before rev025 and
    ///         not yet normalized, returns the record normalization would write.
    function getTaskTerms(bytes32 taskId) external view returns (ITMPCore.TaskTerms memory) {
        return LibTerms.pendingTerms(LibAppStorage.appStorage(), taskId);
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

    // -------------------------------------------------------------------------
    // Settlement calls
    // -------------------------------------------------------------------------

    /// @notice Reject a submission from a worker on a bounty or benchmark task.
    ///         The requester is the authenticated actor (pgtrSender).
    ///         Costs the standard relay fee as anti-spam. Once all active submissions
    ///         are rejected, cancelTask becomes available.
    function rejectSubmission(bytes32 taskId, address worker) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.mode != BOUNTY && task.mode != BENCHMARK) revert ITMPCore.InvalidMode();
        if (task.status != ITMPCore.TaskStatus.Open && task.status != ITMPCore.TaskStatus.PendingApproval) {
            revert ITMPCore.TaskNotOpen();
        }
        if (s.taskRejectedWorkers[taskId][worker]) revert ITMPCore.SubmissionAlreadyRejected();
        if (s.taskActiveSubmissionCount[taskId] == 0) revert ITMPCore.NoActiveSubmissions();

        s.taskRejectedWorkers[taskId][worker] = true;
        // Decrement by the worker's full submission count so that workers who submitted
        // multiple times don't leave a phantom count that blocks cancelTask/refundExpired.
        // A worker with zero recorded submissions has nothing to decrement -- crediting a
        // decrement for them would let a requester phantom-clear this guard against a
        // real, still-live submission from a different worker.
        uint256 workerCount = s.taskSubmissionHashes[taskId][worker].length;
        if (workerCount > 0) {
            uint256 active = s.taskActiveSubmissionCount[taskId];
            s.taskActiveSubmissionCount[taskId] = active > workerCount ? active - workerCount : 0;
        }

        emit ITMPCore.SubmissionRejected(taskId, worker);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Forfeit worker's stake and reopen Claim task.
    ///         The requester is the authenticated actor (pgtrSender).
    function forfeitAndReopen(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.mode != CLAIM) revert ITMPCore.NotAClaimTask();
        if (task.status != ITMPCore.TaskStatus.Claimed) revert ITMPCore.TaskNotClaimed();
        if (block.timestamp <= task.expiryTime) revert ITMPCore.TaskNotYetExpired();

        uint256 forfeited = task.stakeAmount;
        address forfeiter = task.worker;
        s.stakeForfeit[taskId] = forfeited;

        task.status = ITMPCore.TaskStatus.Open;
        task.worker = address(0);
        task.stakeAmount = 0;
        s.taskMetadata[taskId].claimedAt = 0;
        if (forfeited > 0) {
            s.totalFeesCollected += forfeited;
            if (!s.usdcToken.transfer(s.feeRecipient, forfeited)) revert ITMPCore.ForfeitTransferFailed();
        }

        if (forfeited > 0) emit ITMPCore.StakeForfeited(taskId, forfeiter, forfeited);
        emit ITMPCore.TaskReopened(taskId);

        LibHooks._onForfeitHooks(taskId, forfeiter, s);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Cancel an open task and refund escrowed reward.
    ///         The requester is the authenticated actor (pgtrSender).
    function cancelTask(bytes32 taskId, uint256 requesterAgentId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (task.mode == AUCTION) {
            if (s.taskBids[taskId].length != 0) revert ITMPCore.BidsExist();
        }
        // Bounty/Benchmark: once workers have active submissions, the requester must accept
        // a winner -- cancelling to recover escrow after work was done is not permitted.
        // Active submission count drops to zero when all submissions have been rejected.
        if ((task.mode == BOUNTY || task.mode == BENCHMARK) && s.taskActiveSubmissionCount[taskId] > 0) {
            revert ITMPCore.SubmissionsExist();
        }

        task.status = ITMPCore.TaskStatus.Cancelled;
        uint256 refundAmount = task.reward;
        address requesterAddr = task.requester;
        if (!s.usdcToken.transfer(requesterAddr, refundAmount)) revert ITMPCore.RefundFailed();
        _refundEvaluatorStake(taskId, requesterAddr, s);

        // Emit requester reputation signal when cancelling after all submissions were rejected.
        // Clean cancellations (no submissions ever) are reputation-neutral and do not emit.
        if ((task.mode == BOUNTY || task.mode == BENCHMARK) && s.taskHasSubmissions[taskId]) {
            emit ITMPCore.RequesterReputation(
                taskId,
                requesterAddr,
                keccak256("cancelled_after_submissions"),
                refundAmount,
                uint32(s.taskActiveSubmissionCount[taskId]),
                false
            );
            if (requesterAgentId != 0 && s.reputationRegistry != address(0)) {
                LibTaskMarket._requireFeedbackGas();
                try IReputationRegistry(s.reputationRegistry)
                    .giveFeedback(
                        requesterAgentId, -50, 0, "tmp.task.requester", _modeName(task.mode), "", "", bytes32(0)
                    ) { }
                catch {
                    emit ITMPReputation.ReputationFeedbackFailed(taskId, requesterAgentId);
                }
            }
        }

        emit ITMPCore.TaskCancelled(taskId, requesterAddr, refundAmount);
        LibHooks._onCancelHooks(taskId, s);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Refund expired task reward to requester.
    ///         NORMATIVE: bypasses all hooks. Callable by anyone.
    ///         Special case: Auction tasks with a selected winner auto-pay the worker.
    // Complexity is inherent: fund recovery must handle every possible task status and mode without hooks.
    // solhint-disable-next-line code-complexity
    function refundExpired(bytes32 taskId, uint256 requesterAgentId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (block.timestamp <= task.expiryTime) revert ITMPCore.TaskNotYetExpired();
        if (task.status == ITMPCore.TaskStatus.Accepted) revert ITMPCore.TaskAlreadyAccepted();
        if (task.status == ITMPCore.TaskStatus.Cancelled) revert ITMPCore.TaskIsCancelled();
        // Expired is a status this function sets itself, so it must be as terminal here as
        // Accepted and Cancelled are. Without this the call is repeatable: it is permissionless
        // permissionless by design, and every guard above still passes on a second call, so each
        // repeat pays the reward again out of the single pooled escrow balance shared by all
        // tasks -- draining unrelated, fully funded tasks.
        if (task.status == ITMPCore.TaskStatus.Expired) revert ITMPCore.TaskAlreadyRefunded();
        // Bounty/Benchmark: if active submissions exist the requester must explicitly accept.
        // refundExpired is blocked so workers are guaranteed their work will be evaluated.
        // Active submission count drops to zero when all submissions have been rejected.
        if ((task.mode == BOUNTY || task.mode == BENCHMARK) && s.taskActiveSubmissionCount[taskId] > 0) {
            revert ITMPCore.SubmissionsExist();
        }

        if (task.mode == AUCTION && task.status == ITMPCore.TaskStatus.Claimed) {
            _refundAuctionClaimed(taskId, task, s);
        } else {
            _refundExpiredNormal(taskId, task, s, requesterAgentId);
        }
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev The evaluator stake is pulled from the requester when the evaluator is assigned, and only
    ///      evaluate(), evaluatorTimeout() and refundExpired() otherwise release it. A task can only be
    ///      cancelled while Open, before any evaluator has had work to do, so the stake goes back to
    ///      the requester who posted it instead of staying in the pooled balance owed to no task.
    function _refundEvaluatorStake(bytes32 taskId, address requesterAddr, AppStorage storage s) private {
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        uint256 stake = evalCfg.evaluatorStake;
        if (stake == 0) return;
        evalCfg.evaluatorStake = 0;
        if (!s.usdcToken.transfer(requesterAddr, stake)) revert ITMPCore.RefundFailed();
        emit ITMPEvaluator.EvaluatorStakeRefunded(taskId, requesterAddr, stake);
    }

    function _refundAuctionClaimed(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private {
        if (task.deliverable == bytes32(0)) {
            // Worker claimed but never submitted a deliverable -- treat expiry as a full
            // refund to the requester, matching the non-auction _refundExpiredNormal path,
            // instead of auto-paying the claimed stake for work that was never delivered.
            task.status = ITMPCore.TaskStatus.Expired;
            uint256 refundAmount = task.reward;
            address requesterAddr = task.requester;
            // Extinguish the recorded liability in the same statement group that decides to pay
            // it out, before any transfer (checks-effects-interactions). The status check above
            // is what actually blocks a repeat today; this is what keeps the books honest if a
            // future status is ever allowed to reach this path, so the escrow pool can never be
            // asked to satisfy the same obligation twice.
            task.reward = 0;

            // An evaluator can be assigned to an auction task while it's still Open. Since
            // the task never reaches Review without a deliverable, evaluate() never runs and
            // never returns the evaluator's stake -- forfeit it here (mirroring the same
            // evaluator-never-acted forfeiture _refundExpiredNormal already applies) instead
            // of leaving it stranded in escrow with no path back to anyone.
            ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
            address timedOutEvaluator = evalCfg.evaluator;
            uint256 evaluatorForfeited = evalCfg.evaluatorStake;
            if (evaluatorForfeited > 0) {
                evalCfg.evaluatorStake = 0;
                evalCfg.evaluator = address(0);
                s.totalFeesCollected += evaluatorForfeited;
            }

            if (!s.usdcToken.transfer(requesterAddr, refundAmount)) revert ITMPCore.RefundFailed();

            if (evaluatorForfeited > 0) {
                if (!s.usdcToken.transfer(s.feeRecipient, evaluatorForfeited)) revert ITMPCore.ForfeitTransferFailed();
                emit ITMPEvaluator.EvaluatorTimedOut(taskId, timedOutEvaluator, evaluatorForfeited);
            }

            emit ITMPCore.TaskExpired(taskId, requesterAddr, refundAmount);
            LibHooks._onExpireHooks(taskId, s);
            return;
        }

        uint256 fee = (task.stakeAmount * task.feeBps) / 10000;
        uint256 workerPayment = task.stakeAmount - fee;
        task.status = ITMPCore.TaskStatus.Accepted;
        s.workerStats[task.worker].completedTasks++;
        if (fee > 0) s.totalFeesCollected += fee;
        if (workerPayment > 0) {
            if (!s.usdcToken.transfer(task.worker, workerPayment)) revert ITMPCore.WorkerPaymentFailed();
        }
        if (fee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, fee)) revert ITMPCore.FeeTransferFailed();
        }
        uint256 refund = task.reward - task.stakeAmount;
        if (refund > 0) {
            if (!s.usdcToken.transfer(task.requester, refund)) revert ITMPCore.RequesterRefundFailed();
        }
        emit ITMPCore.TaskCompleted(taskId, task.requester, task.worker, workerPayment, fee);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: task.worker, amount: task.stakeAmount, rank: 1 });
        ITMPCore.Verdict memory verdict = ITMPCore.Verdict({
            issued: true,
            verdictType: ITMPCore.VerdictType.APPROVE,
            score: 1000,
            confidence: 1000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });
        LibHooks._onCompleteHooks(taskId, s, verdict);
    }

    function _refundExpiredNormal(
        bytes32 taskId,
        ITMPCore.Task storage task,
        AppStorage storage s,
        uint256 requesterAgentId
    ) private {
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];

        // If evaluate() already ran (status Appealing/Disputed), it paid out
        // LibTaskMarket._evaluatorFee to the evaluator immediately.
        // That amount is no longer part of this task's outstanding liability, so it
        // must not be refunded again here on top of the full original reward.
        uint256 evalFeeAlreadyPaid = 0;
        if (
            (task.status == ITMPCore.TaskStatus.Appealing || task.status == ITMPCore.TaskStatus.Disputed)
                && evalCfg.evaluatorFeeBps > 0
        ) {
            evalFeeAlreadyPaid = LibTaskMarket._evaluatorFee(task, evalCfg.evaluatorFeeBps);
        }

        task.status = ITMPCore.TaskStatus.Expired;
        uint256 refundAmount = task.reward - evalFeeAlreadyPaid;
        // See _refundAuctionClaimed: the outstanding reward liability is settled in full here
        // (the evaluator fee portion having already been paid out by evaluate()), so it is
        // zeroed alongside the status rather than left standing for a later read to act on.
        task.reward = 0;

        address timedOutEvaluator = evalCfg.evaluator;
        uint256 evaluatorForfeited = evalCfg.evaluatorStake;
        if (evaluatorForfeited > 0) {
            evalCfg.evaluatorStake = 0;
            evalCfg.evaluator = address(0);
            s.totalFeesCollected += evaluatorForfeited;
        }

        if (!s.usdcToken.transfer(task.requester, refundAmount)) revert ITMPCore.RefundFailed();

        if (task.mode == CLAIM && task.stakeAmount > 0) {
            if (!s.usdcToken.transfer(task.worker, task.stakeAmount)) revert ITMPCore.StakeReturnFailed();
            emit ITMPCore.StakeReturned(taskId, task.worker, task.stakeAmount);
        }

        if (evaluatorForfeited > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, evaluatorForfeited)) revert ITMPCore.ForfeitTransferFailed();
            emit ITMPEvaluator.EvaluatorTimedOut(taskId, timedOutEvaluator, evaluatorForfeited);
        }

        emit ITMPCore.TaskExpired(taskId, task.requester, refundAmount);

        // Emit requester reputation signal for bounty/benchmark expired tasks.
        if (task.mode == BOUNTY || task.mode == BENCHMARK) {
            bytes32 event_ =
                s.taskHasSubmissions[taskId] ? keccak256("expired_after_rejections") : keccak256("expired_no_action");
            emit ITMPCore.RequesterReputation(taskId, task.requester, event_, refundAmount, 0, false);
            if (requesterAgentId != 0 && s.reputationRegistry != address(0)) {
                LibTaskMarket._requireFeedbackGas();
                try IReputationRegistry(s.reputationRegistry)
                    .giveFeedback(
                        requesterAgentId, -50, 0, "tmp.task.requester", _modeName(task.mode), "", "", bytes32(0)
                    ) { }
                catch {
                    emit ITMPReputation.ReputationFeedbackFailed(taskId, requesterAgentId);
                }
            }
        }

        // NORMATIVE: onExpire MUST NOT block fund recovery. Always try-catch (dispatchAfterHooks).
        LibHooks._onExpireHooks(taskId, s);
    }

    function _modeName(bytes4 mode) private pure returns (string memory) {
        if (mode == BOUNTY) return "tmp.mode.bounty";
        if (mode == CLAIM) return "tmp.mode.claim";
        if (mode == PITCH) return "tmp.mode.pitch";
        if (mode == BENCHMARK) return "tmp.mode.benchmark";
        if (mode == AUCTION) return "tmp.mode.auction";
        return "";
    }
}
