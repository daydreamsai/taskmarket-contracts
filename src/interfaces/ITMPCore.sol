// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ITMPCore — Task Market Protocol core interface
/// @notice Defines the canonical interface for on-chain task marketplaces
///         that support multi-mode task coordination with USDC escrow.
///
///         Implementations MUST:
///         - Implement all functions declared in this interface
///         - Return true from supportsInterface(type(ITMPCore).interfaceId)
///         - Emit the declared events on every corresponding state transition
///         - Ensure refundExpired() bypasses all hooks/extensions (fund safety)
///
/// requires: ERC-20, ERC-165, ERC-8004
///
/// note: ITMPCore does NOT mandate any particular authentication mechanism. An implementation
///       MUST authenticate the requester and worker for each task action, but the mechanism
///       is implementation-defined (direct msg.sender, ERC-2771, ERC-4337, ERC-8194 PGTR,
///       x402 settlement callback, etc.). The reference implementation uses ERC-8194 PGTR.
interface ITMPCore is IERC165 {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    // Access control
    error NotTrustedForwarder();
    error NotRequester();
    error NotWorker();
    error NotEvaluator();
    error NotDisputeResolver();

    // Task existence / state
    error TaskDoesNotExist();
    error TaskNotOpen();
    error TaskNotClaimed();
    error TaskNotAccepted();
    error TaskAlreadyAccepted();
    error TaskIsCancelled();
    error TaskIsExpired();
    error TaskNotYetExpired();
    error NotInAppealingState();
    error NotInDisputedState();
    error NotInReviewState();

    // Mode
    error NotAClaimTask();
    error NotAPitchTask();
    error NotAnAuctionTask();
    error NotABenchmarkTask();
    error NotAClockPriceAuction();
    error NotABidAuction();
    error InvalidMode();
    error InvalidAuctionSubtype();
    error MultiSubmissionOnlyForBountyBenchmark();

    // Worker / deliverable
    error InvalidWorker();
    error InvalidRequester();
    error WorkerMismatch();
    error WorkerAlreadyRated();
    error WorkerRequired();
    error DeliverableRequired();
    error DeliverableMismatch();
    error DeliverableAlreadySet();
    error WorkerNotSelected();
    error WinnerNotSelected();
    error UseEvaluate();

    // Evaluator / appeal
    error EvaluatorAlreadyAssigned();
    error InvalidEvaluator();
    error WrongStatusForEvaluation();
    error AppealWindowClosed();
    error AppealWindowStillOpen();
    error NoVerdictIssued();
    error EvaluationWindowNotExpired();
    error DisputeResolutionMustAwardWorkers();
    error AwardsRequired();

    // Auction
    error BidDeadlinePassed();
    error BidExceedsMaxPrice();
    error BidDeadlineNotPassed();
    error NoBidsSubmitted();
    error BidsExist();
    error PriceExceedsMaxPrice();
    error BidLimitReached();

    // Deadline / timing
    error PitchDeadlinePassed();
    error ExpiryMustBeInFuture();
    error BidDeadlineMustBeInFuture();
    error PitchDeadlineMustBeInFuture();
    error SubmissionsExist();
    error SubmissionAlreadyRejected();
    error NoActiveSubmissions();
    error SubmissionNotFound();

    // Config / params
    error InvalidFeeRecipient();
    error InvalidUSDCToken();
    error InvalidRecipient();
    error InvalidForwarderAddress();
    error FeeBpsTooHigh();
    error RewardMustBeGreaterThanZero();
    error DurationMustBeGreaterThanZero();
    error PitchDeadlineMustBeGreaterThanZero();
    error BidDeadlineMustBeGreaterThanZero();
    error EmptyPitchHash();
    error EmptyProofHash();
    error RatingMustBe0To100();
    error NoWinners();
    error LengthMismatch();
    error SharesMustSumTo10000();
    error AwardsExceedEscrow();
    error ZeroPayoutPerPair();

    // Transfers
    error WorkerPaymentFailed();
    error FeeTransferFailed();
    error StakeReturnFailed();
    error AuctionRefundFailed();
    error RefundFailed();
    error ForfeitTransferFailed();
    error StakeTransferFailed();
    error EvaluatorPaymentFailed();
    error RequesterRefundFailed();
    error USDCRefundFailed();
    error ExcessRefundFailed();

    // Hooks
    error HookCheckFundRejected();
    error HookCheckClaimRejected();
    error HookCheckSelectWorkerRejected();
    error HookCheckSubmitRejected();
    error HookCheckCompleteRejected();
    error HookCheckEvaluateRejected();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Canonical task lifecycle states.
    ///         Review/Appealing/Disputed are activated by assigning an evaluator (ERC-8195).
    enum TaskStatus {
        Open,
        Claimed,
        WorkerSelected,
        PendingApproval,
        Accepted,
        Expired,
        Cancelled,
        Review,
        Appealing,
        Disputed
    }

    /// @notice Verdict classification issued by an evaluator.
    enum VerdictType {
        APPROVE,
        REJECT,
        PARTIAL
    }

    /// @notice Single-winner payout record within a Verdict.
    struct Award {
        address worker;
        uint256 amount;
        uint16 rank;
    }

    /// @notice Evaluation outcome stored on-chain.
    ///         issued = false until evaluate() is called.
    struct Verdict {
        bool issued;
        VerdictType verdictType;
        uint16 score;
        uint16 confidence;
        bytes32[] criteriaFlags;
        bytes32 evidenceHash;
        Award[] awards;
    }

    /// @notice Snapshot of task state passed to ITMPHook callbacks.
    struct TaskContext {
        bytes32 taskId;
        address requester;
        address evaluator;
        address paymentToken;
        uint256 reward;
        uint256 evaluatorStake;
        uint256 evaluatorFeeBps;
        uint256 submissionDeadline;
        uint256 evaluationWindow;
        uint256 appealWindow;
        address disputeResolver;
        TaskStatus currentState;
        bytes4 mode;
        bytes32[] tags;
    }

    /// @notice Evaluator configuration for a task. Stored separately from the core Task
    ///         struct so that the ABI encoder for getTask() stays within Yul stack limits.
    ///         All fields are zero for tasks that have no evaluator assigned.
    struct TaskEvaluatorConfig {
        address evaluator;
        uint256 evaluatorStake;
        uint16 evaluatorFeeBps;
        uint32 evaluationWindow;
        uint32 appealWindow;
        address disputeResolver;
    }

    /// @notice Auction configuration for a task. Stored separately from the core Task
    ///         struct. All fields are zero for non-auction tasks.
    struct TaskAuctionConfig {
        uint256 bidDeadline;
        uint256 maxPrice;
        bytes4 auctionSubtype;
        address lowestBidder;
        uint256 lowestBidPrice;
    }

    /// @notice Write-once informational fields that are never read by internal contract
    ///         logic. Separated from the core Task struct to keep the getTask() ABI
    ///         encoder within Yul stack limits under the coverage compiler.
    struct TaskMetadata {
        uint256 createdAt;
        uint256 claimedAt;
        bytes32 contentHash;
        string contentURI;
    }

    /// @notice Pitch-mode scheduling config. Zero for non-pitch tasks.
    struct TaskPitchConfig {
        uint256 pitchDeadline;
    }

    /// @notice Core task descriptor returned by getTask().
    ///         Write-once metadata lives in taskMetadata(); mode-specific extension
    ///         data lives in taskEvaluatorConfigs(), taskAuctionConfigs(), and
    ///         taskPitchConfigs(). This keeps the ABI encoder within Yul stack limits.
    struct Task {
        bytes32 id;
        address requester;
        address worker;
        TaskStatus status;
        bytes4 mode;
        uint256 reward;
        uint256 expiryTime;
        uint256 stakeAmount;
        uint16 feeBps;
        bytes32 deliverable;
        uint8 rating;
        address hookContract;
    }

    /// @notice Worker performance statistics.
    /// @dev avgRating = ratedTasks > 0 ? (totalStars * 100) / ratedTasks : 0
    struct WorkerStats {
        uint256 completedTasks;
        uint256 ratedTasks;
        uint256 totalStars;
    }

    /// @notice Single bid record for English / Reverse-English auction tasks.
    struct Bid {
        address worker;
        uint256 price;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a trusted forwarder is added or removed.
    ///         Implementations using the forwarder pattern MUST emit this on every
    ///         setTrustedForwarder / removeTrustedForwarder call.
    event ForwarderUpdated(address indexed forwarder, bool trusted);

    /// @notice Emitted when a hook contract is registered for a task.
    event HookRegistered(bytes32 indexed taskId, address hookContract);

    /// @notice Emitted when an after-hook call fails. Failures are swallowed so a buggy
    ///         hook cannot block fund recovery; this event makes failures observable on-chain.
    event HookCallFailed(address indexed hook);

    /// @notice Emitted when a task is created and reward is escrowed.
    event TaskCreated(
        bytes32 indexed taskId, address indexed requester, uint256 reward, bytes4 indexed mode, uint256 expiryTime
    );

    /// @notice Emitted when a task is completed and worker is paid.
    event TaskCompleted(
        bytes32 indexed taskId,
        address indexed requester,
        address indexed worker,
        uint256 workerPayment,
        uint256 platformFee
    );

    /// @notice Emitted when a worker submits work (deliverable hash anchored on-chain).
    event TaskSubmitted(bytes32 indexed taskId, address indexed worker, bytes32 deliverable);

    /// @notice Emitted when a requester rejects a worker's submission on a bounty or benchmark task.
    event SubmissionRejected(bytes32 indexed taskId, address indexed worker);

    /// @notice Emitted when a task expires and the reward is refunded.
    event TaskExpired(bytes32 indexed taskId, address indexed requester, uint256 refundAmount);

    /// @notice Emitted when a requester cancels an open task and receives a refund.
    event TaskCancelled(bytes32 indexed taskId, address indexed requester, uint256 refundAmount);

    /// @notice Emitted when a requester rates a completed task.
    event TaskRated(
        bytes32 indexed taskId,
        address indexed worker,
        uint8 rating,
        uint256 raterAgentId // ERC-8004 agent ID of the requester (0 if unregistered)
    );

    /// @notice Emitted when a Claim-mode task is claimed by a worker.
    event TaskClaimed(bytes32 indexed taskId, address indexed worker, uint256 stakeAmount);

    /// @notice Emitted when a Pitch/Benchmark-mode worker is selected.
    event TaskWorkerSelected(bytes32 indexed taskId, address indexed worker);

    /// @notice Emitted when a Claim-mode worker's stake is forfeited.
    event StakeForfeited(bytes32 indexed taskId, address indexed worker, uint256 stakeAmount);

    /// @notice Emitted when a Claim-mode worker's stake is returned on expiry.
    event StakeReturned(bytes32 indexed taskId, address indexed worker, uint256 stakeAmount);

    /// @notice Emitted when a forfeited task is reopened for new claims / pitches.
    event TaskReopened(bytes32 indexed taskId);

    /// @notice Emitted when a requester updates the reward or expiry of an open task.
    event TaskUpdated(bytes32 indexed taskId, uint256 newReward, uint256 newExpiryTime);

    /// @notice Emitted when a worker submits a bid for an English/Reverse-English auction.
    event BidSubmitted(bytes32 indexed taskId, address indexed worker, uint256 price);

    /// @notice Emitted when a worker accepts a Dutch/Reverse-Dutch clock-price auction.
    ///         Coexists with BidSubmitted + TaskWorkerSelected for backward indexer compatibility.
    event AuctionAccepted(bytes32 indexed taskId, address indexed worker, uint256 acceptedPrice);

    /// @notice Emitted when a worker anchors a pitch hash for a Pitch-mode task.
    event PitchSubmitted(bytes32 indexed taskId, address indexed worker, bytes32 pitchHash);

    /// @notice Emitted when a worker anchors a proof hash for a Benchmark-mode task.
    ///         proofType is keccak256(typeString); metricValue is a task-specific score.
    event ProofSubmitted(
        bytes32 indexed taskId, address indexed worker, bytes32 proofHash, bytes32 proofType, uint256 metricValue
    );

    /// @notice Emitted when the accepting worker address equals the task requester address.
    ///         No slashing — immutable signal for off-chain reputation indexers.
    event SelfAward(bytes32 indexed taskId, address indexed requester, address indexed worker);

    /// @notice Emitted at every bounty/benchmark terminal state to record requester behaviour.
    ///         event_: keccak256 of one of:
    ///           "completed"                   — task paid out
    ///           "cancelled_after_submissions" — requester cancelled after all submissions were rejected
    ///           "expired_no_action"           — task expired with no submissions ever
    ///           "expired_after_rejections"    — task expired after all submissions were rejected
    ///         submissionCount is 0 for cancelled/expired-after-rejection (rejectSubmission decrements
    ///         taskActiveSubmissionCount; the event_ field is the authoritative discriminator).
    event RequesterReputation(
        bytes32 indexed taskId,
        address indexed requester,
        bytes32 event_,
        uint256 reward,
        uint32 submissionCount,
        bool selfAward
    );

    // -------------------------------------------------------------------------
    // Required functions
    // -------------------------------------------------------------------------

    /// @notice Create a new task and escrow the reward.
    ///         The contract MUST generate the task ID as:
    ///         keccak256(abi.encode(block.chainid, address(this), requester, requesterNonce[requester]++))
    ///         The requester is read from the PGTR forwarder via _effectiveSender() / pgtrSender().
    ///         The USDC reward MUST be transferred to this contract by the forwarder before this call.
    /// @param reward        USDC reward amount (6 decimals); for Auction = max price
    /// @param duration      Task lifetime in seconds
    /// @param mode            4-byte mode selector (see ITMPModes for canonical values)
    /// @param pitchDeadline   Seconds from now for pitch acceptance (Pitch mode only, 0 otherwise)
    /// @param bidDeadline     Seconds from now for bid submission (Auction mode only, 0 otherwise)
    /// @param contentHash     Optional keccak256 of off-chain task description (bytes32(0) if unused)
    /// @param contentURI      Optional URI pointing to extended task metadata (empty string if unused)
    /// @param auctionSubtype  Auction subtype selector (see ITMPModes; bytes4(0) for non-auction tasks)
    /// @param hookContract    ITMPHook address; address(0) for no hook (ERC-8195)
    /// @param tags            keccak256-hashed classification labels stored on-chain (ERC-8195)
    /// @param hookData        Arbitrary bytes forwarded verbatim to checkFund; use for per-task hook config
    /// @return taskId         Contract-generated canonical task identifier
    function createTask(
        uint256 reward,
        uint256 duration,
        bytes4 mode,
        uint256 pitchDeadline,
        uint256 bidDeadline,
        bytes32 contentHash,
        string calldata contentURI,
        bytes4 auctionSubtype,
        address hookContract,
        bytes32[] calldata tags,
        bytes calldata hookData
    ) external returns (bytes32 taskId);

    /// @notice Accept a worker's submission and release escrowed payment.
    ///         The requester is authenticated by the implementation's chosen mechanism.
    ///         Payment is atomic with status update (nonReentrant required).
    ///         For Bounty / Benchmark modes the deliverable must have been committed on-chain
    ///         by a prior submitWork call — the contract verifies the hash exists in
    ///         taskSubmissionHashes[taskId][worker]. Reverts SubmissionNotFound if not found.
    ///         For Claim / Pitch / Auction the deliverable was already written by submitWork;
    ///         the param is cross-checked against task.deliverable.
    /// @param taskId           Task identifier
    /// @param worker           Worker address to receive payment
    /// @param deliverable      Accepted deliverable hash; must have been committed by submitWork
    /// @param requesterAgentId ERC-8004 agentId of requester (0 if unknown); used for giveFeedback
    function acceptSubmission(bytes32 taskId, address worker, bytes32 deliverable, uint256 requesterAgentId) external;

    /// @notice Accept N submissions at once with explicit share basis points.
    ///         Valid for Bounty and Benchmark modes. Shares MUST sum to 10000; fee taken per pair.
    ///         workers[0] becomes task.worker; each worker's deliverable is resolved from the
    ///         latest entry in taskSubmissionHashes[taskId][worker]. Reverts SubmissionNotFound
    ///         if any winner has no prior submitWork call.
    ///         One TaskCompleted event MUST be emitted per (worker, share) pair.
    ///         Duplicate worker addresses are allowed; the requester is the authority on who gets paid.
    ///         MUST revert for modes with a single locked worker.
    /// @param taskId           Task identifier
    /// @param workers          Recipient addresses (length >= 1)
    /// @param shares           Basis-point shares; MUST sum to 10000
    /// @param deliverables     Per-winner hash overrides; empty = auto-resolve each worker's latest
    /// @param requesterAgentId ERC-8004 agentId of requester (0 if unknown); used for giveFeedback
    function acceptSubmissions(
        bytes32 taskId,
        address[] calldata workers,
        uint16[] calldata shares,
        bytes32[] calldata deliverables,
        uint256 requesterAgentId
    ) external;

    /// @notice Reject a worker's submission on a Bounty or Benchmark task.
    ///         Once all active submissions are rejected, cancelTask becomes available.
    /// @param taskId Task identifier
    /// @param worker Worker whose submission is being rejected
    function rejectSubmission(bytes32 taskId, address worker) external;

    /// @notice Record that a worker has submitted deliverable work.
    ///         The worker is authenticated by the implementation's chosen mechanism.
    ///         Anchors a content hash on-chain for tamper-evident audit trail.
    ///         State change is mode-dependent:
    ///           Bounty/Benchmark → emit-only (no deliverable write; multiple submissions allowed)
    ///           Claim/Pitch/Auction → write task.deliverable; no status change (worker already locked)
    /// @param taskId     Task identifier
    /// @param deliverable Content hash of the work artifact (keccak256, IPFS CID, or ZK commitment)
    function submitWork(bytes32 taskId, bytes32 deliverable) external;

    /// @notice Anchor a pitch hash on a Pitch-mode task before pitchDeadline.
    ///         pitchHash MUST be keccak256(abi.encode(taskId, worker, pitchText)).
    /// @param taskId    Task identifier
    /// @param pitchHash Domain-separated commitment over (taskId, worker, pitchText)
    function submitPitch(bytes32 taskId, bytes32 pitchHash) external;

    /// @notice Anchor a proof hash on a Benchmark-mode task.
    ///         proofHash MUST be keccak256(abi.encode(taskId, worker, proofData)).
    /// @param taskId      Task identifier
    /// @param proofHash   Domain-separated commitment over (taskId, worker, proofData)
    /// @param proofType   bytes32(keccak256(proofTypeString)) identifying the proof scheme
    /// @param metricValue Claimed numeric result of the benchmark
    function submitProof(bytes32 taskId, bytes32 proofHash, bytes32 proofType, uint256 metricValue) external;

    /// @notice Rate a completed task and record feedback via ERC-8004.
    ///         For Bounty / Benchmark a requester MAY rate each winner separately;
    ///         each (taskId, worker) pair can only be rated once.
    ///         For Claim / Pitch / Auction the worker MUST equal task.worker.
    /// @param taskId        Task identifier
    /// @param worker        Worker being rated
    /// @param rating        Score 0-100
    /// @param workerAgentId ERC-8004 agentId of worker (0 if unknown)
    /// @param raterAgentId  ERC-8004 agentId of the requester giving the rating (0 if unknown)
    /// @param feedbackURI   URI of off-chain feedback document
    /// @param feedbackHash  keccak256 of the feedback document
    function rateTask(
        bytes32 taskId,
        address worker,
        uint8 rating,
        uint256 workerAgentId,
        uint256 raterAgentId,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    /// @notice Refund escrowed reward to requester after expiry.
    ///         MUST bypass all hooks and extension contracts.
    ///         This is a normative security requirement — funds MUST always
    ///         be recoverable after expiry regardless of extension state.
    ///         For Bounty/Benchmark, emits RequesterReputation with event_ =
    ///         keccak256("expired_no_action") or keccak256("expired_after_rejections").
    /// @param taskId           Task identifier
    /// @param requesterAgentId ERC-8004 agentId of requester (0 if unknown); used for giveFeedback
    function refundExpired(bytes32 taskId, uint256 requesterAgentId) external;

    /// @notice Forfeit a claimed worker's stake and reopen the task for new claims.
    ///         Only callable by the requester. Task MUST be in Claimed status and
    ///         past expiry. Forfeited stake goes to the fee recipient; task returns
    ///         to Open status.
    /// @param taskId Task identifier
    function forfeitAndReopen(bytes32 taskId) external;

    /// @notice Get task details.
    /// @param taskId Task identifier
    /// @return Task info struct
    function getTask(bytes32 taskId) external view returns (Task memory);

    /// @notice Returns cumulative statistics for a worker address.
    /// @param worker Worker address
    function getWorkerStats(address worker) external view returns (WorkerStats memory);

    /// @notice Returns the current nonce used in task ID generation for a requester.
    ///         Callers MAY pre-compute the next task ID as:
    ///         keccak256(abi.encode(block.chainid, address(this), requester, requesterNonce(requester)))
    /// @param requester Requester address
    function requesterNonce(address requester) external view returns (uint256);

    /// @notice Bühlmann credibility of a worker's reputation (0–1000).
    ///         credibility = floor(ratedTasks / (ratedTasks + 10) * 1000)
    ///         Returns 0 for workers with no rated tasks.
    function getCredibility(address worker) external view returns (uint256);

    /// @notice Average rating for a worker scaled to 0–1000.
    ///         averageRating = totalStars * 10 / ratedTasks
    ///         Returns 0 for workers with no rated tasks.
    function getAverageRating(address worker) external view returns (uint256);
}
