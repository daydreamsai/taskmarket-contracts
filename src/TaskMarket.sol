// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ITMP} from "./interfaces/ITMP.sol";
import {IPGTRForwarder} from "./interfaces/IPGTRForwarder.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";
import {ITMPReputation} from "./interfaces/ITMPReputation.sol";
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
} from "./interfaces/ITMPMode.sol";

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
contract TaskMarket is Initializable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
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

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum TaskStatus {
        Open,
        Claimed,
        WorkerSelected,
        PendingApproval,
        Accepted,
        Expired,
        Cancelled
    }

    struct Task {
        bytes32 id;
        address requester;
        address worker;
        uint256 reward;
        uint256 createdAt;
        uint256 expiryTime;
        TaskStatus status;
        uint8 rating;
        bytes4 mode;
        uint256 stakeAmount;
        address claimer;
        uint256 claimedAt;
        uint256 pitchDeadline;
        uint16 feeBps;
        uint256 bidDeadline;
        uint256 maxPrice;
        bytes32 deliverable;
        bytes32 contentHash;
        string  contentURI;
        bytes4  auctionSubtype; // Auction subtype selector (zero for non-auction tasks)
        address lowestBidder;   // Running lowest bidder (english/reverse_english subtypes)
        uint256 lowestBidPrice; // Running lowest bid price
    }

    struct Bid {
        address worker;
        uint256 price;
    }

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    IERC20 public usdcToken;

    /// @notice Mapping of trusted PGTR forwarders.
    ///         Multiple forwarders are supported for rotation and redundancy.
    mapping(address => bool) public trustedForwarders;

    mapping(bytes32 => Task) public tasks;
    mapping(address => ITMP.WorkerStats) public workerStats;
    mapping(bytes32 => uint256) public stakeForfeit;
    mapping(bytes32 => Bid[]) public taskBids;

    uint16 public defaultFeeBps;
    address public feeRecipient;
    uint256 public totalFeesCollected;
    address public reputationRegistry;

    /// @notice Per-requester nonce used to generate canonical task IDs.
    ///         Read this before calling createTask to pre-compute the task ID off-chain.
    mapping(address => uint256) public requesterNonce;

    // Reserve 48 slots for future state variables (was 50; requesterNonce consumed 1,
    // and trustedForwarders replaced authorizedServer at the same logical position).
    uint256[48] private __gap;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event TaskCreated(
        bytes32 indexed taskId,
        address indexed requester,
        uint256 reward,
        uint256 expiryTime,
        bytes4  mode
    );
    event TaskClaimed(bytes32 indexed taskId, address indexed claimer, uint256 stakeAmount);
    event TaskWorkerSelected(bytes32 indexed taskId, address indexed worker);
    event TaskAccepted(
        bytes32 indexed taskId,
        address indexed requester,
        address indexed worker,
        uint256 workerPayment,
        uint256 platformFee
    );
    event TaskSubmitted(bytes32 indexed taskId, address indexed worker, bytes32 deliverable);
    event TaskRated(bytes32 indexed taskId, address indexed worker, uint8 rating);
    event TaskExpired(bytes32 indexed taskId, address indexed requester, uint256 refundAmount);
    event StakeForfeited(bytes32 indexed taskId, address indexed claimer, uint256 stakeAmount);
    event StakeReturned(bytes32 indexed taskId, address indexed claimer, uint256 stakeAmount);
    event TaskReopened(bytes32 indexed taskId);
    event FeesUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address newRecipient);
    event ForwarderUpdated(address indexed forwarder, bool trusted);
    event ReputationRegistryUpdated(address newRegistry);
    event BidSubmitted(bytes32 indexed taskId, address indexed worker, uint256 price);
    event TaskCancelled(bytes32 indexed taskId, address indexed requester, uint256 refundAmount);
    event TaskUpdated(bytes32 indexed taskId, uint256 newReward, uint256 newExpiryTime);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyTrustedForwarder() {
        require(trustedForwarders[msg.sender], "Not trusted forwarder");
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
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_defaultFeeBps <= 10000, "Fee BPS too high");
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
     * @dev Returns true for ITMP and IERC165 interface IDs.
     * @param interfaceId 4-byte interface selector to check
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ITMP).interfaceId
            || interfaceId == type(ITMPReputation).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // -------------------------------------------------------------------------
    // Owner admin functions
    // -------------------------------------------------------------------------

    /**
     * @notice Add a trusted PGTR forwarder (owner only)
     * @param forwarder Address to trust as a forwarder
     */
    function addForwarder(address forwarder) external onlyOwner {
        require(forwarder != address(0), "Invalid forwarder address");
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
        require(feeBps <= 10000, "Fee BPS too high");
        defaultFeeBps = feeBps;
        emit FeesUpdated(feeBps);
    }

    /**
     * @notice Set fee recipient (owner only)
     * @param recipient New fee recipient address
     */
    function setFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        feeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

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
     * @param reward        USDC reward (6 decimals); for Auction = max price
     * @param duration      Task lifetime in seconds
     * @param mode            4-byte mode selector (use BOUNTY/CLAIM/PITCH/BENCHMARK/AUCTION)
     * @param pitchDeadline   Seconds from now for pitch window (Pitch mode only, 0 otherwise)
     * @param bidDeadline     Seconds from now for bid window (Auction mode only, 0 otherwise)
     * @param contentHash     Optional keccak256 of off-chain task description (bytes32(0) if unused)
     * @param contentURI      Optional URI pointing to extended task metadata (empty string if unused)
     * @param auctionSubtype  Auction subtype selector (bytes4(0) for non-auction tasks)
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
        bytes4  auctionSubtype
    ) external onlyTrustedForwarder returns (bytes32 taskId) {
        address requester = _effectiveSender();
        require(requester != address(0), "Invalid requester");
        require(reward > 0, "Reward must be greater than 0");
        require(duration > 0, "Duration must be greater than 0");
        require(
            mode == BOUNTY || mode == CLAIM || mode == PITCH || mode == BENCHMARK || mode == AUCTION,
            "Invalid mode"
        );
        if (mode == AUCTION) {
            require(
                auctionSubtype == AUCTION_DUTCH
                    || auctionSubtype == AUCTION_ENGLISH
                    || auctionSubtype == AUCTION_REVERSE_DUTCH
                    || auctionSubtype == AUCTION_REVERSE_ENGLISH,
                "Invalid auction subtype"
            );
        }

        taskId = keccak256(abi.encode(block.chainid, address(this), requester, requesterNonce[requester]++));

        // USDC was transferred to this contract by the forwarder before this call.

        tasks[taskId] = Task({
            id: taskId,
            requester: requester,
            worker: address(0),
            reward: reward,
            createdAt: block.timestamp,
            expiryTime: block.timestamp + duration,
            status: TaskStatus.Open,
            rating: 0,
            mode: mode,
            stakeAmount: 0,
            claimer: address(0),
            claimedAt: 0,
            pitchDeadline: mode == PITCH ? block.timestamp + pitchDeadline : 0,
            feeBps: defaultFeeBps,
            bidDeadline: mode == AUCTION ? block.timestamp + bidDeadline : 0,
            maxPrice: mode == AUCTION ? reward : 0,
            deliverable: bytes32(0),
            contentHash: contentHash,
            contentURI: contentURI,
            auctionSubtype: mode == AUCTION ? auctionSubtype : bytes4(0),
            lowestBidder: address(0),
            lowestBidPrice: 0
        });

        emit TaskCreated(taskId, requester, reward, block.timestamp + duration, mode);
    }

    /**
     * @notice Claim a Claim-mode task. The worker is the authenticated actor (pgtrSender).
     * @param taskId      Task identifier
     * @param stakeAmount USDC stake amount (0 = no stake required).
     *                    If > 0, the forwarder must transfer the stake to this contract before calling.
     */
    function claimTask(bytes32 taskId, uint256 stakeAmount) external onlyTrustedForwarder nonReentrant {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(worker != address(0), "Invalid worker");
        require(task.mode == CLAIM, "Not a Claim task");
        require(task.status == TaskStatus.Open, "Task not available");
        require(block.timestamp <= task.expiryTime, "Task expired");

        // If stakeAmount > 0, the stake was transferred to this contract by the forwarder.

        task.claimer = worker;
        task.claimedAt = block.timestamp;
        task.stakeAmount = stakeAmount;
        task.status = TaskStatus.Claimed;

        emit TaskClaimed(taskId, worker, stakeAmount);
    }

    /**
     * @notice Select a worker for Pitch mode. The requester is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @param worker Selected worker address
     */
    function selectWorker(bytes32 taskId, address worker) external onlyTrustedForwarder {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        require(requester == task.requester, "Not requester");
        require(task.mode == PITCH, "Not a Pitch task");
        require(task.status == TaskStatus.Open, "Task not available");
        require(block.timestamp <= task.pitchDeadline, "Pitch deadline passed");

        task.worker = worker;
        task.status = TaskStatus.WorkerSelected;

        emit TaskWorkerSelected(taskId, worker);
    }

    /**
     * @notice Submit a bid on an Auction mode task. The worker is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @param price  Bid price in USDC base units (must be <= maxPrice)
     */
    function submitBid(bytes32 taskId, uint256 price) external onlyTrustedForwarder {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(task.mode == AUCTION, "Not an Auction task");
        require(task.status == TaskStatus.Open, "Task not open");
        require(block.timestamp < task.bidDeadline, "Bid deadline passed");
        require(price <= task.maxPrice, "Bid exceeds max price");

        // Maintain running minimum for O(1) winner selection in selectLowestBidder
        if (taskBids[taskId].length == 0 || price < task.lowestBidPrice) {
            task.lowestBidPrice = price;
            task.lowestBidder = worker;
        }

        taskBids[taskId].push(Bid({ worker: worker, price: price }));

        emit BidSubmitted(taskId, worker, price);
    }

    /**
     * @notice Select the lowest bidder after bid deadline.
     * @param taskId Task identifier
     * @dev O(1): submitBid() maintains a running minimum in task.lowestBidder/lowestBidPrice.
     */
    function selectLowestBidder(bytes32 taskId) external onlyTrustedForwarder {
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(task.mode == AUCTION, "Not an Auction task");
        require(task.status == TaskStatus.Open, "Task not open");
        require(block.timestamp >= task.bidDeadline, "Bid deadline not passed");
        require(task.lowestBidder != address(0), "No bids submitted");

        task.worker = task.lowestBidder;
        task.stakeAmount = task.lowestBidPrice;
        task.status = TaskStatus.Claimed;

        emit TaskWorkerSelected(taskId, task.lowestBidder);
    }

    /**
     * @notice Directly award an open auction task to a worker at a given price.
     *         Used by clock-based auction subtypes (dutch, reverse_dutch).
     *         The worker is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @param price  Accepted price in USDC base units (must be <= task.maxPrice)
     */
    function acceptAuction(bytes32 taskId, uint256 price) external onlyTrustedForwarder {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(task.mode == AUCTION, "Not an Auction task");
        require(task.status == TaskStatus.Open, "Task not open");
        require(price <= task.maxPrice, "Price exceeds max price");
        task.worker = worker;
        task.stakeAmount = price;
        task.status = TaskStatus.Claimed;
        emit BidSubmitted(taskId, worker, price);
        emit TaskWorkerSelected(taskId, worker);
    }

    /**
     * @notice Record that a worker has submitted deliverable work.
     *         The worker is the authenticated actor (pgtrSender).
     *         Anchors a content hash on-chain for tamper-evident audit trail.
     *         State change is mode-dependent:
     *           BOUNTY/BENCHMARK → PendingApproval
     *           CLAIM/PITCH/AUCTION → no state change (worker already locked)
     * @param taskId      Task identifier
     * @param deliverable Content hash (keccak256, IPFS CID, or ZK commitment)
     */
    function submitWork(bytes32 taskId, bytes32 deliverable) external onlyTrustedForwarder {
        address worker = _effectiveSender();
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(block.timestamp <= task.expiryTime, "Task expired");

        require(task.deliverable == bytes32(0), "Deliverable already set");
        task.deliverable = deliverable;

        if (task.mode == BOUNTY || task.mode == BENCHMARK) {
            require(task.status == TaskStatus.Open, "Task not open");
            task.status = TaskStatus.PendingApproval;
        } else if (task.mode == CLAIM) {
            require(task.status == TaskStatus.Claimed, "Task not claimed");
            require(worker == task.claimer, "Worker must be claimer");
        } else if (task.mode == PITCH || task.mode == AUCTION) {
            require(task.status == TaskStatus.WorkerSelected || task.status == TaskStatus.Claimed, "Worker not selected");
            require(worker == task.worker, "Worker mismatch");
        }

        emit TaskSubmitted(taskId, worker, deliverable);
    }

    /**
     * @notice Accept submission and release payment to worker.
     *         The requester is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @param worker Worker address to pay
     */
    function acceptSubmission(bytes32 taskId, address worker) external onlyTrustedForwarder nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        require(requester == task.requester, "Not requester");
        require(block.timestamp <= task.expiryTime, "Task expired");

        if (task.mode == CLAIM) {
            require(task.status == TaskStatus.Claimed, "Task not claimed");
            require(worker == task.claimer, "Worker must be claimer");
        } else if (task.mode == PITCH) {
            require(task.status == TaskStatus.WorkerSelected, "Worker not selected");
            require(worker == task.worker, "Worker mismatch");
        } else if (task.mode == AUCTION) {
            require(task.status == TaskStatus.Claimed, "Winner not selected");
            require(worker == task.worker, "Worker mismatch");
        } else {
            require(
                task.status == TaskStatus.Open || task.status == TaskStatus.PendingApproval,
                "Task not available"
            );
        }

        task.status = TaskStatus.Accepted;
        task.worker = worker;

        workerStats[worker].completedTasks++;

        uint256 paymentAmount = task.mode == AUCTION ? task.stakeAmount : task.reward;
        uint256 fee = (paymentAmount * task.feeBps) / 10000;
        uint256 workerPayment = paymentAmount - fee;

        require(usdcToken.transfer(worker, workerPayment), "Worker payment failed");

        if (fee > 0) {
            require(usdcToken.transfer(feeRecipient, fee), "Fee transfer failed");
            totalFeesCollected += fee;
        }

        if (task.mode == CLAIM && task.stakeAmount > 0) {
            require(usdcToken.transfer(task.claimer, task.stakeAmount), "Stake return failed");
            emit StakeReturned(taskId, task.claimer, task.stakeAmount);
        }

        if (task.mode == AUCTION) {
            uint256 refund = task.maxPrice - task.stakeAmount;
            if (refund > 0) {
                require(usdcToken.transfer(task.requester, refund), "Auction refund failed");
            }
        }

        emit TaskAccepted(taskId, requester, worker, workerPayment, fee);
    }

    /**
     * @notice Forfeit claimer's stake and reopen Claim task.
     *         The requester is the authenticated actor (pgtrSender).
     * @param taskId Task identifier
     * @dev Can only be called after the task has expired. Claimer's stake is
     *      transferred to fee recipient as a non-delivery penalty.
     */
    function forfeitAndReopen(bytes32 taskId) external onlyTrustedForwarder {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        require(requester == task.requester, "Not requester");
        require(task.mode == CLAIM, "Not a Claim task");
        require(task.status == TaskStatus.Claimed, "Task not claimed");
        require(block.timestamp > task.expiryTime, "Task not yet expired");

        uint256 forfeited = task.stakeAmount;
        stakeForfeit[taskId] = forfeited;

        if (forfeited > 0) {
            require(usdcToken.transfer(feeRecipient, forfeited), "Forfeit transfer failed");
            totalFeesCollected += forfeited;
            emit StakeForfeited(taskId, task.claimer, forfeited);
        }

        task.status = TaskStatus.Open;
        task.claimer = address(0);
        task.claimedAt = 0;
        task.stakeAmount = 0;

        emit TaskReopened(taskId);
    }

    /**
     * @notice Rate a completed task and submit ERC-8004 feedback.
     *         The requester is the authenticated actor (pgtrSender).
     * @param taskId        Task identifier
     * @param rating        Rating (0-100)
     * @param workerAgentId ERC-8004 agentId of worker, or 0 if unknown
     * @param feedbackURI   URI of the canonical off-chain feedback file
     * @param feedbackHash  keccak256 hash of the feedback file content
     */
    function rateTask(
        bytes32 taskId,
        uint8 rating,
        uint256 workerAgentId,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external onlyTrustedForwarder {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        require(requester == task.requester, "Not requester");
        require(task.status == TaskStatus.Accepted, "Task not accepted");
        require(rating <= 100, "Rating must be 0-100");
        require(task.rating == 0, "Already rated");

        task.rating = rating;

        workerStats[task.worker].ratedTasks++;
        workerStats[task.worker].totalStars += rating;

        emit TaskRated(taskId, task.worker, rating);

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
     *         Funds are ALWAYS recoverable after expiry.
     *         Special case: Auction tasks with a selected winner auto-pay the worker.
     * @param taskId Task identifier
     */
    function refundExpired(bytes32 taskId) external nonReentrant {
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(block.timestamp > task.expiryTime, "Task not expired");
        require(task.status != TaskStatus.Accepted, "Task already accepted");
        require(task.status != TaskStatus.Cancelled, "Task cancelled");

        if (task.mode == AUCTION && task.status == TaskStatus.Claimed) {
            uint256 fee = (task.stakeAmount * task.feeBps) / 10000;
            uint256 workerPayment = task.stakeAmount - fee;
            task.status = TaskStatus.Accepted;
            workerStats[task.worker].completedTasks++;
            if (workerPayment > 0) {
                require(usdcToken.transfer(task.worker, workerPayment), "Worker payment failed");
            }
            if (fee > 0) {
                require(usdcToken.transfer(feeRecipient, fee), "Fee transfer failed");
                totalFeesCollected += fee;
            }
            uint256 refund = task.reward - task.stakeAmount;
            if (refund > 0) {
                require(usdcToken.transfer(task.requester, refund), "Requester refund failed");
            }
            emit TaskAccepted(taskId, task.requester, task.worker, workerPayment, fee);
            return;
        }

        task.status = TaskStatus.Expired;
        uint256 refundAmount = task.reward;

        require(usdcToken.transfer(task.requester, refundAmount), "Refund failed");

        if (task.mode == CLAIM && task.stakeAmount > 0) {
            require(usdcToken.transfer(task.claimer, task.stakeAmount), "Stake return failed");
            emit StakeReturned(taskId, task.claimer, task.stakeAmount);
        }

        emit TaskExpired(taskId, task.requester, refundAmount);
    }

    /**
     * @notice Cancel an open task and refund the escrowed reward to the requester.
     *         The requester is the authenticated actor (pgtrSender).
     *         Auction tasks may only be cancelled if no bids have been submitted.
     * @param taskId Task identifier
     */
    function cancelTask(bytes32 taskId) external onlyTrustedForwarder nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(requester == task.requester, "Not requester");
        require(task.status == TaskStatus.Open, "Task not open");
        if (task.mode == AUCTION) {
            require(taskBids[taskId].length == 0, "Bids exist");
        }
        task.status = TaskStatus.Cancelled;
        uint256 refundAmount = task.reward;
        require(usdcToken.transfer(task.requester, refundAmount), "Refund failed");
        emit TaskCancelled(taskId, task.requester, refundAmount);
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
    function updateTask(
        bytes32 taskId,
        uint256 newReward,
        uint256 newExpiryTime,
        uint256 newBidDeadline,
        uint256 newPitchDeadline
    ) external onlyTrustedForwarder nonReentrant {
        address requester = _effectiveSender();
        Task storage task = tasks[taskId];
        require(task.requester != address(0), "Task does not exist");
        require(requester == task.requester, "Not requester");
        require(task.status == TaskStatus.Open, "Task not open");
        if (task.mode == AUCTION) {
            require(taskBids[taskId].length == 0, "Bids exist");
        }

        uint256 originalReward = task.reward;
        uint256 originalExpiryTime = task.expiryTime;

        if (newReward != 0 && newReward != task.reward) {
            if (newReward > task.reward) {
                // Additional USDC was transferred to this contract by the forwarder before this call.
            } else {
                uint256 refund = task.reward - newReward;
                require(usdcToken.transfer(task.requester, refund), "USDC refund failed");
            }
            task.reward = newReward;
            if (task.mode == AUCTION) {
                task.maxPrice = newReward;
            }
        }
        if (newExpiryTime != 0) {
            require(newExpiryTime > block.timestamp, "Expiry must be in future");
            task.expiryTime = newExpiryTime;
        }
        if (newBidDeadline != 0 && task.mode == AUCTION) {
            require(newBidDeadline > block.timestamp, "Bid deadline must be in future");
            task.bidDeadline = newBidDeadline;
        }
        if (newPitchDeadline != 0 && task.mode == PITCH) {
            require(newPitchDeadline > block.timestamp, "Pitch deadline must be in future");
            task.pitchDeadline = newPitchDeadline;
        }

        bool changed = (newReward != 0 && newReward != originalReward)
            || (newExpiryTime != 0 && newExpiryTime != originalExpiryTime)
            || (newBidDeadline != 0 && task.mode == AUCTION)
            || (newPitchDeadline != 0 && task.mode == PITCH);
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
    function getWorkerStats(address worker) external view returns (ITMP.WorkerStats memory) {
        return workerStats[worker];
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
     * @notice Get all bids for a task
     * @param taskId Task identifier
     * @return bids Array of Bid structs
     */
    function getBids(bytes32 taskId) external view returns (Bid[] memory) {
        return taskBids[taskId];
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

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
