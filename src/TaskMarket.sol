// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {ITMPCore} from "./interfaces/ITMPCore.sol";
import {ITMPReputation} from "./interfaces/ITMPReputation.sol";
import {ITMPFees} from "./interfaces/ITMPFees.sol";
import {ITMPEvaluator} from "./interfaces/ITMPEvaluator.sol";
import {ITMPHook} from "./interfaces/ITMPHook.sol";
import {ITMPRegistry} from "./interfaces/ITMPRegistry.sol";
import {IPGTRForwarder} from "./interfaces/IPGTRForwarder.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {
    ITMPModes,
    TMP_BOUNTY,
    TMP_CLAIM,
    TMP_PITCH,
    TMP_BENCHMARK,
    TMP_AUCTION,
    TMP_AUCTION_DUTCH,
    TMP_AUCTION_ENGLISH,
    TMP_AUCTION_REVERSE_DUTCH,
    TMP_AUCTION_REVERSE_ENGLISH
} from "./interfaces/ITMPModes.sol";

/**
 * @title TaskMarket
 * @notice Multi-mode decentralized task marketplace with USDC escrow on Base L2.
 *         Reference implementation of the Task Market Protocol (TMP) EIP.
 *
 * @dev Supports Bounty, Claim, Pitch, Benchmark, and Auction modes with platform
 *      fees and staking. All mutating functions are called by a trusted PGTR forwarder
 *      (ERC-8194). The authenticated actor (requester/worker) is read from the forwarder
 *      via _effectiveSender(), which calls IPGTRForwarder(msg.sender).pgtrSender().
 *
 *      Task IDs are contract-generated:
 *        keccak256(abi.encode(block.chainid, address(this), requester, requesterNonce[requester]++))
 *      Backends can pre-compute the ID by reading requesterNonce[requester] before
 *      submitting the transaction.
 *
 *      UUPS upgradeable — proxy address is permanent; only the implementation changes.
 *      Storage layout rule: new state variables MUST be appended after existing ones
 *      and MUST consume slots from __gap. Never insert between existing variables.
 */
contract TaskMarket is ITMPCore, ITMPEvaluator, ITMPRegistry, ITMPReputation, ITMPFees, ITMPModes, Initializable, Ownable2StepUpgradeable, PausableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Mode constants (bytes4 selectors — extensible without ABI breaking changes)
    // -------------------------------------------------------------------------

    bytes4 public constant BOUNTY    = TMP_BOUNTY;
    bytes4 public constant CLAIM     = TMP_CLAIM;
    bytes4 public constant PITCH     = TMP_PITCH;
    bytes4 public constant BENCHMARK = TMP_BENCHMARK;
    bytes4 public constant AUCTION          = TMP_AUCTION;
    bytes4 public constant AUCTION_DUTCH           = TMP_AUCTION_DUTCH;
    bytes4 public constant AUCTION_ENGLISH         = TMP_AUCTION_ENGLISH;
    bytes4 public constant AUCTION_REVERSE_DUTCH   = TMP_AUCTION_REVERSE_DUTCH;
    bytes4 public constant AUCTION_REVERSE_ENGLISH = TMP_AUCTION_REVERSE_ENGLISH;

    uint256 public constant MAX_BIDS_PER_TASK = 500;

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    IERC20 public usdcToken;

    /// @notice Mapping of trusted PGTR forwarders.
    ///         Multiple forwarders are supported for rotation and redundancy.
    mapping(address => bool) public trustedForwarders;

    mapping(bytes32 => Task) public tasks;
    mapping(address => WorkerStats) public workerStats;
    mapping(bytes32 => uint256) public stakeForfeit;
    mapping(bytes32 => Bid[]) public taskBids;

    uint16 public defaultFeeBps;
    address public feeRecipient;
    uint256 public totalFeesCollected;
    address public reputationRegistry;

    /// @notice Per-requester nonce used to generate canonical task IDs.
    ///         Read this before calling createTask to pre-compute the task ID off-chain.
    mapping(address => uint256) public requesterNonce;

    /// @notice Anchored pitch hashes per task. Pitch content stays off-chain; the hash
    ///         here is a tamper-proof commitment so third parties can verify text
    ///         retrieved from any operator matches what was submitted on-chain.
    mapping(bytes32 => bytes32[]) public taskPitchHashes;

    /// @notice Anchored proof hashes per task. Same commitment pattern as pitches.
    mapping(bytes32 => bytes32[]) public taskProofHashes;

    /// @notice Whether a (task, worker) pair has been rated. Prevents inflating
    ///         workerStats by rating the same worker twice on the same task in
    ///         multi-winner Bounty / Benchmark flows.
    mapping(bytes32 => mapping(address => bool)) public taskWorkerRated;

    // ERC-8195: on-chain tags per task (keccak256-hashed at creation).
    mapping(bytes32 => bytes32[]) public taskTags;

    // ERC-8195: verdicts stored after evaluate() is called.
    mapping(bytes32 => Verdict) public taskVerdicts;

    // ERC-8195: per-task phase deadline. Serves dual purpose depending on task state:
    //   Review state:    evaluation deadline (set by submitWork, read by evaluatorTimeout)
    //   Appealing state: appeal deadline     (overwritten by evaluate, read by appeal/finalizeVerdict)
    mapping(bytes32 => uint256) public phaseDeadline;

    // ERC-8195 split-struct extension mappings. Separating infrequently-accessed and
    // mode-specific fields from the core Task struct keeps the getTask() ABI encoder
    // within Yul stack limits under the coverage compiler (which strips via_ir).
    mapping(bytes32 => TaskEvaluatorConfig) public taskEvaluatorConfigs;
    mapping(bytes32 => TaskAuctionConfig)   public taskAuctionConfigs;
    mapping(bytes32 => TaskMetadata)        public taskMetadata;
    mapping(bytes32 => TaskPitchConfig)     public taskPitchConfigs;

    // Reserve 38 slots (started at 50; reduced by 12 for state variables added post-deploy).
    uint256[38] private __gap;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    // All events are inherited from ITMPCore, ITMPFees, and ITMPReputation.

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyTrustedForwarder() {
        if (!trustedForwarders[msg.sender]) revert NotTrustedForwarder();
        _;
    }

    // -------------------------------------------------------------------------
    // ERC-8194: PGTR destination requirement
    // -------------------------------------------------------------------------

    /// @notice Returns true if addr is a trusted PGTR forwarder (ERC-8194 requirement).
    function isTrustedForwarder(address addr) external view returns (bool) {
        return trustedForwarders[addr];
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /**
     * @notice Initialize the proxy (replaces constructor for UUPS pattern)
     * @param _usdcToken USDC token address on Base
     * @param _feeRecipient Address to receive platform fees
     * @param _defaultFeeBps Default platform fee in basis points (500 = 5%)
     */
    function initialize(
        address _usdcToken,
        address _feeRecipient,
        uint16 _defaultFeeBps
    ) public initializer {
        __Ownable_init(msg.sender);
        __Pausable_init();
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_defaultFeeBps > 10000) revert FeeBpsTooHigh();
        usdcToken = IERC20(_usdcToken);
        feeRecipient = _feeRecipient;
        defaultFeeBps = _defaultFeeBps;
    }

    /**
     * @notice Authorize upgrade — only owner may upgrade the implementation
     * @dev Required by UUPSUpgradeable
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // -------------------------------------------------------------------------
    // ERC-165
    // -------------------------------------------------------------------------

    /**
     * @notice ERC-165 interface detection.
     * @dev Returns true for ITMPCore and IERC165 interface IDs.
     * @param interfaceId 4-byte interface selector to check
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITMPCore).interfaceId
            || interfaceId == type(ITMPEvaluator).interfaceId
            || interfaceId == type(ITMPRegistry).interfaceId
            || interfaceId == type(ITMPReputation).interfaceId
            || interfaceId == type(ITMPFees).interfaceId
            || interfaceId == type(ITMPModes).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // -------------------------------------------------------------------------
    // Owner admin functions
    // -------------------------------------------------------------------------

    /**
     * @notice Halt all state-mutating operations (owner only).
     *         Stops all attack vectors during an emergency. Unpause after deploying a fix.
     */
    function pause() external onlyOwner { _pause(); }

    /**
     * @notice Restore normal operation after a pause (owner only).
     */
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Add a trusted PGTR forwarder (owner only)
     * @param forwarder Address to trust as a forwarder
     */
    function addForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert InvalidForwarderAddress();
        trustedForwarders[forwarder] = true;
        emit ForwarderUpdated(forwarder, true);
    }

    /**
     * @notice Remove a trusted PGTR forwarder (owner only)
     * @param forwarder Address to remove from trusted forwarders
     */
    function removeForwarder(address forwarder) external onlyOwner {
        trustedForwarders[forwarder] = false;
        emit ForwarderUpdated(forwarder, false);
    }

    /**
     * @notice Set the ERC-8004 reputation registry address (owner only)
     * @param registry New reputation registry address
     */
    function setReputationRegistry(address registry) external onlyOwner {
        reputationRegistry = registry;
        emit ReputationRegistryUpdated(registry);
    }

    /**
     * @notice Set default platform fee (owner only)
     * @param feeBps New fee in basis points
     */
    function setDefaultFeeBps(uint16 feeBps) external onlyOwner {
        if (feeBps > 10000) revert FeeBpsTooHigh();
        defaultFeeBps = feeBps;
        emit FeesUpdated(feeBps);
    }

    /**
     * @notice Set fee recipient (owner only)
     * @param recipient New fee recipient address
     */
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Builds a TaskContext snapshot for hook callbacks.
     */
    function _buildContext(bytes32 taskId) internal view returns (TaskContext memory) {
        Task storage t = tasks[taskId];
        TaskEvaluatorConfig storage ec = taskEvaluatorConfigs[taskId];
        return TaskContext({
            taskId: taskId,
            requester: t.requester,
            evaluator: ec.evaluator,
            paymentToken: address(usdcToken),
            reward: t.reward,
            evaluatorStake: ec.evaluatorStake,
            evaluatorFeeBps: ec.evaluatorFeeBps,
            submissionDeadline: t.expiryTime,
            evaluationWindow: ec.evaluationWindow,
            appealWindow: ec.appealWindow,
            disputeResolver: ec.disputeResolver,
            currentState: t.status,
            mode: t.mode,
            tags: taskTags[taskId]
        });
    }

    /**
     * @dev Calls an after-hook best-effort (swallows failures).
     *      Does nothing when hook == address(0).
     */
    function _afterHook(address hook, bytes memory data) internal {
        if (hook == address(0)) return;
        // on* hooks are fire-and-forget; failures are swallowed so a buggy hook cannot block
        // fund recovery. Emit HookCallFailed so failures are observable on-chain.
        // solhint-disable-next-line avoid-low-level-calls
        // slither-disable-next-line unchecked-lowlevel
        (bool ok,) = hook.call(data);
        if (!ok) emit HookCallFailed(hook);
    }

    /**
     * @dev Returns the authenticated actor for this call.
     *      If called by a trusted PGTR forwarder, returns forwarder.pgtrSender().
     *      Otherwise returns msg.sender.
     *
     *      NOTE: All mutating functions carry onlyTrustedForwarder, so the msg.sender
     *      branch is unreachable in the current implementation. It is retained as a
     *      defensive fallback for: (a) view-context callers that do not carry the
     *      modifier, and (b) any future non-forwarded extensions that may be added
     *      without onlyTrustedForwarder.
     */
    function _effectiveSender() internal view returns (address) {
        if (trustedForwarders[msg.sender]) {
            return IPGTRForwarder(msg.sender).pgtrSender();
        }
        return msg.sender;
    }

    // -------------------------------------------------------------------------
    // Core task functions
    // -------------------------------------------------------------------------

    /**
     * @notice Create a new task with USDC escrow.
     *         Task ID is contract-generated:
     *           keccak256(abi.encode(block.chainid, address(this), requester, nonce))
     *         Callers SHOULD pre-compute the ID by reading requesterNonce[requester]
     *         before submitting this transaction.
     *         The requester is the authenticated actor from the PGTR forwarder (pgtrSender).
     *         The USDC reward MUST be transferred to this contract by the forwarder before calling.
     * @param reward          USDC reward (6 decimals); for Auction = max price
     * @param duration        Task lifetime in seconds
     * @param mode            4-byte mode selector (use BOUNTY/CLAIM/PITCH/BENCHMARK/AUCTION)
     * @param pitchDeadline   Seconds from now for pitch window (Pitch mode only, 0 otherwise)
     * @param bidDeadline     Seconds from now for bid window (Auction mode only, 0 otherwise)
     * @param contentHash     Optional keccak256 of off-chain task description (bytes32(0) if unused)
     * @param contentURI      Optional URI pointing to extended task metadata (empty string if unused)
     * @param auctionSubtype  Auction subtype selector (bytes4(0) for non-auction tasks)
     * @param hookContract    ITMPHook address; address(0) for no hook (ERC-8195)
     * @param tags            keccak256-hashed classification labels stored on-chain (ERC-8195)
     * @param hookData        Arbitrary bytes forwarded verbatim to checkFund; use for per-task hook config
     * @return taskId         Contract-generated canonical task identifier
     */
    function createTask(
        uint256 reward,
        uint256 duration,
        bytes4  mode,
        uint256 pitchDeadline,
        uint256 bidDeadline,
        bytes32 contentHash,
        string  calldata contentURI,
        bytes4  auctionSubtype,
        address hookContract,
        bytes32[] calldata tags,
        bytes   calldata hookData
    ) external onlyTrustedForwarder whenNotPaused nonReentrant returns (bytes32 taskId) {
        address requester = _effectiveSender();
        if (requester == address(0)) revert InvalidRequester();
        if (reward == 0) revert RewardMustBeGreaterThanZero();
        if (duration == 0) revert DurationMustBeGreaterThanZero();
        if (!(mode == BOUNTY || mode == CLAIM || mode == PITCH || mode == BENCHMARK || mode == AUCTION)) revert InvalidMode();
        if (mode == AUCTION) {
            if (!(auctionSubtype == AUCTION_DUTCH
                    || auctionSubtype == AUCTION_ENGLISH
                    || auctionSubtype == AUCTION_REVERSE_DUTCH
                    || auctionSubtype == AUCTION_REVERSE_ENGLISH)) revert InvalidAuctionSubtype();
        }

        taskId = keccak256(abi.encode(block.chainid, address(this), requester, requesterNonce[requester]++));

        // USDC was transferred to this contract by the forwarder before this call.

        Task storage t = tasks[taskId];
        t.id         = taskId;
        t.requester  = requester;
        t.reward     = reward;
        t.expiryTime = block.timestamp + duration;
        t.status     = TaskStatus.Open;
        t.mode       = mode;
        t.feeBps     = defaultFeeBps;
        t.hookContract = hookContract;

        TaskMetadata storage meta = taskMetadata[taskId];
        meta.createdAt   = block.timestamp;
        meta.contentHash = contentHash;
        meta.contentURI  = contentURI;

        if (mode == PITCH) taskPitchConfigs[taskId].pitchDeadline = block.timestamp + pitchDeadline;
        if (mode == AUCTION) {
            TaskAuctionConfig storage ac = taskAuctionConfigs[taskId];
            ac.bidDeadline    = block.timestamp + bidDeadline;
            ac.maxPrice       = reward;
            ac.auctionSubtype = auctionSubtype;
        }

        if (tags.length > 0) {
            taskTags[taskId] = tags;
        }

        if (hookContract != address(0)) {
            _checkFundHook(taskId, hookContract, hookData);
        }

        emit TaskCreated(taskId, requester, reward, mode, block.timestamp + duration);
    }

    function _checkFundHook(bytes32 taskId, address hookContract, bytes calldata hookData) internal {
        if (!ITMPHook(hookContract).checkFund(taskId, _buildContext(taskId), hookData)) revert HookCheckFundRejected();
        emit HookRegistered(taskId, hookContract);
    }

    /**
     * @notice Claim a Claim-mode task. The worker is the authenticated actor (pgtrSender).
     * @param taskId      Task identifier
     * @param stakeAmount USDC stake amount (0 = no stake required).
     *                    If > 0, the forwarder must transfer the stake to this contract before calling.
     */
    function claimTask(bytes32 taskId, uint256 stakeAmount) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (worker == address(0)) revert InvalidWorker();
        if (task.mode != CLAIM) revert NotAClaimTask();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert TaskIsExpired();

        // If stakeAmount > 0, the stake was transferred to this contract by the forwarder.

        task.worker = worker;
        task.stakeAmount = stakeAmount;
        task.status = TaskStatus.Claimed;
        taskMetadata[taskId].claimedAt = block.timestamp;

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkClaim(taskId, _buildContext(taskId), worker)) revert HookCheckClaimRejected();
        }

        emit TaskClaimed(taskId, worker, stakeAmount);
    }

    /**
     * @notice Select a worker for Pitch mode. The requester is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @param worker Selected worker address
     */
    function selectWorker(bytes32 taskId, address worker) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        if (requester != task.requester) revert NotRequester();
        if (task.mode != PITCH) revert NotAPitchTask();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp > taskPitchConfigs[taskId].pitchDeadline) revert PitchDeadlinePassed();

        task.worker = worker;
        task.status = TaskStatus.WorkerSelected;

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkSelectWorker(taskId, _buildContext(taskId), worker)) revert HookCheckSelectWorkerRejected();
        }

        emit TaskWorkerSelected(taskId, worker);
    }

    /**
     * @notice Submit a bid on an Auction mode task. The worker is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @param price  Bid price in USDC base units (must be <= maxPrice)
     */
    function submitBid(bytes32 taskId, uint256 price) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        TaskAuctionConfig storage auctionCfg = taskAuctionConfigs[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (task.mode != AUCTION) revert NotAnAuctionTask();
        if (!(auctionCfg.auctionSubtype == AUCTION_ENGLISH || auctionCfg.auctionSubtype == AUCTION_REVERSE_ENGLISH)) revert NotABidAuction();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp >= auctionCfg.bidDeadline) revert BidDeadlinePassed();
        if (price > auctionCfg.maxPrice) revert BidExceedsMaxPrice();
        if (taskBids[taskId].length >= MAX_BIDS_PER_TASK) revert BidLimitReached();

        // Maintain running minimum for O(1) winner selection in selectLowestBidder
        if (taskBids[taskId].length == 0 || price < auctionCfg.lowestBidPrice) {
            auctionCfg.lowestBidPrice = price;
            auctionCfg.lowestBidder = worker;
        }

        taskBids[taskId].push(Bid({ worker: worker, price: price }));

        emit BidSubmitted(taskId, worker, price);
    }

    /**
     * @notice Select the lowest bidder after bid deadline.
     * @param taskId Task identifier
     * @dev O(1): submitBid() maintains a running minimum in task.lowestBidder/lowestBidPrice.
     */
    function selectLowestBidder(bytes32 taskId) external onlyTrustedForwarder whenNotPaused nonReentrant {
        Task storage task = tasks[taskId];
        TaskAuctionConfig storage auctionCfg = taskAuctionConfigs[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (task.mode != AUCTION) revert NotAnAuctionTask();
        if (!(auctionCfg.auctionSubtype == AUCTION_ENGLISH || auctionCfg.auctionSubtype == AUCTION_REVERSE_ENGLISH)) revert NotABidAuction();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp < auctionCfg.bidDeadline) revert BidDeadlineNotPassed();
        if (auctionCfg.lowestBidder == address(0)) revert NoBidsSubmitted();

        task.worker = auctionCfg.lowestBidder;
        task.stakeAmount = auctionCfg.lowestBidPrice;
        task.status = TaskStatus.Claimed;

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkSelectWorker(taskId, _buildContext(taskId), auctionCfg.lowestBidder)) revert HookCheckSelectWorkerRejected();
        }

        emit TaskWorkerSelected(taskId, auctionCfg.lowestBidder);
    }

    /**
     * @notice Directly award an open auction task to a worker at a given price.
     *         Used by clock-based auction subtypes (dutch, reverse_dutch).
     *         The worker is the authenticated actor (pgtrSender).
     * @dev Does not enforce MAX_BIDS_PER_TASK; clock subtypes have at most one winner.
     * @param taskId Task identifier
     * @param price  Accepted price in USDC base units (must be <= task.maxPrice)
     */
    function acceptAuction(bytes32 taskId, uint256 price) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        TaskAuctionConfig storage auctionCfg = taskAuctionConfigs[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (task.mode != AUCTION) revert NotAnAuctionTask();
        if (!(auctionCfg.auctionSubtype == AUCTION_DUTCH || auctionCfg.auctionSubtype == AUCTION_REVERSE_DUTCH)) revert NotAClockPriceAuction();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (price > auctionCfg.maxPrice) revert PriceExceedsMaxPrice();
        task.worker = worker;
        task.stakeAmount = price;
        task.status = TaskStatus.Claimed;

        address auctionHook = task.hookContract;
        if (auctionHook != address(0)) {
            if (!ITMPHook(auctionHook).checkSelectWorker(taskId, _buildContext(taskId), worker)) revert HookCheckSelectWorkerRejected();
        }

        emit AuctionAccepted(taskId, worker, price);
    }

    /**
     * @notice Anchor a pitch-content hash on-chain for a pitch-mode task.
     *         The pitch text itself stays off-chain; the hash is a tamper-proof
     *         commitment that third parties can use to verify any operator-served
     *         pitch text matches what the worker actually submitted.
     *         The worker is the authenticated actor (pgtrSender).
     * @param taskId    Task identifier
     * @param pitchHash Content hash (typically keccak256(abi.encode(taskId, worker, pitchText)))
     */
    function submitPitch(bytes32 taskId, bytes32 pitchHash) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (task.mode != PITCH) revert NotAPitchTask();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp > taskPitchConfigs[taskId].pitchDeadline) revert PitchDeadlinePassed();
        if (block.timestamp > task.expiryTime) revert TaskIsExpired();
        if (pitchHash == bytes32(0)) revert EmptyPitchHash();

        taskPitchHashes[taskId].push(pitchHash);
        emit PitchSubmitted(taskId, worker, pitchHash);
    }

    /**
     * @notice Anchor a benchmark-proof hash on-chain for a benchmark-mode task.
     *         The proof data stays off-chain; the hash here is a tamper-proof
     *         commitment. proofType is a free-form bytes32 selector (typically
     *         keccak256(typeString)); metricValue is a task-specific numeric score.
     *         The worker is the authenticated actor (pgtrSender).
     * @param taskId      Task identifier
     * @param proofHash   Content hash (typically keccak256(abi.encode(taskId, worker, proofData)))
     * @param proofType   bytes32 selector identifying the proof scheme
     * @param metricValue Task-specific numeric score
     */
    function submitProof(
        bytes32 taskId,
        bytes32 proofHash,
        bytes32 proofType,
        uint256 metricValue
    ) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (task.mode != BENCHMARK) revert NotABenchmarkTask();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp > task.expiryTime) revert TaskIsExpired();
        if (proofHash == bytes32(0)) revert EmptyProofHash();

        taskProofHashes[taskId].push(proofHash);
        emit ProofSubmitted(taskId, worker, proofHash, proofType, metricValue);
    }

    /**
     * @notice Record that a worker has submitted deliverable work.
     *         The worker is the authenticated actor (pgtrSender).
     *         Anchors a content hash on-chain for tamper-evident audit trail.
     *         State change is mode-dependent:
     *           BOUNTY/BENCHMARK → Open → PendingApproval on first submission; stays PendingApproval thereafter
     *           CLAIM/PITCH/AUCTION → no state change (worker already locked)
     * @param taskId      Task identifier
     * @param deliverable Content hash (keccak256, IPFS CID, or ZK commitment)
     */
    // Complexity is inherent: five task modes each require distinct state-transition branches.
    // solhint-disable-next-line code-complexity
    function submitWork(bytes32 taskId, bytes32 deliverable) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (block.timestamp > task.expiryTime) revert TaskIsExpired();

        if (task.mode == BOUNTY || task.mode == BENCHMARK) {
            if (task.status != TaskStatus.Open && task.status != TaskStatus.PendingApproval) revert TaskNotOpen();
            // Transition Open → PendingApproval on first submission; subsequent
            // submissions stay in PendingApproval. task.deliverable is not written
            // here — the requester names the winner at acceptSubmission time.
            if (task.status == TaskStatus.Open) {
                task.status = TaskStatus.PendingApproval;
            }
        } else if (task.mode == CLAIM) {
            if (task.status != TaskStatus.Claimed) revert TaskNotClaimed();
            if (worker != task.worker) revert WorkerMismatch();
            if (task.deliverable != bytes32(0)) revert DeliverableAlreadySet();
            task.deliverable = deliverable;
        } else if (task.mode == PITCH || task.mode == AUCTION) {
            if (task.status != TaskStatus.WorkerSelected && task.status != TaskStatus.Claimed) revert WorkerNotSelected();
            if (worker != task.worker) revert WorkerMismatch();
            if (task.deliverable != bytes32(0)) revert DeliverableAlreadySet();
            task.deliverable = deliverable;
        }

        // When evaluator is assigned and the worker is now locked, transition to Review.
        // Extend expiryTime to cover the evaluation window so refundExpired cannot fire
        // while the worker's submission is under active assessment (Fund Recovery Invariant).
        TaskEvaluatorConfig storage evalCfg = taskEvaluatorConfigs[taskId];
        if (evalCfg.evaluator != address(0) && (task.mode == CLAIM || task.mode == PITCH || task.mode == AUCTION)) {
            task.status = TaskStatus.Review;
            uint256 reviewDeadline = block.timestamp + evalCfg.evaluationWindow;
            phaseDeadline[taskId] = reviewDeadline;
            if (reviewDeadline > task.expiryTime) {
                task.expiryTime = reviewDeadline;
            }
        }

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkSubmit(taskId, _buildContext(taskId), worker, deliverable)) revert HookCheckSubmitRejected();
        }

        emit TaskSubmitted(taskId, worker, deliverable);
    }

    // Complexity is inherent: validates four distinct task modes plus evaluator/deliverable variants.
    // solhint-disable-next-line code-complexity
    function _validateAcceptSubmission(Task storage task, bytes32 taskId, address worker, bytes32 deliverable) internal {
        address evaluator = taskEvaluatorConfigs[taskId].evaluator;
        if (task.mode == CLAIM) {
            if (evaluator != address(0)) revert UseEvaluate();
            if (task.status != TaskStatus.Claimed && task.status != TaskStatus.PendingApproval) revert TaskNotClaimed();
            if (worker != task.worker) revert WorkerMismatch();
            if (deliverable != task.deliverable) revert DeliverableMismatch();
        } else if (task.mode == PITCH) {
            if (evaluator != address(0)) revert UseEvaluate();
            if (task.status != TaskStatus.WorkerSelected && task.status != TaskStatus.PendingApproval) revert WorkerNotSelected();
            if (worker != task.worker) revert WorkerMismatch();
            if (deliverable != task.deliverable) revert DeliverableMismatch();
        } else if (task.mode == AUCTION) {
            if (evaluator != address(0)) revert UseEvaluate();
            if (task.status != TaskStatus.Claimed && task.status != TaskStatus.PendingApproval) revert WinnerNotSelected();
            if (worker != task.worker) revert WorkerMismatch();
            if (deliverable != task.deliverable) revert DeliverableMismatch();
        } else {
            // BOUNTY or BENCHMARK: deferred-write model. The requester names the
            // winner and their deliverable here. submitWork didn't write either.
            if (evaluator != address(0)) revert UseEvaluate();
            if (task.status != TaskStatus.Open && task.status != TaskStatus.PendingApproval) revert TaskNotOpen();
            if (worker == address(0)) revert WorkerRequired();
            if (deliverable == bytes32(0)) revert DeliverableRequired();
            task.deliverable = deliverable;
        }
    }

    /**
     * @notice Accept submission and release payment to worker.
     *         The requester is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @param worker Worker address to pay
     */
    function acceptSubmission(bytes32 taskId, address worker, bytes32 deliverable)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
    {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        if (requester != task.requester) revert NotRequester();
        if (block.timestamp > task.expiryTime) revert TaskIsExpired();

        _validateAcceptSubmission(task, taskId, worker, deliverable);

        // Build a simple approval verdict for hook callbacks.
        Award[] memory awards = new Award[](1);
        awards[0] = Award({ worker: worker, amount: task.reward, rank: 1 });
        Verdict memory verdict = Verdict({
            issued: true,
            verdictType: VerdictType.APPROVE,
            score: 1000,
            confidence: 1000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });

        uint256 paymentAmount = task.mode == AUCTION ? task.stakeAmount : task.reward;
        uint256 fee = (paymentAmount * task.feeBps) / 10000;
        uint256 workerPayment = paymentAmount - fee;

        task.status = TaskStatus.Accepted;
        task.worker = worker;
        workerStats[worker].completedTasks++;
        if (fee > 0) {
            totalFeesCollected += fee;
        }

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkComplete(taskId, _buildContext(taskId), verdict)) revert HookCheckCompleteRejected();
        }

        if (!usdcToken.transfer(worker, workerPayment)) revert WorkerPaymentFailed();
        if (fee > 0) {
            if (!usdcToken.transfer(feeRecipient, fee)) revert FeeTransferFailed();
        }

        if (task.mode == CLAIM && task.stakeAmount > 0) {
            if (!usdcToken.transfer(task.worker, task.stakeAmount)) revert StakeReturnFailed();
            emit StakeReturned(taskId, task.worker, task.stakeAmount);
        }

        if (task.mode == AUCTION) {
            uint256 refund = taskAuctionConfigs[taskId].maxPrice - task.stakeAmount;
            if (refund > 0) {
                if (!usdcToken.transfer(task.requester, refund)) revert AuctionRefundFailed();
            }
        }

        emit TaskCompleted(taskId, requester, worker, workerPayment, fee);

        if (hook != address(0)) {
            _afterHook(hook, abi.encodeCall(ITMPHook.onComplete, (taskId, _buildContext(taskId), verdict)));
        }
    }

    /**
     * @notice Accept N submissions at once with explicit share basis points.
     *         Valid for modes that support multiple concurrent submissions
     *         (Bounty, Benchmark). Shares MUST sum to 10000; fee taken per pair.
     *         workers[0] becomes task.worker and deliverables[0] becomes
     *         task.deliverable for single-worker-field back-compat.
     *         Duplicate worker addresses ARE allowed (the requester may
     *         intentionally pay the same worker via multiple slots).
     * @param taskId       Task identifier
     * @param workers      Recipient addresses in rank order
     * @param shares       Basis-point shares; MUST sum to 10000
     * @param deliverables Per-worker content hash; each MUST be non-zero
     */
    function acceptSubmissions(
        bytes32 taskId,
        address[] calldata workers,
        uint16[] calldata shares,
        bytes32[] calldata deliverables
    ) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address requester = _effectiveSender();
        _acceptSubmissions(taskId, requester, workers, shares, deliverables);
    }

    // Complexity is inherent: distributes proportional payouts across N winners with per-winner fee, hook, and event branches.
    // solhint-disable-next-line code-complexity
    function _acceptSubmissions(
        bytes32 taskId,
        address requester,
        address[] calldata workers,
        uint16[] calldata shares,
        bytes32[] calldata deliverables
    ) internal {
        Task storage task = tasks[taskId];
        if (requester != task.requester) revert NotRequester();
        if (block.timestamp > task.expiryTime) revert TaskIsExpired();
        if (task.mode != BOUNTY && task.mode != BENCHMARK) revert MultiSubmissionOnlyForBountyBenchmark();
        if (taskEvaluatorConfigs[taskId].evaluator != address(0)) revert UseEvaluate();
        if (task.status != TaskStatus.Open && task.status != TaskStatus.PendingApproval) revert TaskNotOpen();

        uint256 n = workers.length;
        if (n < 1) revert NoWinners();
        if (shares.length != n || deliverables.length != n) revert LengthMismatch();

        uint256 sumShares = 0;
        for (uint256 i; i < n; ++i) {
            if (deliverables[i] == bytes32(0)) revert DeliverableRequired();
            sumShares += shares[i];
        }
        if (sumShares != 10000) revert SharesMustSumTo10000();

        // Build verdict for hook callbacks.
        Award[] memory awards = new Award[](n);
        for (uint256 i; i < n; ++i) {
            awards[i] = Award({ worker: workers[i], amount: (task.reward * shares[i]) / 10000, rank: uint16(i + 1) });
        }
        Verdict memory verdict = Verdict({
            issued: true,
            verdictType: VerdictType.APPROVE,
            score: 1000,
            confidence: 1000,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: awards
        });

        task.status = TaskStatus.Accepted;
        task.worker = workers[0];
        task.deliverable = deliverables[0];

        uint256 reward = task.reward;
        uint16 feeBps = task.feeBps;

        // Pre-compute all per-worker amounts and commit all state before any transfer.
        uint256[] memory nets = new uint256[](n);
        uint256[] memory fees = new uint256[](n);
        uint256 totalFee = 0;
        for (uint256 i; i < n; ++i) {
            uint256 pay = (reward * shares[i]) / 10000;
            if (pay == 0) revert ZeroPayoutPerPair();
            // Compute fee from the original inputs to avoid divide-before-multiply
            // precision loss when deriving fee from the already-divided pay value.
            uint256 fee = (reward * uint256(shares[i]) * uint256(feeBps)) / 100_000_000;
            nets[i] = pay - fee;
            fees[i] = fee;
            totalFee += fee;
            workerStats[workers[i]].completedTasks++;
        }
        if (totalFee > 0) {
            totalFeesCollected += totalFee;
        }

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkComplete(taskId, _buildContext(taskId), verdict)) revert HookCheckCompleteRejected();
        }

        // Multi-winner payouts require iterating recipients; a single batched transfer
        // is not possible with USDC. State is fully committed before this loop (CEI).
        // slither-disable-next-line calls-loop
        for (uint256 i; i < n; ++i) {
            if (!usdcToken.transfer(workers[i], nets[i])) revert WorkerPaymentFailed();
            emit TaskCompleted(taskId, requester, workers[i], nets[i], fees[i]);
        }
        if (totalFee > 0) {
            if (!usdcToken.transfer(feeRecipient, totalFee)) revert FeeTransferFailed();
        }

        if (hook != address(0)) {
            _afterHook(hook, abi.encodeCall(ITMPHook.onComplete, (taskId, _buildContext(taskId), verdict)));
        }
    }

    /**
     * @notice Forfeit worker's stake and reopen Claim task.
     *         The requester is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @dev Can only be called after the task has expired. Claimer's stake is
     *      transferred to fee recipient as a non-delivery penalty.
     */
    function forfeitAndReopen(bytes32 taskId) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        if (requester != task.requester) revert NotRequester();
        if (task.mode != CLAIM) revert NotAClaimTask();
        if (task.status != TaskStatus.Claimed) revert TaskNotClaimed();
        if (block.timestamp <= task.expiryTime) revert TaskNotYetExpired();

        uint256 forfeited = task.stakeAmount;
        address forfeiter = task.worker;
        stakeForfeit[taskId] = forfeited;

        task.status = TaskStatus.Open;
        task.worker = address(0);
        task.stakeAmount = 0;
        taskMetadata[taskId].claimedAt = 0;
        if (forfeited > 0) {
            totalFeesCollected += forfeited;
        }

        if (forfeited > 0) {
            if (!usdcToken.transfer(feeRecipient, forfeited)) revert ForfeitTransferFailed();
            emit StakeForfeited(taskId, forfeiter, forfeited);
        }

        emit TaskReopened(taskId);

        address hook = task.hookContract;
        if (hook != address(0)) {
            _afterHook(hook, abi.encodeCall(ITMPHook.onForfeit, (taskId, _buildContext(taskId), forfeiter)));
        }
    }

    /**
     * @notice Rate a completed task and submit ERC-8004 feedback.
     *         The requester is the authenticated actor (pgtrSender).
     * @param taskId        Task identifier
     * @param rating        Rating (0-100)
     * @param workerAgentId ERC-8004 agentId of worker, or 0 if unknown
     * @param raterAgentId  ERC-8004 agentId of the requester giving the rating, or 0 if unknown
     * @param feedbackURI   URI of the canonical off-chain feedback file
     * @param feedbackHash  keccak256 hash of the feedback file content
     */
    function rateTask(
        bytes32 taskId,
        address worker,
        uint8 rating,
        uint256 workerAgentId,
        uint256 raterAgentId,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external onlyTrustedForwarder whenNotPaused {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        if (requester != task.requester) revert NotRequester();
        if (task.status != TaskStatus.Accepted) revert TaskNotAccepted();
        if (rating > 100) revert RatingMustBe0To100();

        if (task.mode == BOUNTY || task.mode == BENCHMARK) {
            // Multi-winner: trust the rater's worker choice. No on-chain check
            // that worker was actually paid; same trust model as accepting.
            if (worker == address(0)) revert WorkerRequired();
        } else {
            // Locked-worker modes: worker must be the on-chain task.worker.
            if (worker != task.worker) revert WorkerMismatch();
        }

        if (taskWorkerRated[taskId][worker]) revert WorkerAlreadyRated();
        taskWorkerRated[taskId][worker] = true;

        // Record the first rating in task.rating for single-worker back-compat.
        if (task.rating == 0) {
            task.rating = rating;
        }

        workerStats[worker].ratedTasks++;
        workerStats[worker].totalStars += rating;

        emit TaskRated(taskId, worker, rating, raterAgentId);

        if (workerAgentId != 0 && reputationRegistry != address(0)) {
            try IReputationRegistry(reputationRegistry).giveFeedback(
                workerAgentId,
                int128(int256(uint256(rating))),
                0,
                "tmp.task.rating",
                _modeName(task.mode),
                "",
                feedbackURI,
                feedbackHash
            ) {} catch {}
        }
    }

    /**
     * @notice Refund expired task reward to requester.
     *         NORMATIVE: This function MUST bypass all hooks and extension contracts.
     *         Funds are recoverable after expiry while the contract is unpaused.
     *         Special case: Auction tasks with a selected winner auto-pay the worker.
     * @param taskId Task identifier
     */
    // Complexity is inherent: fund recovery must handle every possible task status and mode without hooks.
    // solhint-disable-next-line code-complexity
    function refundExpired(bytes32 taskId) external whenNotPaused nonReentrant {
        Task storage task = tasks[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (block.timestamp <= task.expiryTime) revert TaskNotYetExpired();
        if (task.status == TaskStatus.Accepted) revert TaskAlreadyAccepted();
        if (task.status == TaskStatus.Cancelled) revert TaskIsCancelled();

        if (task.mode == AUCTION && task.status == TaskStatus.Claimed) {
            uint256 fee = (task.stakeAmount * task.feeBps) / 10000;
            uint256 workerPayment = task.stakeAmount - fee;
            task.status = TaskStatus.Accepted;
            workerStats[task.worker].completedTasks++;
            if (fee > 0) {
                totalFeesCollected += fee;
            }
            if (workerPayment > 0) {
                if (!usdcToken.transfer(task.worker, workerPayment)) revert WorkerPaymentFailed();
            }
            if (fee > 0) {
                if (!usdcToken.transfer(feeRecipient, fee)) revert FeeTransferFailed();
            }
            uint256 refund = task.reward - task.stakeAmount;
            if (refund > 0) {
                if (!usdcToken.transfer(task.requester, refund)) revert RequesterRefundFailed();
            }
            emit TaskCompleted(taskId, task.requester, task.worker, workerPayment, fee);
            address auctionHook = task.hookContract;
            if (auctionHook != address(0)) {
                Award[] memory awards = new Award[](1);
                awards[0] = Award({ worker: task.worker, amount: task.stakeAmount, rank: 1 });
                Verdict memory verdict = Verdict({
                    issued: true,
                    verdictType: VerdictType.APPROVE,
                    score: 1000,
                    confidence: 1000,
                    criteriaFlags: new bytes32[](0),
                    evidenceHash: bytes32(0),
                    awards: awards
                });
                _afterHook(auctionHook, abi.encodeCall(ITMPHook.onComplete, (taskId, _buildContext(taskId), verdict)));
            }
            return;
        }

        task.status = TaskStatus.Expired;
        uint256 refundAmount = task.reward;

        // If the task expired while an evaluator was assigned (Review state), forfeit their stake.
        // The evaluator window was extended by submitWork — reaching here means both the task
        // expiry and the evaluation window have elapsed without an evaluate() call.
        TaskEvaluatorConfig storage evalCfg = taskEvaluatorConfigs[taskId];
        address timedOutEvaluator = evalCfg.evaluator;
        uint256 evaluatorForfeited = evalCfg.evaluatorStake;
        if (evaluatorForfeited > 0) {
            evalCfg.evaluatorStake = 0;
            evalCfg.evaluator = address(0);
            totalFeesCollected += evaluatorForfeited;
        }

        if (!usdcToken.transfer(task.requester, refundAmount)) revert RefundFailed();

        if (task.mode == CLAIM && task.stakeAmount > 0) {
            if (!usdcToken.transfer(task.worker, task.stakeAmount)) revert StakeReturnFailed();
            emit StakeReturned(taskId, task.worker, task.stakeAmount);
        }

        if (evaluatorForfeited > 0) {
            if (!usdcToken.transfer(feeRecipient, evaluatorForfeited)) revert ForfeitTransferFailed();
            emit EvaluatorTimedOut(taskId, timedOutEvaluator, evaluatorForfeited);
        }

        emit TaskExpired(taskId, task.requester, refundAmount);

        address hook = task.hookContract;
        if (hook != address(0)) {
            // NORMATIVE: onExpire MUST NOT block fund recovery. Always try-catch.
            _afterHook(hook, abi.encodeCall(ITMPHook.onExpire, (taskId, _buildContext(taskId))));
        }
    }

    /**
     * @notice Cancel an open task and refund the escrowed reward to the requester.
     *         The requester is the authenticated actor (pgtrSender).
     *         Auction tasks may only be cancelled if no bids have been submitted.
     * @param taskId Task identifier
     */
    function cancelTask(bytes32 taskId) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (requester != task.requester) revert NotRequester();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (task.mode == AUCTION) {
            if (taskBids[taskId].length != 0) revert BidsExist();
        }
        task.status = TaskStatus.Cancelled;
        uint256 refundAmount = task.reward;
        if (!usdcToken.transfer(task.requester, refundAmount)) revert RefundFailed();
        emit TaskCancelled(taskId, task.requester, refundAmount);

        address hook = task.hookContract;
        if (hook != address(0)) {
            _afterHook(hook, abi.encodeCall(ITMPHook.onCancel, (taskId, _buildContext(taskId))));
        }
    }

    /**
     * @notice Update an open task's parameters. Pass 0 for any field to leave unchanged.
     *         The requester is the authenticated actor (pgtrSender).
     *         Auction tasks may only be updated if no bids have been submitted.
     *         If newReward > current reward, the forwarder must transfer the additional
     *         USDC to this contract before calling.
     * @param taskId           Task identifier
     * @param newReward        New reward amount (0 = no change); if higher, forwarder pre-transfers delta
     * @param newExpiryTime    New absolute expiry Unix timestamp (0 = no change)
     * @param newBidDeadline   New absolute bid deadline (Auction only, 0 = no change)
     * @param newPitchDeadline New absolute pitch deadline (Pitch only, 0 = no change)
     */
    // Complexity is inherent: each of the four optional update fields requires independent validation and transfer branches.
    // solhint-disable-next-line code-complexity
    function updateTask(
        bytes32 taskId,
        uint256 newReward,
        uint256 newExpiryTime,
        uint256 newBidDeadline,
        uint256 newPitchDeadline
    ) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        if (task.requester == address(0)) revert TaskDoesNotExist();
        if (requester != task.requester) revert NotRequester();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (task.mode == AUCTION) {
            if (taskBids[taskId].length != 0) revert BidsExist();
        }

        uint256 originalReward = task.reward;
        uint256 originalExpiryTime = task.expiryTime;
        uint256 originalBidDeadline = taskAuctionConfigs[taskId].bidDeadline;
        uint256 originalPitchDeadline = taskPitchConfigs[taskId].pitchDeadline;

        uint256 refund = 0;
        if (newReward != 0 && newReward != task.reward) {
            refund = newReward < task.reward ? task.reward - newReward : 0;
            task.reward = newReward;
            if (task.mode == AUCTION) {
                taskAuctionConfigs[taskId].maxPrice = newReward;
            }
        }
        if (newExpiryTime != 0) {
            if (newExpiryTime <= block.timestamp) revert ExpiryMustBeInFuture();
            task.expiryTime = newExpiryTime;
        }
        if (newBidDeadline != 0 && task.mode == AUCTION) {
            if (newBidDeadline <= block.timestamp) revert BidDeadlineMustBeInFuture();
            taskAuctionConfigs[taskId].bidDeadline = newBidDeadline;
        }
        if (newPitchDeadline != 0 && task.mode == PITCH) {
            if (newPitchDeadline <= block.timestamp) revert PitchDeadlineMustBeInFuture();
            taskPitchConfigs[taskId].pitchDeadline = newPitchDeadline;
        }
        if (refund > 0) {
            if (!usdcToken.transfer(task.requester, refund)) revert USDCRefundFailed();
        }

        bool changed = (newReward != 0 && newReward != originalReward)
            || (newExpiryTime != 0 && newExpiryTime != originalExpiryTime)
            || (newBidDeadline != 0 && newBidDeadline != originalBidDeadline && task.mode == AUCTION)
            || (newPitchDeadline != 0 && newPitchDeadline != originalPitchDeadline && task.mode == PITCH);
        if (changed) {
            emit TaskUpdated(taskId, task.reward, task.expiryTime);
        }
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /**
     * @notice Get worker statistics
     * @param worker Worker address
     * @return Worker stats struct (completedTasks, ratedTasks, totalStars)
     */
    function getWorkerStats(address worker) external view returns (WorkerStats memory) {
        return workerStats[worker];
    }

    function getCredibility(address worker) external view returns (uint256) {
        uint256 n = workerStats[worker].ratedTasks;
        if (n == 0) return 0;
        return (n * 1000) / (n + 10);
    }

    function getAverageRating(address worker) external view returns (uint256) {
        WorkerStats storage s = workerStats[worker];
        if (s.ratedTasks == 0) return 0;
        return (s.totalStars * 10) / s.ratedTasks;
    }

    /**
     * @notice Get task details
     * @param taskId Task identifier
     * @return task Task struct
     */
    function getTask(bytes32 taskId) external view returns (Task memory) {
        return tasks[taskId];
    }

    /**
     * @notice Get evaluator configuration for a task
     * @param taskId Task identifier
     */
    function getTaskEvaluatorConfig(bytes32 taskId) external view returns (TaskEvaluatorConfig memory) {
        return taskEvaluatorConfigs[taskId];
    }

    /**
     * @notice Get auction configuration for a task
     * @param taskId Task identifier
     */
    function getTaskAuctionConfig(bytes32 taskId) external view returns (TaskAuctionConfig memory) {
        return taskAuctionConfigs[taskId];
    }

    /**
     * @notice Get write-once metadata for a task (createdAt, claimedAt, content hash/URI)
     * @param taskId Task identifier
     */
    function getTaskMetadata(bytes32 taskId) external view returns (TaskMetadata memory) {
        return taskMetadata[taskId];
    }

    /**
     * @notice Get pitch configuration for a task
     * @param taskId Task identifier
     */
    function getTaskPitchConfig(bytes32 taskId) external view returns (TaskPitchConfig memory) {
        return taskPitchConfigs[taskId];
    }

    /**
     * @notice Per-task fee in basis points stamped at task creation (ITMPFees).
     * @param taskId Task identifier
     * @return Fee in basis points for this task
     */
    function feeForTask(bytes32 taskId) external view returns (uint16) {
        return tasks[taskId].feeBps;
    }

    /**
     * @notice Returns the evaluator assigned to a task (ITMPEvaluator).
     *         Returns address(0) if no evaluator is assigned.
     * @param taskId Task identifier
     */
    function evaluatorFor(bytes32 taskId) external view returns (address) {
        return taskEvaluatorConfigs[taskId].evaluator;
    }

    /**
     * @notice Returns the mode selector for a task (ITMPModes).
     * @param taskId Task identifier
     */
    function taskMode(bytes32 taskId) external view returns (bytes4 mode) {
        return tasks[taskId].mode;
    }

    /**
     * @notice Get all bids for a task
     * @param taskId Task identifier
     * @return bids Array of Bid structs
     */
    function getBids(bytes32 taskId) external view returns (Bid[] memory) {
        return taskBids[taskId];
    }

    // -------------------------------------------------------------------------
    // ITMPRegistry views
    // -------------------------------------------------------------------------

    function getTaskState(bytes32 taskId) external view returns (TaskStatus) {
        return tasks[taskId].status;
    }

    function getTaskContext(bytes32 taskId) external view returns (TaskContext memory) {
        return _buildContext(taskId);
    }

    function getTaskVerdict(bytes32 taskId) external view returns (Verdict memory) {
        return taskVerdicts[taskId];
    }

    // -------------------------------------------------------------------------
    // ITMPEvaluator
    // -------------------------------------------------------------------------

    /**
     * @notice Assign an evaluator to an open task.
     *         Only the requester may call this, only while the task is Open.
     *         If stakeAmount > 0, the evaluator must have pre-transferred that
     *         amount to this contract before the forwarder calls this function.
     */
    function assignEvaluator(
        bytes32 taskId,
        address evaluator,
        uint256 stakeAmount,
        uint16  feeBps,
        uint32  evaluationWindowSecs,
        uint32  appealWindowSecs,
        address disputeResolver
    ) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        TaskEvaluatorConfig storage evalCfg = taskEvaluatorConfigs[taskId];
        if (requester != task.requester) revert NotRequester();
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (evaluator == address(0)) revert InvalidEvaluator();
        if (evalCfg.evaluator != address(0)) revert EvaluatorAlreadyAssigned();
        if (feeBps > 10000) revert FeeBpsTooHigh();

        evalCfg.evaluator        = evaluator;
        evalCfg.evaluatorStake   = stakeAmount;
        evalCfg.evaluatorFeeBps  = feeBps;
        evalCfg.evaluationWindow = evaluationWindowSecs;
        evalCfg.appealWindow     = appealWindowSecs;
        evalCfg.disputeResolver  = disputeResolver;

        if (stakeAmount > 0) {
            // Pull stake from the requester, not the evaluator parameter. Pulling from
            // an arbitrary address (evaluator) would let a malicious requester drain any
            // address that has pre-approved this contract.
            if (!usdcToken.transferFrom(requester, address(this), stakeAmount)) revert StakeTransferFailed();
        }

        emit EvaluatorAssigned(taskId, evaluator, stakeAmount);
    }

    /**
     * @notice Submit an evaluation verdict.
     *         Only task.evaluator may call this.
     *         For CLAIM/PITCH/AUCTION: task must be in Review status.
     *         For BOUNTY/BENCHMARK: task must be Open.
     */
    function evaluate(
        bytes32          taskId,
        VerdictType      verdictType,
        uint16           score,
        uint16           confidence,
        bytes32          evidenceHash,
        Award[] calldata awards
    ) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address evaluatorAddr = _effectiveSender();
        Task storage task = tasks[taskId];
        TaskEvaluatorConfig storage evalCfg = taskEvaluatorConfigs[taskId];
        if (evaluatorAddr != evalCfg.evaluator) revert NotEvaluator();
        if (!(task.status == TaskStatus.Review ||
            ((task.mode == BOUNTY || task.mode == BENCHMARK) &&
                (task.status == TaskStatus.Open || task.status == TaskStatus.PendingApproval)))) revert WrongStatusForEvaluation();

        // Store the verdict.
        Verdict storage v = taskVerdicts[taskId];
        v.issued      = true;
        v.verdictType = verdictType;
        v.score       = score;
        v.confidence  = confidence;
        v.evidenceHash = evidenceHash;
        delete v.awards;
        for (uint256 i; i < awards.length; ++i) {
            v.awards.push(awards[i]);
        }

        // For BOUNTY/BENCHMARK the first award winner is the primary worker for appeal purposes.
        if ((task.mode == BOUNTY || task.mode == BENCHMARK) && awards.length > 0) {
            task.worker = awards[0].worker;
        }

        uint256 evalFee     = (task.reward * evalCfg.evaluatorFeeBps) / 10000;
        uint256 stakeReturn = evalCfg.evaluatorStake;
        evalCfg.evaluatorStake = 0;
        uint256 appealDeadline = block.timestamp + evalCfg.appealWindow;
        phaseDeadline[taskId] = appealDeadline;
        if (appealDeadline > task.expiryTime) {
            task.expiryTime = appealDeadline;
        }
        task.status = TaskStatus.Appealing;

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkEvaluate(taskId, _buildContext(taskId), evaluatorAddr)) revert HookCheckEvaluateRejected();
        }

        emit TaskEvaluated(taskId, evaluatorAddr, uint8(verdictType), score);

        if (evalFee + stakeReturn > 0) {
            if (!usdcToken.transfer(evalCfg.evaluator, evalFee + stakeReturn)) revert EvaluatorPaymentFailed();
        }
    }

    /**
     * @notice Appeal the evaluator's verdict.
     *         Only task.worker may call this while status == Appealing and within the window.
     */
    function appeal(bytes32 taskId) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        if (worker != task.worker) revert NotWorker();
        if (task.status != TaskStatus.Appealing) revert NotInAppealingState();
        if (block.timestamp >= phaseDeadline[taskId]) revert AppealWindowClosed();

        task.status = TaskStatus.Disputed;
        emit TaskAppealed(taskId, worker);
        address dr = taskEvaluatorConfigs[taskId].disputeResolver;
        if (dr != address(0)) {
            emit TaskDisputed(taskId, dr);
        }
    }

    /**
     * @notice Finalize the verdict after the appeal window has expired.
     *         Anyone may call this once block.timestamp >= appeal deadline.
     */
    function finalizeVerdict(bytes32 taskId) external whenNotPaused nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != TaskStatus.Appealing) revert NotInAppealingState();
        if (block.timestamp < phaseDeadline[taskId]) revert AppealWindowStillOpen();

        Verdict storage v = taskVerdicts[taskId];
        if (!v.issued) revert NoVerdictIssued();

        TaskEvaluatorConfig storage evalCfg = taskEvaluatorConfigs[taskId];
        if (v.verdictType == VerdictType.REJECT) {
            // Evaluator fee was already paid at evaluate() time.
            // Refund remaining escrow to requester and reopen.
            uint256 evalFee = (task.reward * evalCfg.evaluatorFeeBps) / 10000;
            uint256 refund  = task.reward - evalFee;
            task.status      = TaskStatus.Open;
            task.worker      = address(0);
            task.deliverable = bytes32(0);
            // Clear evaluator config so the reopened task uses direct acceptance flow.
            evalCfg.evaluator        = address(0);
            evalCfg.evaluationWindow = 0;
            evalCfg.appealWindow     = 0;
            if (refund > 0) {
                if (!usdcToken.transfer(task.requester, refund)) revert RefundFailed();
            }
        } else {
            _payAwards(taskId, task, v);
        }
    }

    /**
     * @notice Resolve a disputed task.
     *         Only task.disputeResolver may call this while status == Disputed.
     *         Supports direct call or call via trusted forwarder.
     */
    function resolveDispute(
        bytes32          taskId,
        VerdictType      verdictType,
        Award[] calldata awards
    ) external whenNotPaused nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != TaskStatus.Disputed) revert NotInDisputedState();
        address caller = trustedForwarders[msg.sender] ? _effectiveSender() : msg.sender;
        if (caller != taskEvaluatorConfigs[taskId].disputeResolver) revert NotDisputeResolver();
        if (verdictType == VerdictType.REJECT) revert DisputeResolutionMustAwardWorkers();
        if (awards.length == 0) revert AwardsRequired();

        Verdict storage v = taskVerdicts[taskId];
        v.verdictType = verdictType;
        delete v.awards;
        for (uint256 i; i < awards.length; ++i) {
            v.awards.push(awards[i]);
        }

        _payAwards(taskId, task, v);
    }

    /**
     * @notice Trigger evaluator timeout after the evaluation window expires.
     *         Only the requester may call this.
     *         Forfeits the evaluator stake to the fee recipient and transitions
     *         the task to PendingApproval so the requester can call acceptSubmission.
     */
    function evaluatorTimeout(bytes32 taskId) external onlyTrustedForwarder whenNotPaused nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        if (requester != task.requester) revert NotRequester();
        if (task.status != TaskStatus.Review) revert NotInReviewState();
        // phaseDeadline[taskId] holds the evaluation deadline while task is in Review.
        if (block.timestamp <= phaseDeadline[taskId]) revert EvaluationWindowNotExpired();

        TaskEvaluatorConfig storage evalCfg = taskEvaluatorConfigs[taskId];
        address timedOutEvaluator = evalCfg.evaluator;
        uint256 forfeited         = evalCfg.evaluatorStake;
        evalCfg.evaluatorStake    = 0;
        evalCfg.evaluator         = address(0);
        task.status               = TaskStatus.PendingApproval;

        if (forfeited > 0) {
            totalFeesCollected += forfeited;
            if (!usdcToken.transfer(feeRecipient, forfeited)) revert ForfeitTransferFailed();
        }

        emit EvaluatorTimedOut(taskId, timedOutEvaluator, forfeited);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Pay workers from escrowed reward per verdict awards.
     *      Applies platform fee per award and emits TaskCompleted per winner.
     *      Calls checkComplete and onComplete hooks.
     *      Awards should sum to (task.reward - evaluatorFee). Any surplus is
     *      refunded to the requester.
     */
    // Complexity is inherent: iterates N winners applying per-winner fee, transfer, hook, and event; handles excess refund.
    // solhint-disable-next-line code-complexity
    function _payAwards(bytes32 taskId, Task storage task, Verdict storage v) internal {
        uint256 evalFee   = (task.reward * taskEvaluatorConfigs[taskId].evaluatorFeeBps) / 10000;
        uint256 remaining = task.reward - evalFee;
        uint256 n         = v.awards.length;

        Verdict memory verdictMem = taskVerdicts[taskId];

        task.status = TaskStatus.Accepted;
        if (n > 0) {
            task.worker = v.awards[0].worker;
        }

        // Pre-compute all amounts and commit all state before any transfer.
        uint16 feeBps = task.feeBps;
        uint256 totalFee = 0;
        uint256 totalAwarded = 0;
        address[] memory workers = new address[](n);
        uint256[] memory nets = new uint256[](n);
        uint256[] memory awardFees = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address w   = v.awards[i].worker;
            uint256 amt = v.awards[i].amount;
            workers[i] = w;
            if (amt == 0) continue;
            totalAwarded += amt;
            uint256 fee = (amt * feeBps) / 10000;
            nets[i] = amt - fee;
            awardFees[i] = fee;
            totalFee += fee;
            workerStats[w].completedTasks++;
        }
        if (totalAwarded > remaining) revert AwardsExceedEscrow();
        if (totalFee > 0) {
            totalFeesCollected += totalFee;
        }

        address hook = task.hookContract;
        if (hook != address(0)) {
            if (!ITMPHook(hook).checkComplete(taskId, _buildContext(taskId), verdictMem)) revert HookCheckCompleteRejected();
        }

        // Multi-winner payouts require iterating recipients; a single batched transfer
        // is not possible with USDC. State is fully committed before this loop (CEI).
        // slither-disable-next-line calls-loop
        for (uint256 i; i < n; ++i) {
            if (nets[i] == 0 && awardFees[i] == 0) continue;
            if (!usdcToken.transfer(workers[i], nets[i])) revert WorkerPaymentFailed();
            emit TaskCompleted(taskId, task.requester, workers[i], nets[i], awardFees[i]);
        }
        if (totalFee > 0) {
            if (!usdcToken.transfer(feeRecipient, totalFee)) revert FeeTransferFailed();
        }

        // Refund any unawarded remainder to requester.
        if (remaining > totalAwarded) {
            if (!usdcToken.transfer(task.requester, remaining - totalAwarded)) revert ExcessRefundFailed();
        }

        if (hook != address(0)) {
            _afterHook(hook, abi.encodeCall(ITMPHook.onComplete, (taskId, _buildContext(taskId), verdictMem)));
        }
    }

    /// @dev Returns the canonical ERC-8004 tag2 string for a mode selector.
    function _modeName(bytes4 mode) internal pure returns (string memory) {
        if (mode == BOUNTY)    return "tmp.mode.bounty";
        if (mode == CLAIM)     return "tmp.mode.claim";
        if (mode == PITCH)     return "tmp.mode.pitch";
        if (mode == BENCHMARK) return "tmp.mode.benchmark";
        if (mode == AUCTION)   return "tmp.mode.auction";
        return "";
    }
}
