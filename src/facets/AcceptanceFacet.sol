// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";
import { IReputationRegistry } from "../interfaces/IReputationRegistry.sol";
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
    // Complexity is inherent: handles four modes × payment/stake/auction/hook/event branches.
    // solhint-disable-next-line code-complexity
    function acceptSubmission(bytes32 taskId, address worker, bytes32 deliverable, uint256 requesterAgentId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();

        _validateAcceptSubmission(task, taskId, worker, deliverable, s);

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: task.reward, rank: 1 });
        ITMPCore.Verdict memory verdict = ITMPCore.Verdict({
            issued: true,
            verdictType: ITMPCore.VerdictType.APPROVE,
            score: 1000,
            confidence: 1000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });

        uint256 paymentAmount = task.mode == AUCTION ? task.stakeAmount : task.reward;
        uint256 fee = (paymentAmount * task.feeBps) / 10000;
        uint256 workerPayment = paymentAmount - fee;

        task.status = ITMPCore.TaskStatus.Accepted;
        task.worker = worker;
        s.workerStats[worker].completedTasks++;
        if (fee > 0) s.totalFeesCollected += fee;

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkComplete(taskId, LibTaskMarket._buildContext(taskId, s), verdict)) {
                revert ITMPCore.HookCheckCompleteRejected();
            }
        }

        if (!s.usdcToken.transfer(worker, workerPayment)) revert ITMPCore.WorkerPaymentFailed();
        if (fee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, fee)) revert ITMPCore.FeeTransferFailed();
        }

        if (task.mode == CLAIM && task.stakeAmount > 0) {
            if (!s.usdcToken.transfer(task.worker, task.stakeAmount)) revert ITMPCore.StakeReturnFailed();
            emit ITMPCore.StakeReturned(taskId, task.worker, task.stakeAmount);
        }

        if (task.mode == AUCTION) {
            uint256 refund = s.taskAuctionConfigs[taskId].maxPrice - task.stakeAmount;
            if (refund > 0) {
                if (!s.usdcToken.transfer(task.requester, refund)) revert ITMPCore.AuctionRefundFailed();
            }
        }

        emit ITMPCore.TaskCompleted(taskId, requester, worker, workerPayment, fee);

        if (worker == requester) {
            emit ITMPCore.SelfAward(taskId, requester, worker);
        }
        emit ITMPCore.RequesterReputation(
            taskId,
            requester,
            keccak256("completed"),
            task.reward,
            uint32(s.taskActiveSubmissionCount[taskId]),
            worker == requester
        );
        if (requesterAgentId != 0 && s.reputationRegistry != address(0)) {
            try IReputationRegistry(s.reputationRegistry)
                .giveFeedback(
                    requesterAgentId, 100, 0, "tmp.task.requester", _modeName(task.mode), "", "", bytes32(0)
                ) { }
                catch { }
        }

        if (hook != address(0)) {
            LibTaskMarket._afterHook(
                hook, abi.encodeCall(ITMPHook.onComplete, (taskId, LibTaskMarket._buildContext(taskId, s), verdict))
            );
        }
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Accept N submissions at once with explicit share basis points.
    ///         Valid for Bounty and Benchmark modes. Shares MUST sum to 10000.
    ///         Each worker's deliverable is resolved from the latest entry in
    ///         taskSubmissionHashes[taskId][worker]. Reverts SubmissionNotFound if
    ///         any winner has no prior submitWork call.
    /// @param taskId           Task identifier
    /// @param workers          Recipient addresses in rank order
    /// @param shares           Basis-point shares; MUST sum to 10000
    /// @param requesterAgentId ERC-8004 agentId of requester (0 if unknown); used for giveFeedback
    function acceptSubmissions(
        bytes32 taskId,
        address[] calldata workers,
        uint16[] calldata shares,
        uint256 requesterAgentId
    ) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
        _acceptSubmissions(taskId, requester, workers, shares, requesterAgentId, s);
        LibTaskMarket._nonReentrantAfter(s);
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
        if (task.mode != BOUNTY && task.mode != BENCHMARK) {
            if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        }
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
            bytes32[] storage submitted = s.taskSubmissionHashes[taskId][worker];
            bool found = false;
            for (uint256 i = 0; i < submitted.length; ++i) {
                if (submitted[i] == deliverable) {
                    found = true;
                    break;
                }
            }
            if (!found) revert ITMPCore.SubmissionNotFound();
            task.deliverable = deliverable;
        }
    }

    // Complexity is inherent: distributes proportional payouts across N winners with per-winner fee, hook, and event branches.
    // solhint-disable-next-line code-complexity
    function _acceptSubmissions(
        bytes32 taskId,
        address requester,
        address[] calldata workers,
        uint16[] calldata shares,
        uint256 requesterAgentId,
        AppStorage storage s
    ) private {
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.mode != BOUNTY && task.mode != BENCHMARK) revert ITMPCore.MultiSubmissionOnlyForBountyBenchmark();
        if (s.taskEvaluatorConfigs[taskId].evaluator != address(0)) revert ITMPCore.UseEvaluate();
        if (task.status != ITMPCore.TaskStatus.Open && task.status != ITMPCore.TaskStatus.PendingApproval) {
            revert ITMPCore.TaskNotOpen();
        }

        uint256 n = workers.length;
        if (n < 1) revert ITMPCore.NoWinners();
        if (shares.length != n) revert ITMPCore.LengthMismatch();

        // Resolve deliverables from on-chain submission history and validate shares sum.
        bytes32[] memory deliverables = new bytes32[](n);
        uint256 sumShares = 0;
        for (uint256 i; i < n; ++i) {
            if (workers[i] == address(0)) revert ITMPCore.WorkerRequired();
            bytes32[] storage submitted = s.taskSubmissionHashes[taskId][workers[i]];
            if (submitted.length == 0) revert ITMPCore.SubmissionNotFound();
            deliverables[i] = submitted[submitted.length - 1];
            sumShares += shares[i];
        }
        if (sumShares != 10000) revert ITMPCore.SharesMustSumTo10000();

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            awards[i] =
                ITMPCore.Award({ worker: workers[i], amount: (task.reward * shares[i]) / 10000, rank: uint16(i + 1) });
        }
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
        task.worker = workers[0];
        task.deliverable = deliverables[0]; // latest hash from on-chain submission history

        uint256 reward = task.reward;
        uint16 feeBps = task.feeBps;

        uint256[] memory nets = new uint256[](n);
        uint256[] memory fees = new uint256[](n);
        uint256 totalFee = 0;
        for (uint256 i; i < n; ++i) {
            uint256 pay = (reward * shares[i]) / 10000;
            if (pay == 0) revert ITMPCore.ZeroPayoutPerPair();
            uint256 fee = (reward * uint256(shares[i]) * uint256(feeBps)) / 100_000_000;
            nets[i] = pay - fee;
            fees[i] = fee;
            totalFee += fee;
            s.workerStats[workers[i]].completedTasks++;
        }
        if (totalFee > 0) s.totalFeesCollected += totalFee;

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkComplete(taskId, LibTaskMarket._buildContext(taskId, s), verdict)) {
                revert ITMPCore.HookCheckCompleteRejected();
            }
        }

        // Multi-winner payouts require iterating recipients. State fully committed before this loop (CEI).
        // slither-disable-next-line calls-loop
        bool anySelfAward = false;
        for (uint256 i; i < n; ++i) {
            if (!s.usdcToken.transfer(workers[i], nets[i])) revert ITMPCore.WorkerPaymentFailed();
            emit ITMPCore.TaskCompleted(taskId, requester, workers[i], nets[i], fees[i]);
            if (workers[i] == requester) {
                emit ITMPCore.SelfAward(taskId, requester, workers[i]);
                anySelfAward = true;
            }
        }
        if (totalFee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, totalFee)) revert ITMPCore.FeeTransferFailed();
        }

        emit ITMPCore.RequesterReputation(
            taskId,
            requester,
            keccak256("completed"),
            task.reward,
            uint32(s.taskActiveSubmissionCount[taskId]),
            anySelfAward
        );
        if (requesterAgentId != 0 && s.reputationRegistry != address(0)) {
            try IReputationRegistry(s.reputationRegistry)
                .giveFeedback(
                    requesterAgentId, 100, 0, "tmp.task.requester", _modeName(task.mode), "", "", bytes32(0)
                ) { }
                catch { }
        }

        if (hook != address(0)) {
            LibTaskMarket._afterHook(
                hook, abi.encodeCall(ITMPHook.onComplete, (taskId, LibTaskMarket._buildContext(taskId, s), verdict))
            );
        }
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
