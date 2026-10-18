// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { LibReview } from "../libraries/LibReview.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { IReputationRegistry } from "../interfaces/IReputationRegistry.sol";
import { IIdentityRegistry } from "../interfaces/IIdentityRegistry.sol";
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
    // Gas forwarded to the identity registry's ownerOf. A standard ERC-721 lookup needs a few
    // thousand; the cap bounds what a misbehaving registry can burn on a refund.
    uint256 private constant OWNER_OF_GAS = 100_000;

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
        LibReview.requireDecisionOpen(s, taskId, task);

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
        if (task.deliverable != bytes32(0)) revert ITMPCore.DeliveryPending();
        if (block.timestamp <= task.expiryTime) revert ITMPCore.TaskNotYetExpired();

        uint256 forfeited = task.stakeAmount;
        address forfeiter = task.worker;
        s.stakeForfeit[taskId] = forfeited;

        task.status = ITMPCore.TaskStatus.Open;
        task.worker = address(0);
        task.stakeAmount = 0;
        s.taskMetadata[taskId].claimedAt = 0;
        LibTerms.extendOnReopen(s, taskId);
        if (forfeited > 0) LibTerms.payWorkerPenalty(s, taskId, forfeited);

        if (forfeited > 0) emit ITMPCore.StakeForfeited(taskId, forfeiter, forfeited);
        emit ITMPCore.TaskReopened(taskId);

        LibHooks._onForfeitHooks(taskId, forfeiter, s);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice The claimed worker gives up a Claim task before delivery and expiry. The stake
    ///         penalty is zero through the grace period, then rises linearly to the full stake at
    ///         expiry; the rest of the stake returns to the worker and the task reopens.
    function releaseClaim(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.mode != CLAIM) revert ITMPCore.NotAClaimTask();
        if (task.status != ITMPCore.TaskStatus.Claimed) revert ITMPCore.TaskNotClaimed();
        if (worker != task.worker) revert ITMPCore.NotWorker();
        if (block.timestamp >= task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (task.deliverable != bytes32(0)) revert ITMPCore.DeliverableAlreadySet();
        ITMPCore.TaskTerms storage t = LibTerms.terms(s, taskId);
        if (t.releaseAllowed == ITMPCore.ReleaseAllowed.Disallowed) revert ITMPCore.ReleaseNotAllowed();

        uint256 stake = task.stakeAmount;
        uint256 penalty = _releasePenalty(stake, s.taskMetadata[taskId].claimedAt, task.expiryTime, t.releaseGraceBps);
        uint256 returned = stake - penalty;

        task.status = ITMPCore.TaskStatus.Open;
        task.worker = address(0);
        task.stakeAmount = 0;
        s.taskMetadata[taskId].claimedAt = 0;
        s.taskRejectedWorkers[taskId][worker] = true;
        LibTerms.extendOnReopen(s, taskId);
        if (penalty > 0) LibTerms.payWorkerPenalty(s, taskId, penalty);
        if (returned > 0 && !s.usdcToken.transfer(worker, returned)) revert ITMPCore.StakeReturnFailed();

        emit ITMPCore.ClaimReleased(taskId, worker, penalty, returned);
        emit ITMPCore.TaskReopened(taskId);

        LibHooks._onForfeitHooks(taskId, worker, s);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev storedGrace is grace + 1 (0 = default). now < expiry is checked by the caller, so a
    ///      100% grace (graceEnd == expiry) never reaches the division.
    function _releasePenalty(uint256 stake, uint256 claimedAt, uint256 expiry, uint16 storedGrace)
        private
        view
        returns (uint256)
    {
        uint256 grace = storedGrace == 0 ? LibTerms.DEFAULT_RELEASE_GRACE_BPS : storedGrace - 1;
        uint256 graceEnd = claimedAt + ((expiry - claimedAt) * grace) / 10000;
        if (block.timestamp <= graceEnd) return 0;
        return (stake * (block.timestamp - graceEnd)) / (expiry - graceEnd);
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
            LibReview.requireDecisionOpen(s, taskId, task);
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
            if (
                requesterAgentId != 0 && s.reputationRegistry != address(0)
                    && _feedbackAllowed(s, requesterAgentId, requesterAddr)
            ) {
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
    ///         Reverts DeliveryPending while a single-payee task holds an undecided delivery.
    // Complexity is inherent: fund recovery must handle every possible task status and mode without hooks.
    // solhint-disable-next-line code-complexity
    function refundExpired(bytes32 taskId, uint256 requesterAgentId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        // A recorded verdict is never refunded over: it settles as finalizeVerdict would, paying
        // the evaluator its fee, and expiry waits while the appeal window is still open. The call
        // goes back through the diamond before this function takes the reentrancy lock.
        // A dispute the resolver leaves unresolved until expiry lapses, and the original verdict stands.
        if (task.status == ITMPCore.TaskStatus.Disputed && block.timestamp > task.expiryTime) {
            task.status = ITMPCore.TaskStatus.Appealing;
        }
        if (task.status == ITMPCore.TaskStatus.Appealing) {
            if (block.timestamp < s.phaseDeadline[taskId]) revert ITMPCore.AppealWindowStillOpen();
            if (block.timestamp <= task.expiryTime) revert ITMPCore.TaskNotYetExpired();
            ITMPEvaluator(address(this)).finalizeVerdict(taskId);
            return;
        }
        LibGuards._nonReentrantBefore(s);

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
            LibReview.requireDecisionOpen(s, taskId, task);
            revert ITMPCore.SubmissionsExist();
        }
        // A delivery under review (or superseded by an open revision) settles only by accept,
        // rejectDelivery or settleLapsedReview. A delivery with an evaluator (Review) settles by
        // evaluate, or by evaluatorTimeout returning it to the requester's review window; it is
        // never refunded over the work at expiry.
        if (task.deliverable != bytes32(0)) {
            ITMPCore.TaskStatus st = task.status;
            bool underReview = (st == ITMPCore.TaskStatus.Claimed || st == ITMPCore.TaskStatus.WorkerSelected)
                && LibReview.singlePayee(s, taskId, task);
            bool withEvaluator =
                st == ITMPCore.TaskStatus.Review && (task.mode == CLAIM || task.mode == PITCH || task.mode == AUCTION);
            if (underReview || withEvaluator) revert ITMPCore.DeliveryPending();
        }

        if (task.mode == AUCTION && task.status == ITMPCore.TaskStatus.Claimed) {
            _refundAuctionClaimed(taskId, task, s);
        } else {
            _refundExpiredNormal(taskId, task, s, requesterAgentId);
        }
        LibGuards._nonReentrantAfter(s);
    }

    // -------------------------------------------------------------------------
    // Review window (Claim, Pitch and Auction without an evaluator)
    // -------------------------------------------------------------------------

    /// @notice Whether the diamond is inside a state-changing call (its reentrancy lock is held), as
    ///         during settlement while check hooks are dispatched. Lets a hook tell a settlement in
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
    ///         A pre-rev025 delivery not yet normalized reads as if normalized now, since
    ///         normalization starts its window at that moment.
    function reviewDeadline(bytes32 taskId) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
        uint256 start = clock.deliveredAt != 0 ? clock.deliveredAt : clock.revisionDueAt;
        uint256 window = LibReview.reviewWindow(LibTerms.pendingTerms(s, taskId));
        if (start != 0) return start + window;
        return LibTerms.legacyDeliveryAwaitingReview(s, taskId) ? block.timestamp + window : 0;
    }

    /// @notice Reject a delivery inside its review window. The worker is paid the reject fee less
    ///         the platform fee and cannot take the task again; the rest of the escrow reopens the
    ///         task or returns to the requester per the task's rejectOutcome.
    ///         The requester is the authenticated actor (pgtrSender).
    function rejectDelivery(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        ITMPCore.Task storage task = _requireRequesterReview(taskId, s);
        (ITMPCore.TaskTerms storage t, uint256 deadline) = LibReview.requireUnderReview(s, taskId);
        if (block.timestamp > deadline) revert ITMPCore.ReviewWindowClosed();

        address worker = task.worker;
        uint256 rejectFee = _payRejectFee(task, t, worker, s);
        uint256 stakeForfeited = _settleRejectedStake(taskId, task, worker, s);

        s.taskRejectedWorkers[taskId][worker] = true;
        task.deliverable = bytes32(0);
        task.worker = address(0);
        s.taskMetadata[taskId].claimedAt = 0;
        ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
        LibReview.clear(clock);
        clock.revisionsUsed = 0;

        emit ITMPCore.DeliveryRejected(taskId, worker, rejectFee, stakeForfeited);
        _applyRejectOutcome(taskId, task, t);

        LibHooks._onForfeitHooks(taskId, worker, s);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Ask the worker to revise a delivery inside its review window, up to maxRevisions
    ///         times. The worker may resubmit until now + reviewWindowSecs; without a resubmission
    ///         the superseded delivery is back under review from then.
    ///         The requester is the authenticated actor (pgtrSender).
    function requestRevision(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        ITMPCore.Task storage task = _requireRequesterReview(taskId, s);
        (ITMPCore.TaskTerms storage t, uint256 deadline) = LibReview.requireUnderReview(s, taskId);
        if (block.timestamp > deadline) revert ITMPCore.ReviewWindowClosed();
        uint8 maxRevisions = t.maxRevisions == 0 ? LibTerms.DEFAULT_MAX_REVISIONS : t.maxRevisions - 1;
        ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
        if (clock.revisionsUsed >= maxRevisions) revert ITMPCore.RevisionsExhausted();

        uint256 due = block.timestamp + LibReview.reviewWindow(t);
        clock.deliveredAt = 0;
        clock.revisionDueAt = uint64(due);
        uint8 used = clock.revisionsUsed + 1;
        clock.revisionsUsed = used;
        if (task.expiryTime < due) {
            task.expiryTime = due;
            emit ITMPCore.TaskExpiryExtended(taskId, due);
        }

        emit ITMPCore.RevisionRequested(taskId, task.worker, used);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Pay the worker for a delivery whose review window lapsed undecided, exactly as an
    ///         accept would (permissionless). Check hooks are not consulted: a lapsed review must
    ///         settle, so only the onComplete after-hooks run.
    function settleLapsedReview(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        _requireDelivered(taskId, task, s);
        uint256 deadline = LibReview.requireReviewDeadline(s, taskId, LibTerms.terms(s, taskId));
        if (block.timestamp <= deadline) revert ITMPCore.ReviewWindowOpen();

        address worker = task.worker;
        LibReview.clear(s.taskClocks[taskId]);
        task.status = ITMPCore.TaskStatus.Accepted;
        s.workerStats[worker].completedTasks++;
        s.taskAwarded[taskId][worker] = true;

        uint256 payment = _payLapsedReview(taskId, task, worker, s);

        emit ITMPCore.ReviewLapsed(taskId, worker);

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: payment, rank: 1 });
        LibHooks._onCompleteHooks(
            taskId,
            s,
            ITMPCore.Verdict({
                issued: true,
                verdictType: ITMPCore.VerdictType.APPROVE,
                score: 1000,
                confidence: 1000,
                criteriaFlags: new bytes32[](0),
                evidenceHash: bytes32(0),
                awards: awards
            })
        );
        LibGuards._nonReentrantAfter(s);
    }

    function _requireRequesterReview(bytes32 taskId, AppStorage storage s)
        private
        view
        returns (ITMPCore.Task storage task)
    {
        task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (LibGuards._effectiveSender(s) != task.requester) revert ITMPCore.NotRequester();
        _requireDelivered(taskId, task, s);
    }

    function _requireDelivered(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private view {
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != CLAIM && task.mode != PITCH && task.mode != AUCTION) revert ITMPCore.InvalidMode();
        if (s.taskEvaluatorConfigs[taskId].evaluator != address(0)) revert ITMPCore.UseEvaluate();
        if (
            task.deliverable == bytes32(0)
                || (task.status != ITMPCore.TaskStatus.Claimed && task.status != ITMPCore.TaskStatus.WorkerSelected)
        ) revert ITMPCore.DeliverableRequired();
    }

    /// @dev Pays the worker as acceptSubmission does and returns the gross payment.
    function _payLapsedReview(bytes32 taskId, ITMPCore.Task storage task, address worker, AppStorage storage s)
        private
        returns (uint256 payment)
    {
        bool auction = task.mode == AUCTION;
        payment = auction ? task.stakeAmount : task.reward;
        uint256 fee = (payment * task.feeBps) / 10000;
        if (fee > 0) s.totalFeesCollected += fee;
        if (!s.usdcToken.transfer(worker, payment - fee)) revert ITMPCore.WorkerPaymentFailed();
        if (fee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, fee)) revert ITMPCore.FeeTransferFailed();
        }
        if (task.mode == CLAIM && task.stakeAmount > 0) {
            if (!s.usdcToken.transfer(worker, task.stakeAmount)) revert ITMPCore.StakeReturnFailed();
            emit ITMPCore.StakeReturned(taskId, worker, task.stakeAmount);
        }
        if (auction) {
            uint256 refund = s.taskAuctionConfigs[taskId].maxPrice - task.stakeAmount;
            if (refund > 0) {
                if (!s.usdcToken.transfer(task.requester, refund)) revert ITMPCore.AuctionRefundFailed();
            }
        }
        emit ITMPCore.TaskCompleted(taskId, task.requester, worker, payment - fee, fee);
    }

    /// @dev Pays the reject fee (on the reward, or the settled price on an auction) to the
    ///      worker less the platform fee, and takes it out of the task's escrow.
    function _payRejectFee(
        ITMPCore.Task storage task,
        ITMPCore.TaskTerms storage t,
        address worker,
        AppStorage storage s
    ) private returns (uint256 rejectFee) {
        uint256 feeBps = t.rejectFeeBps == 0 ? LibTerms.DEFAULT_REJECT_FEE_BPS : t.rejectFeeBps - 1;
        uint256 base = task.mode == AUCTION ? task.stakeAmount : task.reward;
        rejectFee = (base * feeBps) / 10000;
        if (rejectFee == 0) return 0;
        task.reward -= rejectFee;
        // The platform fee is a share of the reject fee actually paid, so it is taken from the
        // rounded rejectFee rather than recomputed from base.
        // slither-disable-next-line divide-before-multiply
        uint256 platformFee = (rejectFee * task.feeBps) / 10000;
        if (platformFee > 0) s.totalFeesCollected += platformFee;
        if (!s.usdcToken.transfer(worker, rejectFee - platformFee)) revert ITMPCore.WorkerPaymentFailed();
        if (platformFee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, platformFee)) revert ITMPCore.FeeTransferFailed();
        }
    }

    /// @dev A delivered worker's claim stake always comes back on reject, whatever the reject fee:
    ///      stakes are forfeited only for never delivering. Returns the amount forfeited (zero).
    function _settleRejectedStake(bytes32 taskId, ITMPCore.Task storage task, address worker, AppStorage storage s)
        private
        returns (uint256 forfeited)
    {
        uint256 stake = task.mode == CLAIM ? task.stakeAmount : 0;
        if (stake == 0) return 0;
        task.stakeAmount = 0;
        if (!s.usdcToken.transfer(worker, stake)) revert ITMPCore.StakeReturnFailed();
        emit ITMPCore.StakeReturned(taskId, worker, stake);
        return 0;
    }

    /// @dev Reopen hands the remaining escrow to the next worker (Claim) or back to selection
    ///      among the other pitches (Pitch); Refund, and every auction, returns it to the requester.
    function _applyRejectOutcome(bytes32 taskId, ITMPCore.Task storage task, ITMPCore.TaskTerms storage t) private {
        AppStorage storage s = LibAppStorage.appStorage();
        ITMPCore.RejectOutcome outcome = t.rejectOutcome;
        if (task.mode != AUCTION && outcome != ITMPCore.RejectOutcome.Refund) {
            task.status = ITMPCore.TaskStatus.Open;
            LibTerms.extendOnReopen(s, taskId);
            emit ITMPCore.TaskReopened(taskId);
            return;
        }
        task.status = ITMPCore.TaskStatus.Expired;
        uint256 refund = task.reward;
        task.reward = 0;
        if (refund > 0) {
            if (!s.usdcToken.transfer(task.requester, refund)) revert ITMPCore.RefundFailed();
        }
        emit ITMPCore.TaskExpired(taskId, task.requester, refund);
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
        // Only an undelivered auction reaches here: refundExpired reverts DeliveryPending on a
        // delivered one, which settles through the review window instead.
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
    }

    function _refundExpiredNormal(
        bytes32 taskId,
        ITMPCore.Task storage task,
        AppStorage storage s,
        uint256 requesterAgentId
    ) private {
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];

        task.status = ITMPCore.TaskStatus.Expired;
        uint256 refundAmount = task.reward;
        // See _refundAuctionClaimed: the outstanding reward liability is settled in full here, so it is
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
            uint256 stake = task.stakeAmount;
            task.stakeAmount = 0;
            if (task.deliverable == bytes32(0)) {
                // A worker who never delivered forfeits the whole stake, as releaseClaim's penalty
                // reaches the full stake at expiry; otherwise refundExpired would let them keep it.
                s.stakeForfeit[taskId] = stake;
                LibTerms.payWorkerPenalty(s, taskId, stake);
                emit ITMPCore.StakeForfeited(taskId, task.worker, stake);
            } else {
                if (!s.usdcToken.transfer(task.worker, stake)) revert ITMPCore.StakeReturnFailed();
                emit ITMPCore.StakeReturned(taskId, task.worker, stake);
            }
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
            if (
                requesterAgentId != 0 && s.reputationRegistry != address(0)
                    && _feedbackAllowed(s, requesterAgentId, task.requester)
            ) {
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

    /// @dev Requester feedback names a caller-supplied agent ID. With an identity registry set,
    ///      it is sent only when that registry reports the requester as the ID's owner, so a
    ///      requester cannot expire or cancel their own task to aim the -50 at someone else's
    ///      agent. The read is a gas-capped staticcall: a revert (an ID that does not exist), a
    ///      short return or a different owner all skip the feedback. Without a registry, the
    ///      requester must have authenticated the call through a trusted forwarder, since
    ///      refundExpired is permissionless. The RequesterReputation event is emitted either way.
    function _feedbackAllowed(AppStorage storage s, uint256 agentId, address requester) private view returns (bool) {
        address registry = s.identityRegistry;
        if (registry == address(0)) return _sentByRequester(s, requester);
        // Checked first so an under-funded caller cannot run ownerOf out of gas to skip feedback.
        LibTaskMarket._requireFeedbackGas();
        (bool ok, bytes memory ret) =
            registry.staticcall{ gas: OWNER_OF_GAS }(abi.encodeCall(IIdentityRegistry.ownerOf, (agentId)));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) == uint256(uint160(requester));
    }

    function _sentByRequester(AppStorage storage s, address requester) private view returns (bool) {
        return s.trustedForwarders[msg.sender] && LibGuards._effectiveSender(s) == requester;
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
