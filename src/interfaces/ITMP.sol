// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ITMP — Task Market Protocol core interface
/// @notice Defines the canonical interface for on-chain task marketplaces
///         that support multi-mode task coordination with USDC escrow.
///
///         Implementations MUST:
///         - Implement all functions declared in this interface
///         - Return true from supportsInterface(type(ITMP).interfaceId)
///         - Emit the declared events on every corresponding state transition
///         - Ensure refundExpired() bypasses all hooks/extensions (fund safety)
///
/// requires: ERC-20, ERC-165, ERC-8004
interface ITMP is IERC165 {

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Canonical task lifecycle states.
    ///         Disputed is intentionally absent — see ITMPDispute for dispute extension.
    enum TaskStatus {
        Open,
        Claimed,
        WorkerSelected,
        PendingApproval,
        Accepted,
        Expired,
        Cancelled
    }

    /// @notice Minimal task descriptor returned by getTask().
    ///         Implementations MAY return a superset of these fields.
    struct TaskInfo {
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
    }

    /// @notice Worker performance statistics.
    struct WorkerStats {
        uint256 completedTasks;
        uint256 ratedTasks;
        uint256 totalStars;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a task is created and reward is escrowed.
    event TaskCreated(
        bytes32 indexed taskId,
        address indexed requester,
        uint256 reward,
        uint256 expiryTime,
        bytes4  mode
    );

    /// @notice Emitted when a task is completed and worker is paid.
    event TaskAccepted(
        bytes32 indexed taskId,
        address indexed requester,
        address indexed worker,
        uint256 workerPayment,
        uint256 platformFee
    );

    /// @notice Emitted when a worker submits work (deliverable hash anchored on-chain).
    event TaskSubmitted(
        bytes32 indexed taskId,
        address indexed worker,
        bytes32 deliverable
    );

    /// @notice Emitted when a task expires and the reward is refunded.
    event TaskExpired(
        bytes32 indexed taskId,
        address indexed requester,
        uint256 refundAmount
    );

    // -------------------------------------------------------------------------
    // Required functions
    // -------------------------------------------------------------------------

    /// @notice Create a new task and escrow the reward.
    ///         The contract MUST generate the task ID as:
    ///         keccak256(abi.encode(block.chainid, address(this), requester, requesterNonce[requester]++))
    /// @param requester     Address credited as task creator on-chain
    /// @param reward        USDC reward amount (6 decimals); for Auction = max price
    /// @param duration      Task lifetime in seconds
    /// @param mode          4-byte mode selector (see ITMPMode for canonical values)
    /// @param pitchDeadline Seconds from now for pitch acceptance (Pitch mode only, 0 otherwise)
    /// @param bidDeadline   Seconds from now for bid submission (Auction mode only, 0 otherwise)
    /// @return taskId       Contract-generated canonical task identifier
    function createTask(
        address requester,
        uint256 reward,
        uint256 duration,
        bytes4  mode,
        uint256 pitchDeadline,
        uint256 bidDeadline
    ) external returns (bytes32 taskId);

    /// @notice Accept a worker's submission and release escrowed payment.
    ///         Payment is atomic with status update (nonReentrant required).
    /// @param taskId    Task identifier
    /// @param requester Must match task.requester
    /// @param worker    Worker address to receive payment
    function acceptSubmission(bytes32 taskId, address requester, address worker) external;

    /// @notice Record that a worker has submitted deliverable work.
    ///         Anchors a content hash on-chain for tamper-evident audit trail.
    ///         State change is mode-dependent:
    ///           Bounty/Benchmark → PendingApproval
    ///           Claim/Pitch/Auction → no state change (worker already locked)
    /// @param taskId     Task identifier
    /// @param worker     Worker submitting work
    /// @param deliverable Content hash of the work artifact (keccak256, IPFS CID, or ZK commitment)
    function submitWork(bytes32 taskId, address worker, bytes32 deliverable) external;

    /// @notice Rate a completed task and record feedback via ERC-8004.
    /// @param taskId       Task identifier
    /// @param requester    Must match task.requester
    /// @param rating       Score 0–100
    /// @param workerAgentId ERC-8004 agentId of worker (0 if unknown)
    /// @param feedbackURI  URI of off-chain feedback document
    /// @param feedbackHash keccak256 of the feedback document
    function rateTask(
        bytes32 taskId,
        address requester,
        uint8 rating,
        uint256 workerAgentId,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    /// @notice Refund escrowed reward to requester after expiry.
    ///         MUST bypass all hooks and extension contracts.
    ///         This is a normative security requirement — funds MUST always
    ///         be recoverable after expiry regardless of extension state.
    /// @param taskId Task identifier
    function refundExpired(bytes32 taskId) external;

    /// @notice Get task details.
    /// @param taskId Task identifier
    /// @return Task info struct
    function getTask(bytes32 taskId) external view returns (TaskInfo memory);

    /// @notice Get aggregated performance statistics for a worker.
    /// @param worker Worker address
    /// @return completedTasks Number of tasks completed
    /// @return avgRating      Average rating scaled by 100 (e.g. 7500 = 75.00)
    /// @return ratedTasks     Number of tasks that received a rating
    function getWorkerStats(address worker)
        external
        view
        returns (uint256 completedTasks, uint256 avgRating, uint256 ratedTasks);
}
