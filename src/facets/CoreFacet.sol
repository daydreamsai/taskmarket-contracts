// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { IReputationRegistry } from "../interfaces/IReputationRegistry.sol";
import {
    TMP_BOUNTY,
    TMP_CLAIM,
    TMP_PITCH,
    TMP_BENCHMARK,
    TMP_AUCTION,
    TMP_AUCTION_DUTCH,
    TMP_AUCTION_ENGLISH,
    TMP_AUCTION_REVERSE_DUTCH,
    TMP_AUCTION_REVERSE_ENGLISH
} from "../interfaces/ITMPModes.sol";

/// @title CoreFacet — task lifecycle: create, claim, submit, forfeit, cancel, update, refund
/// @notice Handles all core task state transitions except acceptance (AcceptanceFacet)
///         and evaluation (EvaluatorFacet).
contract CoreFacet {
    bytes4 public constant BOUNTY = TMP_BOUNTY;
    bytes4 public constant CLAIM = TMP_CLAIM;
    bytes4 public constant PITCH = TMP_PITCH;
    bytes4 public constant BENCHMARK = TMP_BENCHMARK;
    bytes4 public constant AUCTION = TMP_AUCTION;
    bytes4 public constant AUCTION_DUTCH = TMP_AUCTION_DUTCH;
    bytes4 public constant AUCTION_ENGLISH = TMP_AUCTION_ENGLISH;
    bytes4 public constant AUCTION_REVERSE_DUTCH = TMP_AUCTION_REVERSE_DUTCH;
    bytes4 public constant AUCTION_REVERSE_ENGLISH = TMP_AUCTION_REVERSE_ENGLISH;

    uint256 public constant MAX_BIDS_PER_TASK = 500;

    /// @notice Create a new task with USDC escrow.
    ///         Task ID is contract-generated:
    ///           keccak256(abi.encode(block.chainid, address(this), requester, nonce))
    ///         The USDC reward MUST be transferred to this contract by the forwarder before calling.
    /// @param reward          USDC reward (6 decimals); for Auction = max price
    /// @param duration        Task lifetime in seconds
    /// @param mode            4-byte mode selector (use BOUNTY/CLAIM/PITCH/BENCHMARK/AUCTION)
    /// @param pitchDeadline   Seconds from now for pitch window (Pitch mode only, 0 otherwise)
    /// @param bidDeadline     Seconds from now for bid window (Auction mode only, 0 otherwise)
    /// @param auctionSubtype  Auction subtype selector (bytes4(0) for non-auction tasks)
    /// @param hookConfig      Hook contracts + hookData packed into one calldata pointer (Rev008).
    /// @param content         Content hash, URI, and tags (packed to reduce stack depth).
    // solhint-disable-next-line code-complexity
    function createTask(
        uint256 reward,
        uint256 duration,
        bytes4 mode,
        uint256 pitchDeadline,
        uint256 bidDeadline,
        bytes4 auctionSubtype,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content
    ) external returns (bytes32 taskId) {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
        if (requester == address(0)) revert ITMPCore.InvalidRequester();
        if (reward == 0) revert ITMPCore.RewardMustBeGreaterThanZero();
        if (duration == 0) revert ITMPCore.DurationMustBeGreaterThanZero();
        if (!(mode == BOUNTY || mode == CLAIM || mode == PITCH || mode == BENCHMARK || mode == AUCTION)) {
            revert ITMPCore.InvalidMode();
        }
        if (mode == AUCTION) {
            if (!(auctionSubtype == AUCTION_DUTCH || auctionSubtype == AUCTION_ENGLISH
                        || auctionSubtype == AUCTION_REVERSE_DUTCH || auctionSubtype == AUCTION_REVERSE_ENGLISH)) revert ITMPCore.InvalidAuctionSubtype();
        }

        taskId = keccak256(abi.encode(block.chainid, address(this), requester, s.requesterNonce[requester]++));

        ITMPCore.Task storage t = s.tasks[taskId];
        t.id = taskId;
        t.requester = requester;
        t.reward = reward;
        t.expiryTime = block.timestamp + duration;
        t.status = ITMPCore.TaskStatus.Open;
        t.mode = mode;
        t.feeBps = s.defaultFeeBps;

        ITMPCore.TaskMetadata storage meta = s.taskMetadata[taskId];
        meta.createdAt = block.timestamp;
        meta.contentHash = content.contentHash;
        meta.contentURI = content.contentURI;

        if (mode == PITCH) {
            if (pitchDeadline == 0) revert ITMPCore.PitchDeadlineMustBeGreaterThanZero();
            s.taskPitchConfigs[taskId].pitchDeadline = block.timestamp + pitchDeadline;
        }
        if (mode == AUCTION) {
            if (bidDeadline == 0) revert ITMPCore.BidDeadlineMustBeGreaterThanZero();
            ITMPCore.TaskAuctionConfig storage ac = s.taskAuctionConfigs[taskId];
            ac.bidDeadline = block.timestamp + bidDeadline;
            ac.maxPrice = reward;
            ac.auctionSubtype = auctionSubtype;
        }

        if (content.tags.length > 0) {
            s.taskTags[taskId] = content.tags;
        }

        _buildAndCheckHooks(taskId, hookConfig, s);

        emit ITMPCore.TaskCreated(taskId, requester, reward, mode, block.timestamp + duration);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Claim a Claim-mode task. The worker is the authenticated actor (pgtrSender).
    /// @param taskId      Task identifier
    /// @param stakeAmount USDC stake amount (0 = no stake required)
    function claimTask(bytes32 taskId, uint256 stakeAmount) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address worker = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (worker == address(0)) revert ITMPCore.InvalidWorker();
        if (task.mode != CLAIM) revert ITMPCore.NotAClaimTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();

        task.worker = worker;
        task.stakeAmount = stakeAmount;
        task.status = ITMPCore.TaskStatus.Claimed;
        s.taskMetadata[taskId].claimedAt = block.timestamp;

        LibTaskMarket._checkClaimHooks(taskId, worker, s);

        emit ITMPCore.TaskClaimed(taskId, worker, stakeAmount);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Select a worker for Pitch mode. The requester is the authenticated actor (pgtrSender).
    /// @param taskId Task identifier
    /// @param worker Selected worker address
    function selectWorker(bytes32 taskId, address worker) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.mode != PITCH) revert ITMPCore.NotAPitchTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        // pitchDeadline closes new submissions but does not block worker selection;
        // the requester may review and select from received pitches after the window closes.

        task.worker = worker;
        task.status = ITMPCore.TaskStatus.WorkerSelected;

        LibTaskMarket._checkSelectWorkerHooks(taskId, worker, s);

        emit ITMPCore.TaskWorkerSelected(taskId, worker);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Anchor a pitch-content hash on-chain. The worker is the authenticated actor.
    /// @param taskId    Task identifier
    /// @param pitchHash Content hash (typically keccak256(abi.encode(taskId, worker, pitchText)))
    function submitPitch(bytes32 taskId, bytes32 pitchHash) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address worker = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != PITCH) revert ITMPCore.NotAPitchTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > s.taskPitchConfigs[taskId].pitchDeadline) revert ITMPCore.PitchDeadlinePassed();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (pitchHash == bytes32(0)) revert ITMPCore.EmptyPitchHash();

        s.taskPitchHashes[taskId].push(pitchHash);

        emit ITMPCore.PitchSubmitted(taskId, worker, pitchHash);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Anchor a benchmark-proof hash on-chain. The worker is the authenticated actor.
    /// @param taskId      Task identifier
    /// @param proofHash   Content hash (typically keccak256(abi.encode(taskId, worker, proofData)))
    /// @param proofType   bytes32 selector identifying the proof scheme
    /// @param metricValue Task-specific numeric score
    function submitProof(bytes32 taskId, bytes32 proofHash, bytes32 proofType, uint256 metricValue) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address worker = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != BENCHMARK) revert ITMPCore.NotABenchmarkTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (proofHash == bytes32(0)) revert ITMPCore.EmptyProofHash();

        s.taskProofHashes[taskId].push(proofHash);

        emit ITMPCore.ProofSubmitted(taskId, worker, proofHash, proofType, metricValue);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Record that a worker has submitted deliverable work.
    ///         State change is mode-dependent. The worker is the authenticated actor.
    /// @param taskId      Task identifier
    /// @param deliverable Content hash (keccak256, IPFS CID, or ZK commitment)
    // Complexity is inherent: five task modes each require distinct state-transition branches.
    // solhint-disable-next-line code-complexity
    function submitWork(bytes32 taskId, bytes32 deliverable) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address worker = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();

        if (task.mode == BOUNTY || task.mode == BENCHMARK) {
            // Bounty and Benchmark are open contests: the task stays Open and keeps
            // accepting submissions until the requester accepts one (which moves it to
            // Accepted) or it expires. There is no status flip on submit.
            if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
            if (s.taskRejectedWorkers[taskId][worker]) revert ITMPCore.SubmissionAlreadyRejected();
            // Track on-chain that at least one submission exists. Used to protect workers
            // by blocking cancelTask and refundExpired once work has been submitted.
            s.taskHasSubmissions[taskId] = true;
            s.taskActiveSubmissionCount[taskId]++;
            // Append to version history so AcceptanceFacet can verify the hash was committed.
            s.taskSubmissionHashes[taskId][worker].push(deliverable);
            s.taskSubmissionHashExists[taskId][worker][deliverable] = true;
        } else if (task.mode == CLAIM) {
            if (task.status != ITMPCore.TaskStatus.Claimed) revert ITMPCore.TaskNotClaimed();
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            if (task.deliverable != bytes32(0)) revert ITMPCore.DeliverableAlreadySet();
            task.deliverable = deliverable;
        } else if (task.mode == PITCH || task.mode == AUCTION) {
            if (task.status != ITMPCore.TaskStatus.WorkerSelected && task.status != ITMPCore.TaskStatus.Claimed) {
                revert ITMPCore.WorkerNotSelected();
            }
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            if (task.deliverable != bytes32(0)) revert ITMPCore.DeliverableAlreadySet();
            task.deliverable = deliverable;
        }

        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (evalCfg.evaluator != address(0) && (task.mode == CLAIM || task.mode == PITCH || task.mode == AUCTION)) {
            task.status = ITMPCore.TaskStatus.Review;
            uint256 reviewDeadline = block.timestamp + evalCfg.evaluationWindow;
            s.phaseDeadline[taskId] = reviewDeadline;
            if (reviewDeadline > task.expiryTime) {
                task.expiryTime = reviewDeadline;
            }
        }

        LibTaskMarket._checkSubmitHooks(taskId, worker, deliverable, s);

        emit ITMPCore.TaskSubmitted(taskId, worker, deliverable);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Reject a submission from a worker on a bounty or benchmark task.
    ///         The requester is the authenticated actor (pgtrSender).
    ///         Costs the standard relay fee as anti-spam. Once all active submissions
    ///         are rejected, cancelTask becomes available.
    function rejectSubmission(bytes32 taskId, address worker) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
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
        // Falls back to 1 for pre-rejection (worker hasn't submitted yet) and for
        // submissions made before taskSubmissionHashes tracking was introduced.
        uint256 workerCount = s.taskSubmissionHashes[taskId][worker].length;
        uint256 decrement = workerCount > 0 ? workerCount : 1;
        uint256 active = s.taskActiveSubmissionCount[taskId];
        s.taskActiveSubmissionCount[taskId] = active > decrement ? active - decrement : 0;

        emit ITMPCore.SubmissionRejected(taskId, worker);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Forfeit worker's stake and reopen Claim task.
    ///         The requester is the authenticated actor (pgtrSender).
    function forfeitAndReopen(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
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

        LibTaskMarket._onForfeitHooks(taskId, forfeiter, s);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Cancel an open task and refund escrowed reward.
    ///         The requester is the authenticated actor (pgtrSender).
    function cancelTask(bytes32 taskId, uint256 requesterAgentId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
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
                try IReputationRegistry(s.reputationRegistry)
                    .giveFeedback(
                        requesterAgentId, -50, 0, "tmp.task.requester", _modeName(task.mode), "", "", bytes32(0)
                    ) { }
                    catch { }
            }
        }

        emit ITMPCore.TaskCancelled(taskId, requesterAddr, refundAmount);
        LibTaskMarket._onCancelHooks(taskId, s);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Update an open task's parameters. Pass 0 for any field to leave unchanged.
    ///         The requester is the authenticated actor (pgtrSender).
    // Complexity is inherent: each optional field requires independent validation and transfer branches.
    // solhint-disable-next-line code-complexity
    function updateTask(
        bytes32 taskId,
        uint256 newReward,
        uint256 newExpiryTime,
        uint256 newBidDeadline,
        uint256 newPitchDeadline
    ) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        address requester = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (task.mode == AUCTION && s.taskBids[taskId].length != 0) revert ITMPCore.BidsExist();

        uint256 originalReward = task.reward;
        uint256 originalExpiryTime = task.expiryTime;
        uint256 originalBidDeadline = s.taskAuctionConfigs[taskId].bidDeadline;
        uint256 originalPitchDeadline = s.taskPitchConfigs[taskId].pitchDeadline;

        uint256 refund = 0;
        if (newReward != 0 && newReward != task.reward) {
            refund = newReward < task.reward ? task.reward - newReward : 0;
            task.reward = newReward;
            if (task.mode == AUCTION) s.taskAuctionConfigs[taskId].maxPrice = newReward;
        }
        if (newExpiryTime != 0) {
            if (newExpiryTime <= block.timestamp) revert ITMPCore.ExpiryMustBeInFuture();
            task.expiryTime = newExpiryTime;
        }
        if (newBidDeadline != 0 && task.mode == AUCTION) {
            if (newBidDeadline <= block.timestamp) revert ITMPCore.BidDeadlineMustBeInFuture();
            s.taskAuctionConfigs[taskId].bidDeadline = newBidDeadline;
        }
        if (newPitchDeadline != 0 && task.mode == PITCH) {
            if (newPitchDeadline <= block.timestamp) revert ITMPCore.PitchDeadlineMustBeInFuture();
            s.taskPitchConfigs[taskId].pitchDeadline = newPitchDeadline;
        }
        if (refund > 0) {
            if (!s.usdcToken.transfer(task.requester, refund)) revert ITMPCore.USDCRefundFailed();
        }

        bool changed = (newReward != 0 && newReward != originalReward)
            || (newExpiryTime != 0 && newExpiryTime != originalExpiryTime)
            || (newBidDeadline != 0 && newBidDeadline != originalBidDeadline && task.mode == AUCTION)
            || (newPitchDeadline != 0 && newPitchDeadline != originalPitchDeadline && task.mode == PITCH);

        if (changed) emit ITMPCore.TaskUpdated(taskId, task.reward, task.expiryTime);
        LibTaskMarket._nonReentrantAfter(s);
    }

    /// @notice Refund expired task reward to requester.
    ///         NORMATIVE: bypasses all hooks. Callable by anyone.
    ///         Special case: Auction tasks with a selected winner auto-pay the worker.
    // Complexity is inherent: fund recovery must handle every possible task status and mode without hooks.
    // solhint-disable-next-line code-complexity
    function refundExpired(bytes32 taskId, uint256 requesterAgentId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireNotPaused(s);
        LibTaskMarket._nonReentrantBefore(s);

        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (block.timestamp <= task.expiryTime) revert ITMPCore.TaskNotYetExpired();
        if (task.status == ITMPCore.TaskStatus.Accepted) revert ITMPCore.TaskAlreadyAccepted();
        if (task.status == ITMPCore.TaskStatus.Cancelled) revert ITMPCore.TaskIsCancelled();
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
        LibTaskMarket._nonReentrantAfter(s);
    }

    function _buildAndCheckHooks(bytes32 taskId, ITMPCore.HookConfig calldata hookConfig, AppStorage storage s)
        private
    {
        uint256 defaultLen = s.defaultHooks.length;
        uint256 reqLen = hookConfig.contracts.length;
        if (defaultLen == 0 && reqLen == 0) return;
        if (defaultLen + reqLen > 8) revert ITMPCore.TooManyHooks();
        address[] storage th = s.taskHooks[taskId];
        for (uint256 i; i < defaultLen; i++) {
            th.push(s.defaultHooks[i]);
        }
        for (uint256 i; i < reqLen; i++) {
            address h = hookConfig.contracts[i];
            if (h == address(0)) revert ITMPCore.InvalidHookAddress();
            if (h.code.length == 0) revert ITMPCore.InvalidHookAddress();
            for (uint256 j; j < defaultLen; j++) {
                if (s.defaultHooks[j] == h) revert ITMPCore.DuplicateHookAddress();
            }
            for (uint256 j; j < i; j++) {
                if (hookConfig.contracts[j] == h) revert ITMPCore.DuplicateHookAddress();
            }
            th.push(h);
        }
        LibTaskMarket._checkFundHooks(taskId, th, hookConfig.data, s);
    }

    function _refundAuctionClaimed(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private {
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
        LibTaskMarket._onCompleteHooks(taskId, s, verdict);
    }

    function _refundExpiredNormal(
        bytes32 taskId,
        ITMPCore.Task storage task,
        AppStorage storage s,
        uint256 requesterAgentId
    ) private {
        task.status = ITMPCore.TaskStatus.Expired;
        uint256 refundAmount = task.reward;

        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
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
                try IReputationRegistry(s.reputationRegistry)
                    .giveFeedback(
                        requesterAgentId, -50, 0, "tmp.task.requester", _modeName(task.mode), "", "", bytes32(0)
                    ) { }
                    catch { }
            }
        }

        // NORMATIVE: onExpire MUST NOT block fund recovery. Always try-catch (dispatchAfterHooks).
        LibTaskMarket._onExpireHooks(taskId, s);
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
