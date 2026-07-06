// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";

/// @notice Combined interface for the TaskMarket Diamond proxy.
///         Every function call routes through Diamond.fallback to the correct facet.
///         Use this interface when calling the Diamond from external contracts or tests
///         to avoid per-facet casting.
interface ITMPDiamond {
    // -------------------------------------------------------------------------
    // CoreFacet — mode constants and task lifecycle
    // -------------------------------------------------------------------------
    // solhint-disable func-name-mixedcase
    function BOUNTY() external pure returns (bytes4);
    function CLAIM() external pure returns (bytes4);
    function PITCH() external pure returns (bytes4);
    function BENCHMARK() external pure returns (bytes4);
    function AUCTION() external pure returns (bytes4);
    function AUCTION_DUTCH() external pure returns (bytes4);
    function AUCTION_ENGLISH() external pure returns (bytes4);
    function AUCTION_REVERSE_DUTCH() external pure returns (bytes4);
    function AUCTION_REVERSE_ENGLISH() external pure returns (bytes4);
    function MAX_BIDS_PER_TASK() external pure returns (uint256);
    // solhint-enable func-name-mixedcase

    function createTask(
        uint256 reward,
        uint256 durationSecs,
        bytes4 mode,
        uint256 pitchDeadlineSecs,
        uint256 bidDeadlineSecs,
        bytes32 contentHash,
        string calldata contentURI,
        bytes4 auctionSubtype,
        address hookContract,
        bytes32[] calldata tags,
        bytes calldata hookData
    ) external returns (bytes32);

    function claimTask(bytes32 taskId, uint256 stakeAmount) external;
    function selectWorker(bytes32 taskId, address worker) external;
    function submitPitch(bytes32 taskId, bytes32 pitchHash) external;
    function submitProof(bytes32 taskId, bytes32 proofHash, bytes32 proofType, uint256 metricValue) external;
    function submitWork(bytes32 taskId, bytes32 deliverable) external;
    function rejectSubmission(bytes32 taskId, address worker) external;
    function forfeitAndReopen(bytes32 taskId) external;
    function cancelTask(bytes32 taskId, uint256 requesterAgentId) external;
    function updateTask(
        bytes32 taskId,
        uint256 newReward,
        uint256 newExpiryTime,
        uint256 newBidDeadline,
        uint256 newPitchDeadline
    ) external;
    function refundExpired(bytes32 taskId, uint256 requesterAgentId) external;

    // -------------------------------------------------------------------------
    // AuctionFacet
    // -------------------------------------------------------------------------
    function submitBid(bytes32 taskId, uint256 bidAmount) external;
    function selectLowestBidder(bytes32 taskId) external;
    function acceptAuction(bytes32 taskId, uint256 price) external;

    // -------------------------------------------------------------------------
    // AcceptanceFacet
    // -------------------------------------------------------------------------
    function acceptSubmission(bytes32 taskId, address worker, bytes32 deliverable, uint256 requesterAgentId) external;

    /// @notice Accept N submissions with explicit share basis points.
    ///         Pass an empty deliverables array to auto-resolve each winner's latest submission.
    ///         Pass a same-length deliverables array to pin specific versions (bytes32(0) = auto for that slot).
    function acceptSubmissions(
        bytes32 taskId,
        address[] calldata workers,
        uint16[] calldata shares,
        bytes32[] calldata deliverables,
        uint256 requesterAgentId
    ) external;

    function taskSubmissionHashes(bytes32 taskId, address worker) external view returns (bytes32[] memory);

    // -------------------------------------------------------------------------
    // EvaluatorFacet
    // -------------------------------------------------------------------------
    function assignEvaluator(
        bytes32 taskId,
        address evaluator,
        uint256 stakeAmount,
        uint16 feeBps,
        uint32 evaluationWindowSecs,
        uint32 appealWindowSecs,
        address disputeResolver
    ) external;

    function evaluate(
        bytes32 taskId,
        ITMPCore.VerdictType verdictType,
        uint16 score,
        uint16 confidence,
        bytes32 evidenceHash,
        ITMPCore.Award[] calldata awards
    ) external;

    function appeal(bytes32 taskId) external;
    function finalizeVerdict(bytes32 taskId) external;
    function resolveDispute(bytes32 taskId, ITMPCore.VerdictType verdictType, ITMPCore.Award[] calldata awards) external;
    function evaluatorTimeout(bytes32 taskId) external;

    // -------------------------------------------------------------------------
    // RatingFacet
    // -------------------------------------------------------------------------
    function rateTask(
        bytes32 taskId,
        address worker,
        uint8 rating,
        uint256 workerAgentId,
        uint256 raterAgentId,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    function getCredibility(address worker) external view returns (uint256);
    function getAverageRating(address worker) external view returns (uint256);

    // -------------------------------------------------------------------------
    // RegistryFacet — views
    // -------------------------------------------------------------------------
    function getTask(bytes32 taskId) external view returns (ITMPCore.Task memory);
    function getWorkerStats(address worker) external view returns (ITMPCore.WorkerStats memory);
    function requesterNonce(address requester) external view returns (uint256);
    function getTaskState(bytes32 taskId) external view returns (ITMPCore.TaskStatus);
    function getTaskContext(bytes32 taskId) external view returns (ITMPCore.TaskContext memory);
    function getTaskVerdict(bytes32 taskId) external view returns (ITMPCore.Verdict memory);
    function evaluatorFor(bytes32 taskId) external view returns (address);
    function taskMode(bytes32 taskId) external view returns (bytes4);
    function defaultFeeBps() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function totalFeesCollected() external view returns (uint256);
    function feeForTask(bytes32 taskId) external view returns (uint16);
    function reputationRegistry() external view returns (address);
    function getTaskEvaluatorConfig(bytes32 taskId) external view returns (ITMPCore.TaskEvaluatorConfig memory);
    function getTaskAuctionConfig(bytes32 taskId) external view returns (ITMPCore.TaskAuctionConfig memory);
    function getTaskMetadata(bytes32 taskId) external view returns (ITMPCore.TaskMetadata memory);
    function getTaskPitchConfig(bytes32 taskId) external view returns (ITMPCore.TaskPitchConfig memory);
    function getBids(bytes32 taskId) external view returns (ITMPCore.Bid[] memory);
    function usdcToken() external view returns (address);
    function taskPitchHashes(bytes32 taskId, uint256 index) external view returns (bytes32);
    function taskProofHashes(bytes32 taskId, uint256 index) external view returns (bytes32);

    // -------------------------------------------------------------------------
    // AdminFacet
    // -------------------------------------------------------------------------
    function addForwarder(address forwarder) external;
    function removeForwarder(address forwarder) external;
    function isTrustedForwarder(address addr) external view returns (bool);
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function setDefaultFeeBps(uint16 feeBps) external;
    function setFeeRecipient(address recipient) external;
    function setReputationRegistry(address registry) external;

    // -------------------------------------------------------------------------
    // DiamondLoupeFacet
    // -------------------------------------------------------------------------
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
