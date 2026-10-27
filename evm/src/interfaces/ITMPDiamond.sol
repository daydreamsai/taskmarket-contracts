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
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms
    ) external returns (bytes32);

    // Rev025: the createTask overload taking ITMPCore.TaskTerms is declared on ITMPTerms, not
    // here, so `abi.encodeCall(market.createTask, ...)` stays unambiguous for existing callers.
    function claimTask(bytes32 taskId, uint256 stakeAmount) external;
    function selectWorker(bytes32 taskId, address worker) external;
    function submitPitch(bytes32 taskId, bytes32 pitchHash) external;
    function submitProof(bytes32 taskId, bytes32 proofHash, bytes32 proofType, uint256 metricValue) external;
    function submitWork(bytes32 taskId, bytes32 deliverable) external;
    function rejectSubmission(bytes32 taskId, address worker) external;
    function forfeitAndReopen(bytes32 taskId) external;
    function requesterTimeout(bytes32 taskId) external;
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
    /// @dev Rev025: reverts EvaluationWindowTooShort below minEvaluationWindowSecs.
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
    function setDefaultHooks(address[] calldata hooks) external;
    function getDefaultHooks() external view returns (address[] memory);
    // Rev017: admin-settable floor on assignEvaluator's appealWindowSecs.
    function minAppealWindowSecs() external view returns (uint32);
    function setMinAppealWindowSecs(uint32 newMinimum) external;
    // Rev024: per-chain floor on the gas left before a swallowed giveFeedback call.
    function minFeedbackGas() external view returns (uint256);
    function setMinFeedbackGas(uint256 newMinimum) external;
    // Rev025: owner-only bounds on requester-chosen settlement terms (read via termsBounds).
    function setTermsBounds(uint32 minWindowSecs, uint32 maxWindowSecs, uint16 maxRejectFeeBps, uint8 maxRevisions)
        external;
    // Rev025: owner-only per-chain limits on tags and hooks per task.
    function setTaskLimits(uint16 maxTags, uint8 maxHooks) external;
    function taskLimits() external view returns (uint256 maxTags, uint256 maxHooks);
    // Rev025: owner-only per-chain floor on an evaluator's evaluationWindow.
    function minEvaluationWindowSecs() external view returns (uint32);
    function setMinEvaluationWindowSecs(uint32 newMinimum) external;
    // Rev025: owner-only ERC-8004 identity registry, binding requester feedback to its agent ID.
    function setIdentityRegistry(address registry) external;
    function identityRegistry() external view returns (address);
    function getTaskHooks(bytes32 taskId) external view returns (address[] memory);

    // -------------------------------------------------------------------------
    // FeedbackFacet (Rev025)
    // -------------------------------------------------------------------------
    function setFeedbackValue(bytes32 eventKey, int128 value) external;
    function feedbackValue(bytes32 eventKey) external view returns (int128 value, bool isSet);
    function requesterAgentOf(address requester) external view returns (uint256);
    // Rev027: the worker binding used by reservation feedback.
    function workerAgentOf(address worker) external view returns (uint256);

    // -------------------------------------------------------------------------
    // SettlementFacet (Rev025)
    // -------------------------------------------------------------------------
    function getTaskTerms(bytes32 taskId) external view returns (ITMPCore.TaskTerms memory);
    function getTaskClock(bytes32 taskId) external view returns (ITMPCore.TaskClock memory);
    function termsBounds()
        external
        view
        returns (uint32 minWindowSecs, uint32 maxWindowSecs, uint16 maxRejectFeeBps, uint8 maxRevisions);
    function reviewDeadline(bytes32 taskId) external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function MAX_SUBMISSION_WINNERS() external pure returns (uint256);
    function isSettling() external view returns (bool);
    function rejectDelivery(bytes32 taskId) external;
    function requestRevision(bytes32 taskId) external;
    function settleLapsedReview(bytes32 taskId) external;
    function releaseClaim(bytes32 taskId) external;
    // Rev027: a Claim task with a reserved worker. Creating one is the createTask overload declared
    // on ITMPReservation, kept off this interface so `market.createTask` stays unambiguous.
    function declineReservation(bytes32 taskId, uint256 workerAgentId) external;
    function getReservation(bytes32 taskId) external view returns (address worker, uint256 acceptBy);

    // -------------------------------------------------------------------------
    // Escrow accounting (Rev026): views on RegistryFacet, the sweep on AdminFacet
    // -------------------------------------------------------------------------
    function totalLiabilities() external view returns (uint256);
    function escrowRecord(bytes32 taskId) external view returns (uint256 booked, bool tracked);
    function liabilitiesInitialised() external view returns (bool);
    function sweepSurplus() external;
    function backfillLiabilities(bytes32[] calldata taskIds) external returns (uint256 booked);
    function completeLiabilities() external;
    // Rev026: per-chain gas stipend forwarded to each hook call.
    function hookGasStipend() external view returns (uint256);
    function setHookGasStipend(uint256 newStipend) external;

    // -------------------------------------------------------------------------
    // DiamondLoupeFacet
    // -------------------------------------------------------------------------
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
