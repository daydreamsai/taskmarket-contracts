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

    /// @notice Assign an evaluator to an open task.
    ///         Only the requester may call this, only while the task is Open.
    ///         If stakeAmount > 0, the contract pulls from the requester via transferFrom.
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
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (evaluator == address(0)) revert ITMPCore.InvalidEvaluator();
        if (evalCfg.evaluator != address(0)) revert ITMPCore.EvaluatorAlreadyAssigned();
        if (feeBps > 10000) revert ITMPCore.FeeBpsTooHigh();

        evalCfg.evaluator = evaluator;
        evalCfg.evaluatorStake = stakeAmount;
        evalCfg.evaluatorFeeBps = feeBps;
        evalCfg.evaluationWindow = evaluationWindowSecs;
        evalCfg.appealWindow = appealWindowSecs;
        evalCfg.disputeResolver = disputeResolver;

        if (stakeAmount > 0) {
            // Pull stake from the requester. Pulling from an arbitrary evaluator address would
            // let a malicious requester drain any address that has pre-approved this contract.
            // requester = _effectiveSender(s) = authenticated PGTR forwarder caller; not arbitrary
            // slither-disable-next-line arbitrary-send-erc20
            if (!s.usdcToken.transferFrom(requester, address(this), stakeAmount)) {
                revert ITMPCore.StakeTransferFailed();
            }
        }

        emit ITMPEvaluator.EvaluatorAssigned(taskId, evaluator, stakeAmount);
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

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkEvaluate(taskId, LibTaskMarket._buildContext(taskId, s), evaluatorAddr)) {
                revert ITMPCore.HookCheckEvaluateRejected();
            }
        }

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
        if (worker != task.worker) revert ITMPCore.NotWorker();
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
            uint256 evalFee = (task.reward * evalCfg.evaluatorFeeBps) / 10000;
            uint256 refund = task.reward - evalFee;
            task.status = ITMPCore.TaskStatus.Open;
            task.worker = address(0);
            task.deliverable = bytes32(0);
            evalCfg.evaluator = address(0);
            evalCfg.evaluationWindow = 0;
            evalCfg.appealWindow = 0;
            if (refund > 0) {
                if (!s.usdcToken.transfer(task.requester, refund)) revert ITMPCore.RefundFailed();
            }
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

    // Complexity is inherent: iterates N winners applying per-winner fee, transfer, hook, and event; handles excess refund.
    // solhint-disable-next-line code-complexity
    function _payAwards(bytes32 taskId, ITMPCore.Task storage task, ITMPCore.Verdict storage v, AppStorage storage s)
        private
    {
        uint256 evalFee = (task.reward * s.taskEvaluatorConfigs[taskId].evaluatorFeeBps) / 10000;
        uint256 remaining = task.reward - evalFee;
        uint256 n = v.awards.length;

        ITMPCore.Verdict memory verdictMem = s.taskVerdicts[taskId];

        task.status = ITMPCore.TaskStatus.Accepted;
        if (n > 0) task.worker = v.awards[0].worker;

        uint16 feeBps = task.feeBps;
        uint256 totalFee = 0;
        uint256 totalAwarded = 0;
        address[] memory workers = new address[](n);
        uint256[] memory nets = new uint256[](n);
        uint256[] memory awardFees = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address w = v.awards[i].worker;
            uint256 amt = v.awards[i].amount;
            workers[i] = w;
            if (amt == 0) continue;
            totalAwarded += amt;
            uint256 fee = (amt * feeBps) / 10000;
            nets[i] = amt - fee;
            awardFees[i] = fee;
            totalFee += fee;
            s.workerStats[w].completedTasks++;
        }
        if (totalAwarded > remaining) revert ITMPCore.AwardsExceedEscrow();
        if (totalFee > 0) s.totalFeesCollected += totalFee;

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkComplete(taskId, LibTaskMarket._buildContext(taskId, s), verdictMem)) {
                revert ITMPCore.HookCheckCompleteRejected();
            }
        }

        // Multi-winner payouts require iterating recipients. State fully committed before loop (CEI).
        // slither-disable-next-line calls-loop
        for (uint256 i; i < n; ++i) {
            if (nets[i] == 0 && awardFees[i] == 0) continue;
            if (!s.usdcToken.transfer(workers[i], nets[i])) revert ITMPCore.WorkerPaymentFailed();
            emit ITMPCore.TaskCompleted(taskId, task.requester, workers[i], nets[i], awardFees[i]);
        }
        if (totalFee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, totalFee)) revert ITMPCore.FeeTransferFailed();
        }

        if (remaining > totalAwarded) {
            if (!s.usdcToken.transfer(task.requester, remaining - totalAwarded)) revert ITMPCore.ExcessRefundFailed();
        }

        if (hook != address(0)) {
            LibTaskMarket._afterHook(
                hook, abi.encodeCall(ITMPHook.onComplete, (taskId, LibTaskMarket._buildContext(taskId, s), verdictMem))
            );
        }
    }
}
