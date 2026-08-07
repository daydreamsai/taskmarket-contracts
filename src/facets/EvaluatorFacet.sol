// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";
import { TMP_BOUNTY, TMP_BENCHMARK } from "../interfaces/ITMPModes.sol";

/// @title EvaluatorFacet — ERC-8195 evaluator flow: assign, evaluate, appeal, finalize, dispute
contract EvaluatorFacet {
    bytes4 private constant BOUNTY = TMP_BOUNTY;
    bytes4 private constant BENCHMARK = TMP_BENCHMARK;

    /// @notice Assign an evaluator to an open task that was created without one.
    ///         Only the requester may call this, only while the task is Open.
    ///         If stakeAmount > 0, the contract pulls from the requester via transferFrom.
    /// @dev A requester who knows at creation time that the task needs an evaluator should pass
    ///      the configuration to `createTask` instead: the task is claimable the instant
    ///      `createTask` mines, so a second transaction races the first worker to claim and can
    ///      lose (`TaskNotOpen`). This function exists for the case that genuinely needs it --
    ///      deciding on an evaluator after the task is already live -- and the `Open` gate below
    ///      is correct for that case, because appointing an evaluator after a worker has claimed
    ///      would change the terms the worker committed to.
    /// @param taskId               Task identifier
    /// @param evaluator            Evaluator address
    /// @param stakeAmount          USDC stake amount pulled from requester (0 = no stake)
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
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();

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
            s
        );

        LibTaskMarket._nonReentrantAfter(s);
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
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address evaluatorAddr = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (evaluatorAddr != evalCfg.evaluator) revert ITMPCore.NotEvaluator();
        if (!(task.status == ITMPCore.TaskStatus.Review
                    || ((task.mode == BOUNTY || task.mode == BENCHMARK)
                        && (task.status == ITMPCore.TaskStatus.Open
                            || task.status == ITMPCore.TaskStatus.PendingApproval)))) revert ITMPCore.WrongStatusForEvaluation();

        _validateAwardRecipients(task, taskId, awards, s);

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

        if ((task.mode == BOUNTY || task.mode == BENCHMARK) && awards.length > 0) {
            task.worker = awards[0].worker;
        }

        uint256 evalFee = (task.reward * evalCfg.evaluatorFeeBps) / 10000;
        uint256 stakeReturn = evalCfg.evaluatorStake;
        evalCfg.evaluatorStake = 0;
        uint256 appealDeadline = block.timestamp + evalCfg.appealWindow;
        s.phaseDeadline[taskId] = appealDeadline;
        if (appealDeadline > task.expiryTime) {
            task.expiryTime = appealDeadline;
        }
        task.status = ITMPCore.TaskStatus.Appealing;

        LibTaskMarket._checkEvaluateHooks(taskId, evaluatorAddr, s);

        emit ITMPEvaluator.TaskEvaluated(taskId, evaluatorAddr, uint8(verdictType), score);

        if (evalFee + stakeReturn > 0) {
            if (!s.usdcToken.transfer(evalCfg.evaluator, evalFee + stakeReturn)) {
                revert ITMPCore.EvaluatorPaymentFailed();
            }
        }
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Appeal the evaluator's verdict.
    ///         Only task.worker may call this while status == Appealing and within the window.
    function appeal(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address worker = LibTaskMarket._effectiveSender(s);
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
        if (task.status != ITMPCore.TaskStatus.Appealing) revert ITMPCore.NotInAppealingState();
        if (block.timestamp >= s.phaseDeadline[taskId]) revert ITMPCore.AppealWindowClosed();

        task.status = ITMPCore.TaskStatus.Disputed;
        emit ITMPEvaluator.TaskAppealed(taskId, worker);
        address dr = s.taskEvaluatorConfigs[taskId].disputeResolver;
        if (dr != address(0)) emit ITMPEvaluator.TaskDisputed(taskId, dr);

        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Finalize the verdict after the appeal window has expired.
    ///         Anyone may call this once block.timestamp >= appeal deadline.
    function finalizeVerdict(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.status != ITMPCore.TaskStatus.Appealing) revert ITMPCore.NotInAppealingState();
        if (block.timestamp < s.phaseDeadline[taskId]) revert ITMPCore.AppealWindowStillOpen();

        ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
        if (!v.issued) revert ITMPCore.NoVerdictIssued();

        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (v.verdictType == ITMPCore.VerdictType.REJECT) {
            // REJECT refunds the (post-evaluator-fee) remainder to the requester in full,
            // so the task is done -- not reopened. Terminal status here mirrors
            // cancelTask's pattern (refund + Cancelled), and dispatches the same
            // _onCancelHooks release so any reward-hook reservation is cleaned up
            // rather than left dangling. Previously this set status back to Open,
            // which falsely advertised the task as re-claimable despite having no
            // escrow left behind it -- a worker who claimed it would find
            // acceptSubmission reverting on the empty balance at completion time.
            uint256 evalFee = (task.reward * evalCfg.evaluatorFeeBps) / 10000;
            uint256 refund = task.reward - evalFee;
            address requesterAddr = task.requester;
            task.status = ITMPCore.TaskStatus.Cancelled;
            task.worker = address(0);
            task.deliverable = bytes32(0);
            evalCfg.evaluator = address(0);
            evalCfg.evaluationWindow = 0;
            evalCfg.appealWindow = 0;
            if (refund > 0) {
                if (!s.usdcToken.transfer(requesterAddr, refund)) revert ITMPCore.RefundFailed();
            }
            emit ITMPCore.TaskCancelled(taskId, requesterAddr, refund);
            LibTaskMarket._onCancelHooks(taskId, s);
        } else {
            _payAwards(taskId, task, v, s);
        }
        LibTaskMarket._nonReentrantAfter(s);
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
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.status != ITMPCore.TaskStatus.Disputed) revert ITMPCore.NotInDisputedState();
        address caller = s.trustedForwarders[msg.sender] ? LibTaskMarket._effectiveSender(s) : msg.sender;
        if (caller != s.taskEvaluatorConfigs[taskId].disputeResolver) revert ITMPCore.NotDisputeResolver();
        if (verdictType == ITMPCore.VerdictType.REJECT) revert ITMPCore.DisputeResolutionMustAwardWorkers();
        if (awards.length == 0) revert ITMPCore.AwardsRequired();
        _validateAwardRecipients(task, taskId, awards, s);

        ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
        v.verdictType = verdictType;
        delete v.awards;
        for (uint256 i; i < awards.length; ++i) {
            v.awards.push(awards[i]);
        }

        _payAwards(taskId, task, v, s);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Trigger evaluator timeout after the evaluation window expires.
    ///         Only the requester may call this.
    function evaluatorTimeout(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.status != ITMPCore.TaskStatus.Review) revert ITMPCore.NotInReviewState();
        if (block.timestamp <= s.phaseDeadline[taskId]) revert ITMPCore.EvaluationWindowNotExpired();

        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        address timedOutEvaluator = evalCfg.evaluator;
        uint256 forfeited = evalCfg.evaluatorStake;
        evalCfg.evaluatorStake = 0;
        evalCfg.evaluator = address(0);
        task.status = ITMPCore.TaskStatus.PendingApproval;

        if (forfeited > 0) {
            s.totalFeesCollected += forfeited;
            if (!s.usdcToken.transfer(s.feeRecipient, forfeited)) revert ITMPCore.ForfeitTransferFailed();
        }

        emit ITMPEvaluator.EvaluatorTimedOut(taskId, timedOutEvaluator, forfeited);
        LibTaskMarket._nonReentrantAfter(s);
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
    ///      permanently, stranding the escrow.
    function _validateAwardRecipients(
        ITMPCore.Task storage task,
        bytes32 taskId,
        ITMPCore.Award[] calldata awards,
        AppStorage storage s
    ) private view {
        bool bountyLike = task.mode == BOUNTY || task.mode == BENCHMARK;
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].amount == 0) continue;
            address worker = awards[i].worker;
            if (worker == address(0)) revert ITMPCore.InvalidAwardRecipient();
            if (bountyLike) {
                if (s.taskSubmissionHashes[taskId][worker].length == 0) revert ITMPCore.SubmissionNotFound();
            } else if (worker != task.worker) {
                revert ITMPCore.WorkerMismatch();
            }
        }
    }

    // Complexity is inherent: iterates N winners applying per-winner fee, transfer, hook, and event; handles excess refund.
    // solhint-disable-next-line code-complexity
    function _payAwards(bytes32 taskId, ITMPCore.Task storage task, ITMPCore.Verdict storage v, AppStorage storage s)
        private
    {
        // Validate recipients before touching any state.
        uint256 awardLen = v.awards.length;
        for (uint256 i; i < awardLen; i++) {
            if (v.awards[i].amount > 0 && v.awards[i].worker == address(0)) {
                revert ITMPCore.InvalidAwardRecipient();
            }
        }

        uint256 remaining = task.reward - (task.reward * s.taskEvaluatorConfigs[taskId].evaluatorFeeBps) / 10000;
        ITMPCore.Verdict memory verdictMem = s.taskVerdicts[taskId];

        task.status = ITMPCore.TaskStatus.Accepted;
        if (v.awards.length > 0) task.worker = v.awards[0].worker;

        // Commit award accounting (worker stats + fees) and validate escrow before the check hook;
        // transfers happen after. Accounting and distribution live in separate frames to avoid
        // stack-too-deep under --ir-minimum coverage compilation.
        uint256 totalAwarded = _commitEvalAccounting(v, task.feeBps, remaining, s);

        LibTaskMarket._checkCompleteHooks(taskId, s, verdictMem);
        _distributeEvalAwards(taskId, task.requester, v, task.feeBps, remaining, totalAwarded, s);
        LibTaskMarket._onCompleteHooks(taskId, s, verdictMem);
    }

    /// @dev Tallies awards, increments worker stats, commits fees, and validates escrow. No transfers.
    function _commitEvalAccounting(ITMPCore.Verdict storage v, uint16 feeBps, uint256 remaining, AppStorage storage s)
        private
        returns (uint256 totalAwarded)
    {
        uint256 n = v.awards.length;
        uint256 totalFee = 0;
        for (uint256 i; i < n; ++i) {
            uint256 amt = v.awards[i].amount;
            if (amt == 0) continue;
            totalAwarded += amt;
            totalFee += (amt * feeBps) / 10000;
            s.workerStats[v.awards[i].worker].completedTasks++;
        }
        if (totalAwarded > remaining) revert ITMPCore.AwardsExceedEscrow();
        if (totalFee > 0) s.totalFeesCollected += totalFee;
    }

    /// @dev Transfers per-winner nets, the aggregate fee, and any escrow excess. Isolated in its own
    ///      frame so the payout-loop locals do not pressure the orchestrator's stack.
    function _distributeEvalAwards(
        bytes32 taskId,
        address requester,
        ITMPCore.Verdict storage v,
        uint16 feeBps,
        uint256 remaining,
        uint256 totalAwarded,
        AppStorage storage s
    ) private {
        uint256 n = v.awards.length;
        uint256 totalFee = 0;
        // Multi-winner payouts require iterating recipients. State fully committed before loop (CEI).
        // slither-disable-next-line calls-loop
        for (uint256 i; i < n; ++i) {
            uint256 amt = v.awards[i].amount;
            if (amt == 0) continue;
            uint256 fee = (amt * feeBps) / 10000;
            totalFee += fee;
            if (!s.usdcToken.transfer(v.awards[i].worker, amt - fee)) revert ITMPCore.WorkerPaymentFailed();
            emit ITMPCore.TaskCompleted(taskId, requester, v.awards[i].worker, amt - fee, fee);
        }
        if (totalFee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, totalFee)) revert ITMPCore.FeeTransferFailed();
        }
        if (remaining > totalAwarded) {
            if (!s.usdcToken.transfer(requester, remaining - totalAwarded)) revert ITMPCore.ExcessRefundFailed();
        }
    }
}
