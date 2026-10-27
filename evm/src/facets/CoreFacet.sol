// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibTaskLimits } from "../libraries/LibTaskLimits.sol";
import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { LibReview } from "../libraries/LibReview.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { LibFeedback } from "../libraries/LibFeedback.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
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

/// @title CoreFacet — task lifecycle: create, claim, submit, update
/// @notice Handles core task state transitions except acceptance (AcceptanceFacet),
///         evaluation (EvaluatorFacet) and rejection, forfeit, cancel and refund (SettlementFacet).
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
    /// @param config          Reward (6-decimal USDC; for Auction = max price), duration, mode,
    ///                        and the mode-specific pitch/bid deadlines and auction subtype.
    /// @param hookConfig      Hook contracts + hookData packed into one calldata pointer (Rev008).
    /// @param content         Content hash, URI, and tags (packed to reduce stack depth).
    /// @param evaluatorConfig Evaluator terms, applied in this same transaction. Pass the zero
    ///                        struct for a task with no evaluator. Configuring an evaluator here
    ///                        rather than via a following `assignEvaluator` call is the only way
    ///                        to do it without a race: the task is Open, and so claimable, the
    ///                        instant this transaction mines, and `assignEvaluator` reverts
    ///                        `TaskNotOpen` once a worker has claimed.
    /// @param terms           Settlement terms (rev025), the stake requirement included. Zero
    ///                        fields take the protocol defaults; see ITMPCore.TaskTerms for the
    ///                        encodings. Reverts InvalidTerms outside the owner-set bounds, or for
    ///                        a Reopen reject outcome on an auction. `terms.version` is ignored.
    /// @dev The rev018 overload taking a StakeConfig and recording default terms was removed in
    ///      rev026; its selector no longer routes.
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms
    ) external returns (bytes32) {
        return _createTask(config, hookConfig, content, evaluatorConfig, terms, address(0));
    }

    /// @notice Rev027: create a Claim task with a reserved worker. As createTask, and only that
    ///         worker may claim (accept) or decline it, up to and including the accept-by time:
    ///         creation plus terms.acceptWindowSecs (0 = 72 hours; otherwise 1 hour to 30 days).
    ///         config.duration is the delivery period, counted from the claim, and must be at
    ///         least the accept window. A rejected delivery refunds the requester, so
    ///         terms.rejectOutcome may not be Reopen. reservedWorker zero creates an ordinary task.
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms,
        address reservedWorker
    ) external returns (bytes32) {
        return _createTask(config, hookConfig, content, evaluatorConfig, terms, reservedWorker);
    }

    /// @notice The rev025 createTask taking version 1 terms (no acceptWindowSecs), kept routed by
    ///         rev027 so callers can move to the version 2 encoding after the cut. It creates a task
    ///         with no reserved worker and records version 2 terms. A later revision removes it.
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTermsV1 calldata terms
    ) external returns (bytes32) {
        ITMPCore.TaskTerms memory t = ITMPCore.TaskTerms({
            version: terms.version,
            stakeRequired: terms.stakeRequired,
            stakeBps: terms.stakeBps,
            penaltyTo: terms.penaltyTo,
            reviewWindowSecs: terms.reviewWindowSecs,
            decisionWindowSecs: terms.decisionWindowSecs,
            reopenExtensionSecs: terms.reopenExtensionSecs,
            releaseAllowed: terms.releaseAllowed,
            releaseGraceBps: terms.releaseGraceBps,
            rejectOutcome: terms.rejectOutcome,
            rejectFeeBps: terms.rejectFeeBps,
            maxRevisions: terms.maxRevisions,
            resolutionWindowSecs: terms.resolutionWindowSecs,
            acceptWindowSecs: 0
        });
        return _createTask(config, hookConfig, content, evaluatorConfig, t, address(0));
    }

    function _createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms memory terms,
        address reservedWorker
    ) private returns (bytes32 taskId) {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        taskId = _initTask(requester, config, content, terms, reservedWorker != address(0), s);
        if (reservedWorker != address(0)) _reserve(taskId, requester, reservedWorker, config.duration, terms, s);

        // Applied before the hooks so a checkFund hook observes a fully configured task rather
        // than one that only becomes evaluator-gated a moment later.
        _applyCreationEvaluatorConfig(taskId, requester, evaluatorConfig, s);

        _buildAndCheckHooks(taskId, hookConfig, s);

        ITMPCore.Task storage t = s.tasks[taskId];
        emit ITMPCore.TaskCreated(taskId, requester, t.reward, t.mode, t.expiryTime, t.stakeRequired, t.stakeBps);
        emit ITMPCore.TaskTermsSet(taskId, s.taskTerms[taskId]);
        if (reservedWorker != address(0)) {
            emit ITMPCore.TaskReserved(taskId, reservedWorker, LibTerms.acceptBy(s, taskId));
        }
        LibEscrow.book(s, taskId, requester, ITMPEscrow.Component.Task, true);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev Validates the task and records it, its terms and its content.
    // solhint-disable-next-line code-complexity
    function _initTask(
        address requester,
        ITMPCore.TaskConfig calldata config,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskTerms memory terms,
        bool reserved,
        AppStorage storage s
    ) private returns (bytes32 taskId) {
        if (requester == address(0)) revert ITMPCore.InvalidRequester();
        if (config.reward == 0) revert ITMPCore.RewardMustBeGreaterThanZero();
        if (config.duration == 0) revert ITMPCore.DurationMustBeGreaterThanZero();
        if (!(config.mode == BOUNTY || config.mode == CLAIM || config.mode == PITCH || config.mode == BENCHMARK
                    || config.mode == AUCTION)) {
            revert ITMPCore.InvalidMode();
        }
        if (config.mode == AUCTION) {
            if (!(config.auctionSubtype == AUCTION_DUTCH || config.auctionSubtype == AUCTION_ENGLISH
                        || config.auctionSubtype == AUCTION_REVERSE_DUTCH
                        || config.auctionSubtype == AUCTION_REVERSE_ENGLISH)) revert ITMPCore.InvalidAuctionSubtype();
        }
        LibTerms.validate(s, terms, config.mode, reserved);

        taskId = keccak256(abi.encode(block.chainid, address(this), requester, s.requesterNonce[requester]++));

        ITMPCore.Task storage t = s.tasks[taskId];
        t.id = taskId;
        t.requester = requester;
        t.reward = config.reward;
        t.expiryTime = block.timestamp + config.duration;
        t.status = ITMPCore.TaskStatus.Open;
        t.mode = config.mode;
        t.feeBps = s.defaultFeeBps;
        t.stakeRequired = terms.stakeRequired;
        t.stakeBps = terms.stakeBps;
        terms.version = LibTerms.TERMS_VERSION;
        s.taskTerms[taskId] = terms;

        ITMPCore.TaskMetadata storage meta = s.taskMetadata[taskId];
        meta.createdAt = block.timestamp;
        meta.contentHash = content.contentHash;
        meta.contentURI = content.contentURI;

        if (config.mode == PITCH) {
            if (config.pitchDeadline == 0) revert ITMPCore.PitchDeadlineMustBeGreaterThanZero();
            s.taskPitchConfigs[taskId].pitchDeadline = block.timestamp + config.pitchDeadline;
        }
        if (config.mode == AUCTION) {
            if (config.bidDeadline == 0) revert ITMPCore.BidDeadlineMustBeGreaterThanZero();
            ITMPCore.TaskAuctionConfig storage ac = s.taskAuctionConfigs[taskId];
            ac.bidDeadline = block.timestamp + config.bidDeadline;
            ac.maxPrice = config.reward;
            ac.auctionSubtype = config.auctionSubtype;
        }

        if (content.tags.length > LibTaskLimits.maxTags(s)) revert ITMPCore.TooManyTags();
        if (content.tags.length > 0) {
            s.taskTags[taskId] = content.tags;
        }
    }

    /// @dev Rev027: records the reserved worker. The worker may not be the requester, and the
    ///      delivery period may not be shorter than the accept window, so the task's expiry is
    ///      never before its accept-by time and the worker always has the whole window.
    function _reserve(
        bytes32 taskId,
        address requester,
        address worker,
        uint256 duration,
        ITMPCore.TaskTerms memory terms,
        AppStorage storage s
    ) private {
        if (worker == requester) revert ITMPCore.InvalidWorker();
        if (duration < LibTerms.acceptWindow(terms)) revert ITMPCore.InvalidTerms();
        s.reservedWorkers[taskId] = worker;
    }

    /// @notice Claim a Claim-mode task. The worker is the authenticated actor (pgtrSender).
    /// @param taskId      Task identifier
    /// @param stakeAmount USDC stake amount (0 = no stake required)
    function claimTask(bytes32 taskId, uint256 stakeAmount) external {
        _claimTask(taskId, stakeAmount, 0);
    }

    /// @notice Rev027: claimTask that also binds the worker's ERC-8004 agent ID when it accepts a
    ///         reservation, so a later forfeit's feedback reaches the worker. The ID is bound only
    ///         when a trusted forwarder relays the worker's own call; 0 binds nothing.
    /// @param workerAgentId ERC-8004 agent ID of the worker (0 if unknown)
    function claimTask(bytes32 taskId, uint256 stakeAmount, uint256 workerAgentId) external {
        _claimTask(taskId, stakeAmount, workerAgentId);
    }

    function _claimTask(bytes32 taskId, uint256 stakeAmount, uint256 workerAgentId) private {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (worker == address(0)) revert ITMPCore.InvalidWorker();
        if (task.mode != CLAIM) revert ITMPCore.NotAClaimTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (s.taskRejectedWorkers[taskId][worker]) revert ITMPCore.SubmissionAlreadyRejected();
        if (s.reservedWorkers[taskId] != address(0)) {
            _acceptReservation(taskId, task, worker, s);
            LibFeedback.bindWorker(s, worker, workerAgentId);
        }
        LibGuards._requireStakePayment(stakeAmount);
        if (stakeAmount < LibTerms.minStake(s.taskTerms[taskId], task.reward)) {
            revert ITMPCore.StakePaymentMismatch();
        }

        task.worker = worker;
        task.stakeAmount = stakeAmount;
        task.status = ITMPCore.TaskStatus.Claimed;
        s.taskMetadata[taskId].claimedAt = block.timestamp;

        LibHooks._checkClaimHooks(taskId, worker, s);

        emit ITMPCore.TaskClaimed(taskId, worker, stakeAmount);
        LibEscrow.book(s, taskId, worker, ITMPEscrow.Component.WorkerStake, false);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev Rev027: a task with a reserved worker is claimed only by that worker, by the accept-by
    ///      time, and its delivery period (the span from creation to expiry) restarts at the claim,
    ///      so time spent deciding never shortens it.
    function _acceptReservation(bytes32 taskId, ITMPCore.Task storage task, address worker, AppStorage storage s)
        private
    {
        if (worker != s.reservedWorkers[taskId]) revert ITMPCore.NotReservedWorker();
        if (block.timestamp > LibTerms.acceptBy(s, taskId)) revert ITMPCore.AcceptWindowClosed();
        uint256 newExpiry = block.timestamp + (task.expiryTime - s.taskMetadata[taskId].createdAt);
        if (newExpiry != task.expiryTime) {
            task.expiryTime = newExpiry;
            emit ITMPCore.TaskExpiryExtended(taskId, newExpiry);
        }
    }

    /// @notice Select a worker for Pitch mode. The requester is the authenticated actor (pgtrSender).
    /// @param taskId Task identifier
    /// @param worker Selected worker address
    function selectWorker(bytes32 taskId, address worker) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.mode != PITCH) revert ITMPCore.NotAPitchTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        // pitchDeadline closes new submissions but does not block worker selection;
        // the requester may review and select from received pitches after the window closes.
        if (s.taskRejectedWorkers[taskId][worker]) revert ITMPCore.SubmissionAlreadyRejected();

        task.worker = worker;
        task.status = ITMPCore.TaskStatus.WorkerSelected;

        LibHooks._checkSelectWorkerHooks(taskId, worker, s);

        emit ITMPCore.TaskWorkerSelected(taskId, worker);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Anchor a pitch-content hash on-chain. The worker is the authenticated actor.
    /// @param taskId    Task identifier
    /// @param pitchHash Content hash (typically keccak256(abi.encode(taskId, worker, pitchText)))
    function submitPitch(bytes32 taskId, bytes32 pitchHash) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != PITCH) revert ITMPCore.NotAPitchTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > s.taskPitchConfigs[taskId].pitchDeadline) revert ITMPCore.PitchDeadlinePassed();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (pitchHash == bytes32(0)) revert ITMPCore.EmptyPitchHash();

        s.taskPitchHashes[taskId].push(pitchHash);

        emit ITMPCore.PitchSubmitted(taskId, worker, pitchHash);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Anchor a benchmark-proof hash on-chain. The worker is the authenticated actor.
    /// @param taskId      Task identifier
    /// @param proofHash   Content hash (typically keccak256(abi.encode(taskId, worker, proofData)))
    /// @param proofType   bytes32 selector identifying the proof scheme
    /// @param metricValue Task-specific numeric score
    function submitProof(bytes32 taskId, bytes32 proofHash, bytes32 proofType, uint256 metricValue) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (task.mode != BENCHMARK) revert ITMPCore.NotABenchmarkTask();
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
        if (proofHash == bytes32(0)) revert ITMPCore.EmptyProofHash();

        s.taskProofHashes[taskId].push(proofHash);

        emit ITMPCore.ProofSubmitted(taskId, worker, proofHash, proofType, metricValue);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Record that a worker has submitted deliverable work.
    ///         State change is mode-dependent. The worker is the authenticated actor.
    /// @param taskId      Task identifier
    /// @param deliverable Content hash (keccak256, IPFS CID, or ZK commitment)
    // Complexity is inherent: five task modes each require distinct state-transition branches.
    // solhint-disable-next-line code-complexity
    function submitWork(bytes32 taskId, bytes32 deliverable) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address worker = LibGuards._effectiveSender(s);
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
            _recordDelivery(taskId, task, deliverable, s);
        } else if (task.mode == PITCH || task.mode == AUCTION) {
            if (task.status != ITMPCore.TaskStatus.WorkerSelected && task.status != ITMPCore.TaskStatus.Claimed) {
                revert ITMPCore.WorkerNotSelected();
            }
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
            _recordDelivery(taskId, task, deliverable, s);
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

        LibHooks._checkSubmitHooks(taskId, worker, deliverable, s);

        emit ITMPCore.TaskSubmitted(taskId, worker, deliverable);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev A single-payee task without an evaluator opens its review window at delivery; a
    ///      resubmission is allowed only while a revision request is open.
    function _recordDelivery(bytes32 taskId, ITMPCore.Task storage task, bytes32 deliverable, AppStorage storage s)
        private
    {
        ITMPCore.TaskClock storage clock = s.taskClocks[taskId];
        if (task.deliverable != bytes32(0) && !LibReview.revisionOpen(clock)) revert ITMPCore.DeliverableAlreadySet();
        task.deliverable = deliverable;
        if (s.taskEvaluatorConfigs[taskId].evaluator == address(0)) {
            clock.deliveredAt = uint64(block.timestamp);
            clock.revisionDueAt = 0;
        }
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
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (requester != task.requester) revert ITMPCore.NotRequester();
        LibTerms.requireTermsOpen(s, taskId, task);
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (task.mode == AUCTION && s.taskBids[taskId].length != 0) revert ITMPCore.BidsExist();
        // Rev027: a claimTask carries no expected terms, so a pending offer must not change under
        // the worker's answer. The requester withdraws it (cancelTask) and makes a new one.
        if (s.reservedWorkers[taskId] != address(0) && block.timestamp <= LibTerms.acceptBy(s, taskId)) {
            revert ITMPCore.ReservationPending();
        }

        uint256 originalReward = task.reward;
        uint256 originalExpiryTime = task.expiryTime;
        uint256 originalBidDeadline = s.taskAuctionConfigs[taskId].bidDeadline;
        uint256 originalPitchDeadline = s.taskPitchConfigs[taskId].pitchDeadline;

        // A reward that is named but unchanged must revert, not no-op. The USDC for a reward
        // increase is pulled by the forwarder BEFORE this call runs, and the Diamond has no way
        // to hand it back -- so a silent no-op here keeps money that corresponds to no liability,
        // and a duplicate relay of the same increase (a retry with a fresh receipt nonce, which
        // the forwarder's replay guard does not and cannot catch) charges the requester twice for
        // one increase. Reverting is the only mechanism available on this side of the forwarder
        // boundary that unwinds the transfer, because the whole transaction unwinds with it.
        // Callers leave a field unchanged by passing 0, so this rejects nothing legitimate.
        if (newReward != 0 && newReward == task.reward) revert ITMPCore.NoRewardChange();

        uint256 refund = 0;
        // The forwarder must have moved exactly the increase into escrow, and nothing on an update
        // that raises no reward. LibEscrow.book below checks the increase is covered by the
        // unbooked balance for a booked task.
        LibGuards._requireReportedPayment(newReward > task.reward ? newReward - task.reward : 0);
        if (newReward != 0 && newReward != task.reward) {
            if (newReward < task.reward) {
                refund = task.reward - newReward;
            }
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
            uint256 balanceBefore = LibEscrow.balance(s);
            if (!s.usdcToken.transfer(task.requester, refund)) revert ITMPCore.USDCRefundFailed();
            LibEscrow.release(s, taskId, balanceBefore);
        } else if (newReward > originalReward) {
            LibEscrow.book(s, taskId, requester, ITMPEscrow.Component.RewardIncrease, false);
        }

        bool changed = (newReward != 0 && newReward != originalReward)
            || (newExpiryTime != 0 && newExpiryTime != originalExpiryTime)
            || (newBidDeadline != 0 && newBidDeadline != originalBidDeadline && task.mode == AUCTION)
            || (newPitchDeadline != 0 && newPitchDeadline != originalPitchDeadline && task.mode == PITCH);

        if (changed) emit ITMPCore.TaskUpdated(taskId, task.reward, task.expiryTime);
        LibGuards._nonReentrantAfter(s);
    }

    /// @dev Creation-side wrapper around the shared evaluator-config body. Kept in its own frame
    ///      so the struct copy and stake-pull locals do not add to createTask's already-deep
    ///      stack. A zero `evaluator` means the task has no evaluator, which is the common case.
    function _applyCreationEvaluatorConfig(
        bytes32 taskId,
        address requester,
        ITMPCore.TaskEvaluatorConfig memory evaluatorConfig,
        AppStorage storage s
    ) private {
        if (evaluatorConfig.evaluator != address(0)) {
            LibTaskMarket._applyEvaluatorConfig(taskId, requester, evaluatorConfig, s.tasks[taskId].reward, s);
            return;
        }
        // Evaluator terms with no evaluator to apply them to would be silently dropped, leaving
        // the requester believing the task is evaluator-gated when it is not -- and believing it
        // for the whole life of the task, since nothing ever reports the discarded fields.
        // A malformed request is worth a revert here; a misconfigured escrow is not recoverable.
        if (
            evaluatorConfig.evaluatorStake != 0 || evaluatorConfig.evaluatorFeeBps != 0
                || evaluatorConfig.evaluationWindow != 0 || evaluatorConfig.appealWindow != 0
                || evaluatorConfig.disputeResolver != address(0)
        ) {
            revert ITMPCore.InvalidEvaluator();
        }
        // The reward is the whole payment of an evaluator-less create.
        LibGuards._requireReportedPayment(s.tasks[taskId].reward);
    }

    function _buildAndCheckHooks(bytes32 taskId, ITMPCore.HookConfig calldata hookConfig, AppStorage storage s)
        private
    {
        uint256 defaultLen = s.defaultHooks.length;
        uint256 reqLen = hookConfig.contracts.length;
        if (defaultLen == 0 && reqLen == 0) return;
        if (defaultLen + reqLen > LibTaskLimits.maxHooks(s)) revert ITMPCore.TooManyHooks();
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
        LibHooks._checkFundHooks(taskId, th, hookConfig.data, s);
    }
}
