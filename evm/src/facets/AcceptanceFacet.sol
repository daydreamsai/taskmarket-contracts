// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibProject } from "../libraries/LibProject.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibHooksV2 } from "../libraries/LibHooksV2.sol";
import { LibSettlement } from "../libraries/LibSettlement.sol";
import { LibPayout } from "../libraries/LibPayout.sol";
import { LibReview } from "../libraries/LibReview.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { LibFeedback } from "../libraries/LibFeedback.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title AcceptanceFacet — single and multi-winner submission acceptance with payouts
contract AcceptanceFacet {
    bytes4 private constant BOUNTY = TMP_BOUNTY;
    bytes4 private constant CLAIM = TMP_CLAIM;
    bytes4 private constant PITCH = TMP_PITCH;
    bytes4 private constant BENCHMARK = TMP_BENCHMARK;
    bytes4 private constant AUCTION = TMP_AUCTION;

    /// @notice Accept submission and release payment to worker.
    ///         The requester is the authenticated actor (pgtrSender).
    /// @param taskId           Task identifier
    /// @param worker           Worker address to pay
    /// @param deliverable      Accepted content hash; must have been committed by submitWork for Bounty/Benchmark
    /// @param requesterAgentId ERC-8004 agentId of requester (0 if unknown); used for giveFeedback
    function acceptSubmission(bytes32 taskId, address worker, bytes32 deliverable, uint256 requesterAgentId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarderNoPayment(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);
        uint256 balanceBefore = LibEscrow.balance(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        LibGuards._requireRequester(s, taskId, requester);
        // Rev028: an operator or the project owner may act for the requester, but the reputation
        // signal, the self-award check and the events belong to the task's requester of record.
        requester = task.requester;

        bytes4 mode = task.mode;
        LibHooksV2.snap(taskId, uint8(task.status));
        _validateAcceptSubmission(task, taskId, worker, deliverable, s);
        _signalDecisionLapsed(taskId, task, s);

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        // The award is what the worker is paid: the accepted price for an auction, not its cap.
        uint256 awardAmount = mode == AUCTION ? task.stakeAmount : task.reward;
        awards[0] = ITMPCore.Award({ worker: worker, amount: awardAmount, rank: 1 });
        ITMPCore.Verdict memory verdict = ITMPCore.Verdict({
            issued: true,
            verdictType: ITMPCore.VerdictType.APPROVE,
            score: 1000,
            confidence: 1000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });

        task.status = ITMPCore.TaskStatus.Accepted;
        task.worker = worker;
        s.workerStats[worker].completedTasks++;
        if (mode == CLAIM || mode == PITCH || mode == AUCTION) s.taskAwarded[taskId][worker] = true;

        // Fee computation, transfers, events, and hook dispatch are isolated in a separate
        // frame to keep this function's local count under the --ir-minimum stack limit.
        _completeAcceptance(taskId, task, worker, requester, requesterAgentId, mode, verdict, s);

        LibEscrow.release(s, taskId, balanceBefore);
        LibGuards._nonReentrantAfter(s);
    }

    // Complexity is inherent: handles four modes × payment/stake/auction/hook/event branches.
    // Isolated from acceptSubmission to reduce stack depth under --ir-minimum coverage compilation.
    // solhint-disable-next-line code-complexity
    function _completeAcceptance(
        bytes32 taskId,
        ITMPCore.Task storage task,
        address worker,
        address requester,
        uint256 requesterAgentId,
        bytes4 mode,
        ITMPCore.Verdict memory verdict,
        AppStorage storage s
    ) private {
        uint256 paymentAmount = mode == AUCTION ? task.stakeAmount : task.reward;
        // Rev028: a V2 task's beforeAccept, and the transforming hook's result if any.
        (bool changed, ITMPCore.Award[] memory awards, uint16 hookFeeBps, address feeHook) =
            LibHooks._acceptV2(s, taskId, verdict, true, false, paymentAmount);
        if (changed) {
            // Undo the core award's bookkeeping; _payResult books the final awards.
            s.workerStats[worker].completedTasks--;
            s.taskAwarded[taskId][worker] = false;
            if (awards.length == 0) awards = verdict.awards;
            else _recordPaidAwards(taskId, awards, s);
            _payResult(taskId, requester, awards, paymentAmount, task.feeBps, hookFeeBps, feeHook, s);
        } else {
            if (paymentAmount > 0) s.taskAwarded[taskId][worker] = true;
            _payWorkerShare(taskId, requester, worker, paymentAmount, task.feeBps, s);
        }
        _returnStakeAndPriceCap(taskId, task, s);

        // Rev030: when a transforming hook changed the awards, self-dealing is read from the awards
        // actually paid, as the multi-winner path does, not from the core worker.
        bool selfPaid = worker == requester;
        if (changed) {
            selfPaid = false;
            for (uint256 i; i < awards.length; ++i) {
                if (awards[i].amount == 0) continue;
                if (LibProject.isActingParty(s, taskId, awards[i].worker)) {
                    emit ITMPCore.SelfAward(taskId, requester, awards[i].worker);
                }
                if (awards[i].worker == requester) selfPaid = true;
            }
        } else if (LibProject.isActingParty(s, taskId, worker)) {
            emit ITMPCore.SelfAward(taskId, requester, worker);
        }
        if (mode == BOUNTY || mode == BENCHMARK) {
            emit ITMPCore.RequesterReputation(
                taskId,
                requester,
                keccak256("completed"),
                task.reward,
                uint32(s.taskActiveSubmissionCount[taskId]),
                selfPaid
            );
            LibFeedback.requester(s, taskId, requester, requesterAgentId, LibFeedback.COMPLETED, mode);
        }

        LibHooks._onCompleteHooksStrict(taskId, verdict);
    }

    /// @notice Accept N submissions at once with explicit share basis points.
    ///         Valid for Bounty and Benchmark modes. Shares MUST sum to 10000.
    ///         Pass an empty deliverables array to auto-resolve each worker's latest
    ///         on-chain submission hash. Pass a same-length array to pin specific
    ///         hashes (bytes32(0) in a slot = auto-resolve that slot).
    ///         Reverts SubmissionNotFound if any winner has no prior submitWork call
    ///         or a pinned hash was never submitted by that worker.
    /// @param taskId           Task identifier
    /// @param workers          Recipient addresses in rank order
    /// @param shares           Basis-point shares; MUST sum to 10000
    /// @param deliverables     Per-winner hash overrides; empty = auto-resolve all
    /// @param requesterAgentId ERC-8004 agentId of requester (0 if unknown); used for giveFeedback
    function acceptSubmissions(
        bytes32 taskId,
        address[] calldata workers,
        uint16[] calldata shares,
        bytes32[] calldata deliverables,
        uint256 requesterAgentId
    ) external {
        AppStorage storage s = LibAppStorage.appStorage();
        // Rev030: the cap is per chain (s.maxSubmissionWinners, 50 when unset).
        if (workers.length > LibTaskMarket._maxSubmissionWinners(s)) {
            revert ITMPCore.TooManyWinners();
        }
        LibGuards._requireForwarderNoPayment(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);
        uint256 balanceBefore = LibEscrow.balance(s);

        address requester = LibGuards._effectiveSender(s);
        _acceptSubmissions(taskId, requester, workers, shares, deliverables, requesterAgentId, s);
        LibEscrow.release(s, taskId, balanceBefore);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev Requester reputation signal for settling a Bounty or Benchmark after its decision
    ///      deadline. Runs before the payout changes the active submission count.
    function _signalDecisionLapsed(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private {
        if (!LibReview.decisionLapsed(s, taskId, task)) return;
        emit ITMPCore.RequesterReputation(
            taskId,
            task.requester,
            keccak256("decision_deadline_lapsed"),
            task.reward,
            uint32(s.taskActiveSubmissionCount[taskId]),
            false
        );
    }

    // Complexity is inherent: validates four distinct task modes plus evaluator/deliverable variants.
    // solhint-disable-next-line code-complexity
    function _validateAcceptSubmission(
        ITMPCore.Task storage task,
        bytes32 taskId,
        address worker,
        bytes32 deliverable,
        AppStorage storage s
    ) private {
        // Bounty/Benchmark: expiryTime is the submission window deadline only; acceptance
        // is open-ended once submissions exist. Claim/Pitch/Auction: expiryTime still applies.
        if (task.mode != BOUNTY && task.mode != BENCHMARK) _checkReviewWindow(task, taskId, s);
        address evaluator = s.taskEvaluatorConfigs[taskId].evaluator;
        if (task.mode == CLAIM) {
            if (evaluator != address(0)) revert ITMPCore.UseEvaluate();
            if (task.status != ITMPCore.TaskStatus.Claimed && task.status != ITMPCore.TaskStatus.PendingApproval) {
                revert ITMPCore.TaskNotClaimed();
            }
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            if (deliverable != task.deliverable) revert ITMPCore.DeliverableMismatch();
        } else if (task.mode == PITCH) {
            if (evaluator != address(0)) revert ITMPCore.UseEvaluate();
            if (task.status != ITMPCore.TaskStatus.WorkerSelected && task.status != ITMPCore.TaskStatus.PendingApproval)
            {
                revert ITMPCore.WorkerNotSelected();
            }
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            if (deliverable != task.deliverable) revert ITMPCore.DeliverableMismatch();
        } else if (task.mode == AUCTION) {
            if (evaluator != address(0)) revert ITMPCore.UseEvaluate();
            if (task.status != ITMPCore.TaskStatus.Claimed && task.status != ITMPCore.TaskStatus.PendingApproval) {
                revert ITMPCore.WinnerNotSelected();
            }
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            if (deliverable != task.deliverable) revert ITMPCore.DeliverableMismatch();
        } else {
            // BOUNTY or BENCHMARK: verify the deliverable was committed on-chain by submitWork.
            if (evaluator != address(0)) revert ITMPCore.UseEvaluate();
            if (task.status != ITMPCore.TaskStatus.Open && task.status != ITMPCore.TaskStatus.PendingApproval) {
                revert ITMPCore.TaskNotOpen();
            }
            if (worker == address(0)) revert ITMPCore.WorkerRequired();
            if (deliverable == bytes32(0)) revert ITMPCore.DeliverableRequired();
            if (!s.taskSubmissionHashExists[taskId][worker][deliverable]) revert ITMPCore.SubmissionNotFound();
            task.deliverable = deliverable;
        }
    }

    /// @dev A delivery under review may be accepted until its review deadline, before or after
    ///      expiryTime; none may be accepted while a revision is open for resubmission. Without a
    ///      delivery under review, expiryTime applies as before.
    function _checkReviewWindow(ITMPCore.Task storage task, bytes32 taskId, AppStorage storage s) private {
        if (LibReview.singlePayee(s, taskId, task)) {
            ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
            if (LibReview.revisionOpen(clock)) revert ITMPCore.DeliveryPending();
            ITMPCore.TaskTerms storage t = LibTerms.terms(s, taskId);
            uint256 start = LibReview.reviewStart(clock);
            if (start != 0) {
                if (block.timestamp > start + LibReview.reviewWindow(t)) revert ITMPCore.ReviewWindowClosed();
                LibReview.clear(clock);
                return;
            }
        }
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
    }

    // Validates, resolves deliverables, and builds the awards array before delegating
    // payment/hooks/events to _payMultiAwards. Split to stay under the --ir-minimum stack limit:
    // workers/shares calldata each consume two stack slots (offset + length) in viaIR mode.
    // solhint-disable-next-line code-complexity
    function _acceptSubmissions(
        bytes32 taskId,
        address requester,
        address[] calldata workers,
        uint16[] calldata shares,
        bytes32[] calldata pinnedDeliverables,
        uint256 requesterAgentId,
        AppStorage storage s
    ) private {
        ITMPCore.Task storage task = s.tasks[taskId];
        LibGuards._requireRequester(s, taskId, requester);
        LibHooksV2.snap(taskId, uint8(task.status));
        // Rev028: credit the requester of record, not the delegate acting for it.
        requester = task.requester;
        if (task.mode != BOUNTY && task.mode != BENCHMARK) revert ITMPCore.MultiSubmissionOnlyForBountyBenchmark();
        if (s.taskEvaluatorConfigs[taskId].evaluator != address(0)) revert ITMPCore.UseEvaluate();
        if (task.status != ITMPCore.TaskStatus.Open && task.status != ITMPCore.TaskStatus.PendingApproval) {
            revert ITMPCore.TaskNotOpen();
        }

        uint256 n = workers.length;
        if (n < 1) revert ITMPCore.NoWinners();
        if (shares.length != n) revert ITMPCore.LengthMismatch();
        if (pinnedDeliverables.length != 0 && pinnedDeliverables.length != n) revert ITMPCore.LengthMismatch();

        bytes32[] memory deliverables = _resolveDeliverables(taskId, workers, shares, pinnedDeliverables, s);
        _signalDecisionLapsed(taskId, task, s);

        uint256 reward = task.reward;
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            awards[i] =
                ITMPCore.Award({ worker: workers[i], amount: (reward * shares[i]) / 10000, rank: uint16(i + 1) });
        }

        task.status = ITMPCore.TaskStatus.Accepted;
        task.worker = workers[0];
        task.deliverable = deliverables[0];

        // Verdict building, fee computation, hook dispatch, transfers and events are isolated in a
        // separate frame so workers/shares calldata slots do not overlap with payment temporaries.
        _payMultiAwards(taskId, task, requester, requesterAgentId, awards, s);
    }

    // Complexity is inherent: computes per-winner fees, dispatches hooks, transfers, emits events.
    // solhint-disable-next-line code-complexity
    function _payMultiAwards(
        bytes32 taskId,
        ITMPCore.Task storage task,
        address requester,
        uint256 requesterAgentId,
        ITMPCore.Award[] memory awards,
        AppStorage storage s
    ) private {
        ITMPCore.Verdict memory verdict = ITMPCore.Verdict({
            issued: true,
            verdictType: ITMPCore.VerdictType.APPROVE,
            score: 1000,
            confidence: 1000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });

        // Every pair must pay something, whichever path settles it.
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].amount == 0) revert ITMPCore.ZeroPayoutPerPair();
        }
        // Rev028: a V2 task's beforeAccept, and the transforming hook's result if any.
        (bool changed, ITMPCore.Award[] memory result, uint16 hookFeeBps, address feeHook) =
            LibHooks._acceptV2(s, taskId, verdict, true, false, task.reward);
        if (changed) {
            if (result.length == 0) result = awards;
            else _recordPaidAwards(taskId, result, s);
            _payResult(taskId, requester, result, task.reward, task.feeBps, hookFeeBps, feeHook, s);
            awards = result;
        } else {
            _payMultiCore(taskId, task, requester, awards, s);
        }
        bool anySelfAward = false;
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].amount > 0 && LibProject.isActingParty(s, taskId, awards[i].worker)) {
                emit ITMPCore.SelfAward(taskId, requester, awards[i].worker);
                anySelfAward = true;
            }
        }
        if (!changed) _refundSplitRemainder(taskId, task.reward, awards, s);

        emit ITMPCore.RequesterReputation(
            taskId,
            requester,
            keccak256("completed"),
            task.reward,
            uint32(s.taskActiveSubmissionCount[taskId]),
            anySelfAward
        );
        LibFeedback.requester(s, taskId, requester, requesterAgentId, LibFeedback.COMPLETED, task.mode);

        LibHooks._onCompleteHooksStrict(taskId, verdict);
    }

    /// @dev The core multi-winner payout, unchanged from rev027 apart from the settlement tally:
    ///      bookkeeping, then transfers.
    function _payMultiCore(
        bytes32 taskId,
        ITMPCore.Task storage task,
        address requester,
        ITMPCore.Award[] memory awards,
        AppStorage storage s
    ) private {
        uint256 totalFee = 0;
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].amount == 0) revert ITMPCore.ZeroPayoutPerPair();
            totalFee += (awards[i].amount * uint256(task.feeBps)) / 10000;
            s.workerStats[awards[i].worker].completedTasks++;
            s.taskAwarded[taskId][awards[i].worker] = true;
        }
        if (totalFee > 0) s.totalFeesCollected += totalFee;

        uint256 totalNet = 0;
        // slither-disable-next-line calls-loop
        for (uint256 i; i < awards.length; ++i) {
            uint256 fee = (awards[i].amount * uint256(task.feeBps)) / 10000;
            uint256 net = awards[i].amount - fee;
            totalNet += net;
            if (!s.usdcToken.transfer(awards[i].worker, net)) revert ITMPCore.WorkerPaymentFailed();
            emit ITMPCore.TaskCompleted(taskId, requester, awards[i].worker, net, fee);
        }
        if (totalFee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, totalFee)) revert ITMPCore.FeeTransferFailed();
        }
        _tally(taskId, totalNet, totalFee, awards.length);
    }

    /// @dev Rev028: pays a transforming hook's validated result. Each nonzero award is paid net of
    ///      the protocol fee and the hook fee (both from the worker side); the hook fee goes to the
    ///      hook; whatever the awards leave of `budget` goes back to the requester. Rating rights
    ///      follow the final nonzero awards.
    function _payResult(
        bytes32 taskId,
        address requester,
        ITMPCore.Award[] memory awards,
        uint256 budget,
        uint16 feeBps,
        uint16 hookFeeBps,
        address feeHook,
        AppStorage storage s
    ) private {
        uint256 total = LibPayout.payAwards(s, taskId, requester, awards, feeBps, hookFeeBps, feeHook);
        if (budget > total) {
            if (!LibProject.payRequester(s, taskId, budget - total)) revert ITMPCore.ExcessRefundFailed();
        }
    }

    /// @dev Rev030: when a transforming hook replaced the awards, the task's verdict records the
    ///      awards paid, as EvaluatorFacet._payAwards does, so getTaskVerdict reports what was paid
    ///      and an after-callback (the DREAMS reward hook's bonus) is sized from it. A requester
    ///      acceptance no hook changed still stores no verdict.
    function _recordPaidAwards(bytes32 taskId, ITMPCore.Award[] memory awards, AppStorage storage s) private {
        delete s.taskVerdicts[taskId];
        ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
        v.issued = true;
        v.verdictType = ITMPCore.VerdictType.APPROVE;
        v.score = 1000;
        v.confidence = 1000;
        for (uint256 i; i < awards.length; ++i) {
            v.awards.push(awards[i]);
        }
    }

    function _tally(bytes32 taskId, uint256 net, uint256 fee, uint256 count) private {
        LibSettlement.add(taskId, LibSettlement.WORKER, net);
        LibSettlement.add(taskId, LibSettlement.PROTOCOL_FEE, fee);
        LibSettlement.add(taskId, LibSettlement.AWARDS, count);
    }

    /// @dev Each award is rounded down from its share, so the awards can sum to a few base units less
    ///      than the reward; that remainder belongs to the requester, not the pooled balance. Its own
    ///      frame keeps _payMultiAwards under the --ir-minimum stack limit.
    function _refundSplitRemainder(bytes32 taskId, uint256 reward, ITMPCore.Award[] memory awards, AppStorage storage s)
        private
    {
        uint256 totalAwarded = 0;
        for (uint256 i; i < awards.length; ++i) {
            totalAwarded += awards[i].amount;
        }
        if (reward > totalAwarded) {
            if (!LibProject.payRequester(s, taskId, reward - totalAwarded)) revert ITMPCore.ExcessRefundFailed();
        }
    }

    function _resolveDeliverables(
        bytes32 taskId,
        address[] calldata workers,
        uint16[] calldata shares,
        bytes32[] calldata pinnedDeliverables,
        AppStorage storage s
    ) private view returns (bytes32[] memory deliverables) {
        uint256 n = workers.length;
        deliverables = new bytes32[](n);
        uint256 sumShares = 0;
        for (uint256 i; i < n; ++i) {
            if (workers[i] == address(0)) revert ITMPCore.WorkerRequired();
            for (uint256 j; j < i; ++j) {
                if (workers[j] == workers[i]) revert ITMPCore.DuplicateAwardWorker();
            }
            bytes32 pinned = (pinnedDeliverables.length > 0) ? pinnedDeliverables[i] : bytes32(0);
            if (pinned != bytes32(0)) {
                if (!s.taskSubmissionHashExists[taskId][workers[i]][pinned]) revert ITMPCore.SubmissionNotFound();
                deliverables[i] = pinned;
            } else {
                bytes32[] storage submitted = s.taskSubmissionHashes[taskId][workers[i]];
                if (submitted.length == 0) revert ITMPCore.SubmissionNotFound();
                deliverables[i] = submitted[submitted.length - 1];
            }
            sumShares += shares[i];
        }
        if (sumShares != 10000) revert ITMPCore.SharesMustSumTo10000();
    }

    // -------------------------------------------------------------------------
    // Lapsed review (rev028: moved from SettlementFacet, selector unchanged, to keep that facet
    // under the contract size limit)
    // -------------------------------------------------------------------------

    /// @notice Pay the worker for a delivery whose review window lapsed undecided, exactly as an
    ///         accept would (permissionless). Check hooks are not consulted: a lapsed review must
    ///         settle, so only the onComplete after-hooks run.
    function settleLapsedReview(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._requireNoRelayedPayment(s);
        LibGuards._nonReentrantBefore(s);
        LibHooksV2.snap(taskId, uint8(s.tasks[taskId].status));
        uint256 balanceBefore = LibEscrow.balance(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        _requireLapsedDelivery(taskId, task, s);
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
        LibEscrow.release(s, taskId, balanceBefore);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev Pays the worker as acceptSubmission does and returns the gross payment.
    function _payLapsedReview(bytes32 taskId, ITMPCore.Task storage task, address worker, AppStorage storage s)
        private
        returns (uint256 payment)
    {
        payment = task.mode == AUCTION ? task.stakeAmount : task.reward;
        _payWorkerShare(taskId, task.requester, worker, payment, task.feeBps, s);
        _returnStakeAndPriceCap(taskId, task, s);
    }

    /// @dev The single-payee payout shared by acceptSubmission and settleLapsedReview: the protocol
    ///      fee is booked and sent, the worker paid the rest, and the settlement record tallied.
    function _payWorkerShare(
        bytes32 taskId,
        address requester,
        address worker,
        uint256 payment,
        uint16 feeBps,
        AppStorage storage s
    ) private {
        uint256 fee = (payment * feeBps) / 10000;
        uint256 net = payment - fee;
        if (fee > 0) s.totalFeesCollected += fee;
        if (!s.usdcToken.transfer(worker, net)) revert ITMPCore.WorkerPaymentFailed();
        if (fee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, fee)) revert ITMPCore.FeeTransferFailed();
        }
        _tally(taskId, net, fee, 1);
        emit ITMPCore.TaskCompleted(taskId, requester, worker, net, fee);
    }

    /// @dev A Claim worker's stake goes back to them, and an auction's unused price cap to the
    ///      requester.
    function _returnStakeAndPriceCap(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private {
        if (task.mode == CLAIM && task.stakeAmount > 0) {
            if (!s.usdcToken.transfer(task.worker, task.stakeAmount)) revert ITMPCore.StakeReturnFailed();
            emit ITMPCore.StakeReturned(taskId, task.worker, task.stakeAmount);
        }
        if (task.mode == AUCTION) {
            uint256 refund = s.taskAuctionConfigs[taskId].maxPrice - task.stakeAmount;
            if (refund > 0) {
                if (!LibProject.payRequester(s, taskId, refund)) revert ITMPCore.AuctionRefundFailed();
            }
        }
    }

    /// @dev A Claim, Pitch or Auction delivery with no evaluator, still Claimed or WorkerSelected.
    function _requireLapsedDelivery(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private view {
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != CLAIM && task.mode != PITCH && task.mode != AUCTION) revert ITMPCore.InvalidMode();
        if (s.taskEvaluatorConfigs[taskId].evaluator != address(0)) revert ITMPCore.UseEvaluate();
        if (
            task.deliverable == bytes32(0)
                || (task.status != ITMPCore.TaskStatus.Claimed && task.status != ITMPCore.TaskStatus.WorkerSelected)
        ) revert ITMPCore.DeliverableRequired();
    }
}
