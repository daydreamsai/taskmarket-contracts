// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibProject } from "../libraries/LibProject.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibHooksV2 } from "../libraries/LibHooksV2.sol";
import { LibSettlement } from "../libraries/LibSettlement.sol";
import { LibPayout } from "../libraries/LibPayout.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { TMP_BOUNTY, TMP_BENCHMARK, TMP_CLAIM, TMP_PITCH, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title EvaluatorFacet — ERC-8195 evaluator flow: assign, evaluate, appeal, finalize, dispute
contract EvaluatorFacet {
    bytes4 private constant BOUNTY = TMP_BOUNTY;
    bytes4 private constant BENCHMARK = TMP_BENCHMARK;
    bytes4 private constant CLAIM = TMP_CLAIM;
    bytes4 private constant PITCH = TMP_PITCH;
    bytes4 private constant AUCTION = TMP_AUCTION;

    /// @notice Assign an evaluator to an open task that was created without one.
    ///         Only the requester may call this, only while the task is Open.
    ///         A stake arrives with the forwarded payment, which the forwarder must report and which
    ///         must equal stakeAmount; this function never calls transferFrom on the requester.
    ///         A project task draws the stake from its project's pool instead.
    /// @dev A requester who knows at creation time that the task needs an evaluator should pass
    ///      the configuration to `createTask` instead: the task is claimable the instant
    ///      `createTask` mines, so a second transaction races the first worker to claim and can
    ///      lose (`TaskNotOpen`). This function exists for the case that genuinely needs it --
    ///      deciding on an evaluator after the task is already live -- and the `Open` gate below
    ///      is correct for that case, because appointing an evaluator after a worker has claimed
    ///      would change the terms the worker committed to.
    /// @param taskId               Task identifier
    /// @param evaluator            Evaluator address
    /// @param stakeAmount          Evaluator stake: the relayed payment through a paying forwarder, or drawn from the project pool (0 = no stake)
    /// @param feeBps               Evaluator fee in basis points (max 10000)
    /// @param evaluationWindowSecs Seconds from assignment for evaluator to submit verdict
    /// @param appealWindowSecs     Seconds after verdict for worker to appeal
    /// @param disputeResolver      Address that may resolve disputes; address(0) if none
    function assignEvaluator(
        bytes32 taskId,
        address evaluator,
        uint256 stakeAmount,
        uint16 feeBps,
        uint32 evaluationWindowSecs,
        uint32 appealWindowSecs,
        address disputeResolver
    ) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        LibGuards._requireRequester(s, taskId, requester);
        LibTerms.requireTermsOpen(s, taskId, task);
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        LibHooks._before(s, taskId, LibHooksV2.A_ASSIGN_EVALUATOR, evaluator, bytes32(0));
        // Rev028: neither the requester of record nor, on a project task, its operator or the
        // project owner may judge the task they can act for.
        if (LibProject.isActingParty(s, taskId, evaluator)) revert ITMPCore.EvaluatorCannotBeRequester();
        if (LibProject.isActingParty(s, taskId, disputeResolver)) revert ITMPCore.DisputeResolverCannotBeRequester();
        // Rev028: an evaluator is a term of the offer, so it is frozen while a reservation is
        // pending, exactly as updateTask freezes the reward and deadlines.
        if (s.reservedWorkers[taskId] != address(0) && block.timestamp <= LibTerms.acceptBy(s, taskId)) {
            revert ITMPCore.ReservationPending();
        }

        // Rev027: a project task draws the stake from its project's pool (LibProject.topUp), and
        // projectPrepaid tells the funding check below to expect it with no forwarded payment.
        bool drawn = LibProject.topUp(s, taskId, requester, stakeAmount) != stakeAmount;
        if (drawn) s.projectPrepaid = stakeAmount;

        // Remaining validation, storage writes, stake pull and event live in LibTaskMarket so
        // this path and createTask's cannot drift apart. See _applyEvaluatorConfig.
        LibTaskMarket._applyEvaluatorConfig(
            taskId,
            requester,
            ITMPCore.TaskEvaluatorConfig({
                evaluator: evaluator,
                evaluatorStake: stakeAmount,
                evaluatorFeeBps: feeBps,
                evaluationWindow: evaluationWindowSecs,
                appealWindow: appealWindowSecs,
                disputeResolver: disputeResolver
            }),
            0,
            s
        );
        if (drawn) s.projectPrepaid = 0;

        LibEscrow.book(s, taskId, requester, ITMPEscrow.Component.EvaluatorStake, false);
        LibHooks._observe(s, taskId, LibHooksV2.A_ASSIGN_EVALUATOR, true);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Submit an evaluation verdict.
    ///         Only task.evaluator may call this.
    /// @param taskId       Task identifier
    /// @param verdictType  Approved, Rejected, or Partial
    /// @param score        Quality score (0-10000)
    /// @param confidence   Evaluator confidence (0-10000)
    /// @param evidenceHash keccak256 of off-chain evidence data
    /// @param awards       Per-worker award breakdown for Partial verdicts
    function evaluate(
        bytes32 taskId,
        ITMPCore.VerdictType verdictType,
        uint16 score,
        uint16 confidence,
        bytes32 evidenceHash,
        ITMPCore.Award[] calldata awards
    ) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarderNoPayment(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);
        uint256 balanceBefore = LibEscrow.balance(s);

        address evaluatorAddr = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (evaluatorAddr != evalCfg.evaluator) revert ITMPCore.NotEvaluator();
        // Rev030: ownership can move to the evaluator after it was assigned; an acting party never
        // judges its own task.
        if (LibProject.isActingParty(s, taskId, evaluatorAddr)) revert ITMPCore.EvaluatorCannotBeRequester();
        if (!(task.status == ITMPCore.TaskStatus.Review
                    || ((task.mode == BOUNTY || task.mode == BENCHMARK)
                        && (task.status == ITMPCore.TaskStatus.Open
                            || task.status == ITMPCore.TaskStatus.PendingApproval)))) revert ITMPCore.WrongStatusForEvaluation();
        // The mirror of evaluatorTimeout's boundary: a verdict is allowed up to and including the
        // deadline, the timeout strictly after it, so only one of them can succeed at any moment.
        if (task.status == ITMPCore.TaskStatus.Review && block.timestamp > s.phaseDeadline[taskId]) {
            revert ITMPCore.EvaluationWindowClosed();
        }
        // Rev030: a Bounty or Benchmark has the same boundary, at its evaluation deadline.
        if (task.status != ITMPCore.TaskStatus.Review && block.timestamp > _submissionsDeadline(task, taskId, s)) {
            revert ITMPCore.EvaluationWindowClosed();
        }

        _validateAwardRecipients(task, taskId, awards, s);
        LibHooksV2.snap(taskId, uint8(task.status));

        ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
        v.issued = true;
        v.verdictType = verdictType;
        v.score = score;
        v.confidence = confidence;
        v.evidenceHash = evidenceHash;
        delete v.awards;
        for (uint256 i; i < awards.length; ++i) {
            v.awards.push(awards[i]);
        }

        if (task.mode == BOUNTY || task.mode == BENCHMARK) {
            for (uint256 i; i < awards.length; ++i) {
                if (awards[i].amount == 0) continue;
                task.worker = awards[i].worker;
                break;
            }
        }

        uint256 stakeReturn = evalCfg.evaluatorStake;
        evalCfg.evaluatorStake = 0;
        uint256 appealDeadline = block.timestamp + evalCfg.appealWindow;
        s.phaseDeadline[taskId] = appealDeadline;
        LibProject.extendExpiry(s, taskId, appealDeadline);
        task.status = ITMPCore.TaskStatus.Appealing;

        LibHooks._checkEvaluateHooks(taskId, evaluatorAddr, s);

        emit ITMPEvaluator.TaskEvaluated(taskId, evaluatorAddr, uint8(verdictType), score);

        if (stakeReturn > 0) {
            if (!s.usdcToken.transfer(evalCfg.evaluator, stakeReturn)) {
                revert ITMPCore.EvaluatorPaymentFailed();
            }
        }
        LibEscrow.release(s, taskId, balanceBefore);
        LibHooks._observe(s, taskId, LibHooksV2.A_EVALUATE, true);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Appeal the evaluator's verdict.
    ///         Only task.worker may call this while status == Appealing and within the window.
    function appeal(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarderNoPayment(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);
        LibHooksV2.snap(taskId, uint8(s.tasks[taskId].status));

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        // Bounty/Benchmark verdicts issued with an empty awards array leave task.worker
        // unset even though real submitters exist in taskSubmissionHashes (populated by
        // submitWork independently of task.worker). Fall back to that per-worker record
        // so an empty-awards verdict is still appealable by whoever actually submitted,
        // instead of being permanently unappealable by construction. Gated on task.worker
        // still being unset: once a verdict has awarded someone, only that worker may
        // appeal -- otherwise any other past submitter (including one already rejected
        // pre-evaluation) could appeal a verdict they were never part of, stalling a
        // legitimately-awarded worker's payout.
        bool authorized = worker == task.worker;
        if (!authorized && task.worker == address(0) && (task.mode == BOUNTY || task.mode == BENCHMARK)) {
            authorized = s.taskSubmissionHashes[taskId][worker].length > 0;
        }
        if (!authorized) revert ITMPCore.NotWorker();
        // Rev030: a worker that became an acting party after its claim cannot appeal its own task.
        LibProject.requireNotActingParty(s, taskId, worker);
        if (task.status != ITMPCore.TaskStatus.Appealing) revert ITMPCore.NotInAppealingState();
        if (block.timestamp >= s.phaseDeadline[taskId]) revert ITMPCore.AppealWindowClosed();
        // Only the dispute resolver can settle a Disputed task, and nothing can call
        // resolveDispute as the zero address. Without one, an appeal would freeze the verdict
        // until expiry, when refundExpired pays the requester and the worker loses any award.
        // Refusing the appeal leaves the verdict to finalize when the appeal window closes.
        address dr = s.taskEvaluatorConfigs[taskId].disputeResolver;
        if (dr == address(0)) revert ITMPCore.NoDisputeResolver();
        LibHooks._before(s, taskId, LibHooksV2.A_APPEAL, worker, bytes32(0));

        task.status = ITMPCore.TaskStatus.Disputed;
        // Rev030: the resolver's window is recorded apart from the clamped expiry; refundExpired
        // waits for it before lapsing the dispute.
        s.phaseDeadline[taskId] = LibTerms.extendOnAppeal(s, taskId);
        emit ITMPEvaluator.TaskAppealed(taskId, worker);
        emit ITMPEvaluator.TaskDisputed(taskId, dr);

        LibHooks._observe(s, taskId, LibHooksV2.A_APPEAL, true);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Finalize the verdict after the appeal window has expired.
    ///         Anyone may call this once block.timestamp >= appeal deadline.
    function finalizeVerdict(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._requireNoRelayedPayment(s);
        LibGuards._nonReentrantBefore(s);
        LibHooksV2.snap(taskId, uint8(s.tasks[taskId].status));
        uint256 balanceBefore = LibEscrow.balance(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.status != ITMPCore.TaskStatus.Appealing) revert ITMPCore.NotInAppealingState();
        if (block.timestamp < s.phaseDeadline[taskId]) revert ITMPCore.AppealWindowStillOpen();

        ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
        if (!v.issued) revert ITMPCore.NoVerdictIssued();

        if (v.verdictType == ITMPCore.VerdictType.REJECT) {
            _finalizeReject(taskId, task, s);
        } else {
            // Past expiry no hook may block settlement, as refundExpired never runs hooks:
            // a reverting hook would otherwise lock the escrow for good.
            _payAwards(taskId, task, v, s, true, block.timestamp <= task.expiryTime);
        }
        LibEscrow.release(s, taskId, balanceBefore);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev REJECT pays the evaluator fee and refunds the remainder to the requester in full, so the task
    ///      is done -- not reopened. Terminal status here mirrors cancelTask's pattern (refund +
    ///      Cancelled), and dispatches the same _onCancelHooks release so any reward-hook reservation
    ///      is cleaned up rather than left dangling. Reopening would advertise the task as
    ///      re-claimable with no escrow left behind it.
    function _finalizeReject(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private {
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        uint256 evalFee = LibTaskMarket._evaluatorFee(task, evalCfg.evaluatorFeeBps);
        uint256 refund = task.reward - evalFee;
        address requesterAddr = task.requester;
        address evaluatorAddr = evalCfg.evaluator;
        address claimant = task.worker;
        task.status = ITMPCore.TaskStatus.Cancelled;
        task.worker = address(0);
        task.deliverable = bytes32(0);
        evalCfg.evaluator = address(0);
        evalCfg.evaluationWindow = 0;
        evalCfg.appealWindow = 0;
        if (refund > 0) {
            if (!LibProject.payRequester(s, taskId, refund)) revert ITMPCore.RefundFailed();
        }
        _forfeitClaimStake(taskId, task, claimant, s);
        if (evalFee > 0) {
            if (!s.usdcToken.transfer(evaluatorAddr, evalFee)) revert ITMPCore.EvaluatorPaymentFailed();
            LibSettlement.add(taskId, LibSettlement.EVALUATOR_FEE, evalFee);
        }
        emit ITMPCore.TaskCancelled(taskId, requesterAddr, refund);
        if (block.timestamp <= task.expiryTime) LibHooks._onCancelHooksStrict(taskId);
        else LibHooks._onCancelHooks(taskId, s);
    }

    /// @dev Settles a Claim worker's stake when a verdict or a dispute resolution ends the task.
    ///      Award recipients are pinned to task.worker for Claim, so task.worker is the claimant.
    ///      A worker the evaluator or resolver awarded something gets the stake back, as
    ///      acceptSubmission does; a worker the evaluator or resolver awarded nothing forfeits it.
    ///      Rev030: `awarded` reflects the evaluator's or resolver's own awards, not a transforming
    ///      hook's replacement of them. Auction tasks reuse stakeAmount
    ///      for the accepted price, which is not a stake.
    function _settleClaimStake(bytes32 taskId, ITMPCore.Task storage task, bool awarded, AppStorage storage s) private {
        if (task.mode != CLAIM || task.stakeAmount == 0) return;
        if (!awarded) {
            _forfeitClaimStake(taskId, task, task.worker, s);
            return;
        }
        uint256 stake = task.stakeAmount;
        task.stakeAmount = 0;
        if (!s.usdcToken.transfer(task.worker, stake)) revert ITMPCore.StakeReturnFailed();
        emit ITMPCore.StakeReturned(taskId, task.worker, stake);
    }

    /// @dev The stake exists to make submitting work that will not pass costly, so work an
    ///      evaluator rejects forfeits it. It goes to the task's penaltyTo destination.
    function _forfeitClaimStake(bytes32 taskId, ITMPCore.Task storage task, address claimant, AppStorage storage s)
        private
    {
        if (task.mode != CLAIM) return;
        uint256 stake = task.stakeAmount;
        if (stake == 0) return;
        task.stakeAmount = 0;
        s.stakeForfeit[taskId] = stake;
        LibTerms.payWorkerPenalty(s, taskId, stake);
        emit ITMPCore.StakeForfeited(taskId, claimant, stake);
    }

    /// @notice Resolve a disputed task.
    ///         Only task.disputeResolver may call this while status == Disputed.
    ///         Supports direct call or call via trusted forwarder.
    /// @param taskId      Task identifier
    /// @param verdictType Resolution type (must not be REJECT — must award workers)
    /// @param awards      Per-worker award breakdown
    function resolveDispute(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] calldata awards)
        external
    {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._requireNoRelayedPayment(s);
        LibGuards._nonReentrantBefore(s);
        uint256 balanceBefore = LibEscrow.balance(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.status != ITMPCore.TaskStatus.Disputed) revert ITMPCore.NotInDisputedState();
        address caller = s.trustedForwarders[msg.sender] ? LibGuards._effectiveSender(s) : msg.sender;
        if (caller != s.taskEvaluatorConfigs[taskId].disputeResolver) revert ITMPCore.NotDisputeResolver();
        // Rev030: as for evaluate, a resolver that became an acting party after assignment is refused.
        if (LibProject.isActingParty(s, taskId, caller)) revert ITMPCore.DisputeResolverCannotBeRequester();
        if (verdictType == ITMPCore.VerdictType.REJECT) revert ITMPCore.DisputeResolutionMustAwardWorkers();
        if (awards.length == 0) revert ITMPCore.AwardsRequired();
        _validateAwardRecipients(task, taskId, awards, s);

        ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
        bool upheld = _sameVerdict(v, verdictType, awards);
        v.verdictType = verdictType;
        delete v.awards;
        for (uint256 i; i < awards.length; ++i) {
            v.awards.push(awards[i]);
        }

        // A task's beforeAccept is best effort on a resolution (see _payAwards), so the requester's
        // hook cannot veto the resolver's decision there.
        _payAwards(taskId, task, v, s, upheld, true);
        LibEscrow.release(s, taskId, balanceBefore);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev A resolution upholds the verdict only when it repeats it exactly: same type and the same
    ///      awards in the same order. A REJECT can never be upheld, since a resolution must award.
    function _sameVerdict(
        ITMPCore.Verdict storage v,
        ITMPCore.VerdictType verdictType,
        ITMPCore.Award[] calldata awards
    ) private view returns (bool) {
        if (v.verdictType != verdictType || v.awards.length != awards.length) {
            return false;
        }
        for (uint256 i; i < awards.length; ++i) {
            if (v.awards[i].worker != awards[i].worker || v.awards[i].amount != awards[i].amount) return false;
        }
        return true;
    }

    /// @notice Trigger evaluator timeout after the evaluation window expires.
    ///         Permissionless: anyone may call this directly once the window has passed. It
    ///         reads no caller, so it does not require the PGTR forwarder (rev027).
    ///         Rev030: a Bounty or Benchmark never enters Review, so it times out from Open (or
    ///         PendingApproval) once it has live submissions and its evaluation deadline,
    ///         `max(expiryTime, decisionStartAt) + evaluationWindow`, has passed. The evaluator is
    ///         cleared and the requester's decision window (decisionWindowSecs) starts now, after
    ///         which requesterTimeout refunds the requester.
    function evaluatorTimeout(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._requireNoRelayedPayment(s);
        LibGuards._nonReentrantBefore(s);
        LibHooksV2.snap(taskId, uint8(s.tasks[taskId].status));
        uint256 balanceBefore = LibEscrow.balance(s);

        // Permissionless: once the evaluation window has passed anyone, including the worker, may
        // time out the evaluator, so a requester cannot leave a delivered task stuck in Review.
        ITMPCore.Task storage task = s.tasks[taskId];
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        address timedOutEvaluator = evalCfg.evaluator;
        bytes4 mode = task.mode;
        bool submissions = (mode == BOUNTY || mode == BENCHMARK)
            && (task.status == ITMPCore.TaskStatus.Open || task.status == ITMPCore.TaskStatus.PendingApproval);
        if (submissions) {
            if (timedOutEvaluator == address(0)) revert ITMPCore.NotInReviewState();
            if (s.taskActiveSubmissionCount[taskId] == 0) revert ITMPCore.NoActiveSubmissions();
            if (block.timestamp <= _submissionsDeadline(task, taskId, s)) {
                revert ITMPCore.EvaluationWindowNotExpired();
            }
            // The requester's decision window runs from the timeout: decisionLapsed reads
            // max(expiryTime, decisionStartAt), and the timeout is after expiryTime.
            s.taskClocks[taskId].decisionStartAt = uint64(block.timestamp);
        } else {
            if (task.status != ITMPCore.TaskStatus.Review) revert ITMPCore.NotInReviewState();
            if (block.timestamp <= s.phaseDeadline[taskId]) revert ITMPCore.EvaluationWindowNotExpired();
        }

        uint256 forfeited = evalCfg.evaluatorStake;
        evalCfg.evaluatorStake = 0;
        evalCfg.evaluator = address(0);
        if ((mode == CLAIM || mode == PITCH || mode == AUCTION) && task.deliverable != bytes32(0)) {
            // A delivered single-payee task goes back under the requester's review window from now,
            // so the requester cannot time out the evaluator and refund at expiry over the work.
            task.status = mode == PITCH ? ITMPCore.TaskStatus.WorkerSelected : ITMPCore.TaskStatus.Claimed;
            ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
            clock.deliveredAt = uint64(block.timestamp);
            clock.revisionDueAt = 0;
        } else {
            task.status = ITMPCore.TaskStatus.PendingApproval;
        }

        if (forfeited > 0) {
            s.totalFeesCollected += forfeited;
            if (!s.usdcToken.transfer(s.feeRecipient, forfeited)) revert ITMPCore.ForfeitTransferFailed();
        }

        emit ITMPEvaluator.EvaluatorTimedOut(taskId, timedOutEvaluator, forfeited);
        LibEscrow.release(s, taskId, balanceBefore);
        // Rev028: the evaluator's forfeited stake joins the task's running forfeited total.
        LibSettlement.add(taskId, LibSettlement.FORFEITED, forfeited);
        LibHooks._onEvaluatorForfeit(s, taskId, timedOutEvaluator);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev Rev030: the evaluator's deadline on a Bounty or Benchmark, which settles through
    ///      submissions and never enters Review: `max(expiryTime, decisionStartAt) +
    ///      evaluationWindow`, the start LibReview.decisionLapsed uses for a task without an
    ///      evaluator. decisionStartAt is zero here unless the task was normalized at the rev025 cut.
    function _submissionsDeadline(ITMPCore.Task storage task, bytes32 taskId, AppStorage storage s)
        private
        view
        returns (uint256)
    {
        uint256 start = task.expiryTime;
        uint256 seeded = s.taskClocks[taskId].decisionStartAt;
        if (seeded > start) start = seeded;
        return start + s.taskEvaluatorConfigs[taskId].evaluationWindow;
    }

    /// @dev Ensures every award recipient is a legitimate party for this task: the locked
    ///      worker for Claim/Pitch/Auction, or an address that actually submitted work for
    ///      Bounty/Benchmark (mirrors AcceptanceFacet._resolveDeliverables' submission
    ///      check). Called by both evaluate() and resolveDispute() before their respective
    ///      awards arrays are committed to storage, so a caller-supplied awards array can
    ///      never redirect payout to a party who was never actually the worker/submitter.
    ///      Zero-amount awards are skipped -- they never trigger a transfer or touch
    ///      task.worker, so their recipient is inert. A non-zero award to address(0) reverts
    ///      here rather than at _payAwards: the verdict is one-shot on chain, so letting it
    ///      be stored would move the task to Appealing and then revert finalizeVerdict
    ///      permanently, stranding the escrow. For the same reason the non-zero award total
    ///      must fit the award budget (reward less the evaluator fee), or it reverts
    ///      AwardsExceedEscrow. Rev030: a non-zero Bounty or Benchmark award must have rank >= 1
    ///      (InvalidAwardRank), and a verdict of any mode may carry at most the chain's winner
    ///      cap of awards (TooManyWinners).
    function _validateAwardRecipients(
        ITMPCore.Task storage task,
        bytes32 taskId,
        ITMPCore.Award[] calldata awards,
        AppStorage storage s
    ) private view {
        bool bountyLike = task.mode == BOUNTY || task.mode == BENCHMARK;
        // Rev030: the cap is per chain (s.maxSubmissionWinners, 50 when unset), on every mode.
        if (awards.length > LibTaskMarket._maxSubmissionWinners(s)) revert ITMPCore.TooManyWinners();
        uint256 total = 0;
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].amount == 0) continue;
            total += awards[i].amount;
            address worker = awards[i].worker;
            if (worker == address(0)) revert ITMPCore.InvalidAwardRecipient();
            if (bountyLike) {
                // Rev030: a paid contest place is ranked from 1; rank 0 names no place.
                if (awards[i].rank == 0) revert ITMPCore.InvalidAwardRank();
                if (s.taskSubmissionHashes[taskId][worker].length == 0) revert ITMPCore.SubmissionNotFound();
            } else if (worker != task.worker) {
                revert ITMPCore.WorkerMismatch();
            }
        }
        // Same bound _payAwards applies at settlement. Checking it here keeps a verdict that can
        // never finalize from being stored; the settlement check stays as a backstop.
        if (total > _awardBudget(task, taskId, s)) revert ITMPCore.AwardsExceedEscrow();
    }

    /// @dev The most a verdict may award: the task's reward less the evaluator fee. For an auction
    ///      the base is the accepted price (stakeAmount), not the price cap held in task.reward,
    ///      matching the base _evaluatorFee uses.
    function _awardBudget(ITMPCore.Task storage task, bytes32 taskId, AppStorage storage s)
        private
        view
        returns (uint256)
    {
        uint256 base = task.mode == AUCTION ? task.stakeAmount : task.reward;
        return base - LibTaskMarket._evaluatorFee(task, s.taskEvaluatorConfigs[taskId].evaluatorFeeBps);
    }

    // Complexity is inherent: iterates N winners applying per-winner fee, transfer, hook, and event; handles excess refund.
    // solhint-disable-next-line code-complexity
    function _payAwards(
        bytes32 taskId,
        ITMPCore.Task storage task,
        ITMPCore.Verdict storage v,
        AppStorage storage s,
        bool feeToEvaluator,
        bool runCheckHooks
    ) private {
        // Validate recipients before touching any state.
        uint256 awardLen = v.awards.length;
        for (uint256 i; i < awardLen; i++) {
            if (v.awards[i].amount > 0 && v.awards[i].worker == address(0)) {
                revert ITMPCore.InvalidAwardRecipient();
            }
        }

        uint256 remaining = _awardBudget(task, taskId, s);
        ITMPCore.Verdict memory verdictMem = s.taskVerdicts[taskId];
        // Rev028: a dispute resolution is settling a Disputed task; hooks are shown that state.
        bool disputed = task.status == ITMPCore.TaskStatus.Disputed;
        LibHooksV2.snap(taskId, uint8(task.status));

        // Rev028: a V2 task's beforeAccept (vetoable on the accept path, best effort on dispute
        // resolution and after expiry), and the transforming hook's result if any.
        uint16 hookFeeBps = 0;
        address feeHook = address(0);
        // Rev030: the Claim stake follows what the evaluator or resolver awarded, recorded before a
        // transforming hook's result replaces the awards, so a hook that zeroes an approved award
        // cannot forfeit the worker's stake to the requester. Acceptance returns it the same way.
        bool verdictAwarded = _anyAward(verdictMem.awards);
        {
            (bool changed, ITMPCore.Award[] memory result, uint16 bps, address hook) =
                LibHooks._acceptV2(s, taskId, verdictMem, runCheckHooks && !disputed, disputed, remaining);
            if (changed) {
                if (result.length > 0) {
                    verdictMem.awards = result;
                    // getVerdict reports the awards that were paid, not the ones the hook replaced.
                    delete v.awards;
                    for (uint256 i; i < result.length; ++i) {
                        v.awards.push(result[i]);
                    }
                }
                (hookFeeBps, feeHook) = (bps, hook);
            }
        }
        ITMPCore.Award[] memory awards = verdictMem.awards;
        awardLen = awards.length;

        task.status = ITMPCore.TaskStatus.Accepted;
        bool selectedWorker = false;
        for (uint256 i; i < awardLen; ++i) {
            // slither-disable-next-line incorrect-equality
            if (awards[i].amount == 0) continue;
            task.worker = awards[i].worker;
            selectedWorker = true;
            break;
        }
        if (!selectedWorker && (task.mode == BOUNTY || task.mode == BENCHMARK)) {
            // An evaluator-selected worker has no authority after a zero-only verdict.
            task.worker = address(0);
        }

        // Commit award accounting (worker stats + fees) and validate escrow before the transfers.
        // Accounting and distribution live in separate frames to avoid stack-too-deep under
        // --ir-minimum coverage compilation.
        uint256 totalAwarded = _commitEvalAccounting(taskId, awards, task.feeBps, remaining, s);

        // An auction escrows the price cap but budgets awards against the accepted price, so the
        // unused cap goes back to the requester with the rest of the unawarded budget.
        if (task.mode == AUCTION) remaining += task.reward - task.stakeAmount;

        LibPayout.transferAwards(s, taskId, task.requester, awards, task.feeBps, hookFeeBps, feeHook);
        if (remaining > totalAwarded) {
            if (!LibProject.payRequester(s, taskId, remaining - totalAwarded)) revert ITMPCore.ExcessRefundFailed();
        }
        _settleClaimStake(taskId, task, verdictAwarded, s);
        _payEvaluatorFee(taskId, task, feeToEvaluator, s);
        // A verdict settled before expiry is a non-exit action; a ruling or a settlement after expiry
        // never waits on hook gas.
        if (runCheckHooks && !disputed) LibHooks._onCompleteHooksStrict(taskId, verdictMem);
        else LibHooks._onCompleteHooks(taskId, s, verdictMem);
    }

    /// @dev Whether any award in the list pays a nonzero amount.
    function _anyAward(ITMPCore.Award[] memory awards) private pure returns (bool) {
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].amount > 0) return true;
        }
        return false;
    }

    /// @dev The fee stays in escrow from evaluate until the verdict is final. A verdict an appeal
    ///      overturns earns nothing, so its fee goes back to the requester through
    ///      LibProject.payRequester: to the project's budget for a project task (rev027).
    function _payEvaluatorFee(bytes32 taskId, ITMPCore.Task storage task, bool toEvaluator, AppStorage storage s)
        private
    {
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        uint256 evalFee = LibTaskMarket._evaluatorFee(task, evalCfg.evaluatorFeeBps);
        if (evalFee == 0) return;
        if (toEvaluator) {
            if (!s.usdcToken.transfer(evalCfg.evaluator, evalFee)) revert ITMPCore.EvaluatorPaymentFailed();
            LibSettlement.add(taskId, LibSettlement.EVALUATOR_FEE, evalFee);
        } else if (!LibProject.payRequester(s, taskId, evalFee)) {
            revert ITMPCore.EvaluatorPaymentFailed();
        }
    }

    /// @dev Tallies awards, increments worker stats, commits fees, and validates escrow. No transfers.
    function _commitEvalAccounting(
        bytes32 taskId,
        ITMPCore.Award[] memory awards,
        uint16 feeBps,
        uint256 remaining,
        AppStorage storage s
    ) private returns (uint256 totalAwarded) {
        uint256 n = awards.length;
        uint256 totalFee = 0;
        for (uint256 i; i < n; ++i) {
            uint256 amt = awards[i].amount;
            // slither-disable-next-line incorrect-equality
            if (amt == 0) continue;
            totalAwarded += amt;
            totalFee += (amt * feeBps) / 10000;
            // Rev028: a worker named twice in one verdict completes the task once.
            if (!s.taskAwarded[taskId][awards[i].worker]) {
                s.workerStats[awards[i].worker].completedTasks++;
                s.taskAwarded[taskId][awards[i].worker] = true;
            }
        }
        if (totalAwarded > remaining) revert ITMPCore.AwardsExceedEscrow();
        if (totalFee > 0) s.totalFeesCollected += totalFee;
    }
}
