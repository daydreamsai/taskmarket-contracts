// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";

/// @notice Unified application storage for all TaskMarket Diamond facets.
///         Stored at a fixed keccak256 slot; new fields must only be appended.
struct AppStorage {
    IERC20 usdcToken;
    mapping(address => bool) trustedForwarders;
    mapping(bytes32 => ITMPCore.Task) tasks;
    mapping(address => ITMPCore.WorkerStats) workerStats;
    mapping(bytes32 => uint256) stakeForfeit;
    mapping(bytes32 => ITMPCore.Bid[]) taskBids;
    uint16 defaultFeeBps;
    address feeRecipient;
    uint256 totalFeesCollected;
    address reputationRegistry;
    mapping(address => uint256) requesterNonce;
    mapping(bytes32 => bytes32[]) taskPitchHashes;
    mapping(bytes32 => bytes32[]) taskProofHashes;
    mapping(bytes32 => mapping(address => bool)) taskWorkerRated;
    mapping(bytes32 => bytes32[]) taskTags;
    mapping(bytes32 => ITMPCore.Verdict) taskVerdicts;
    mapping(bytes32 => uint256) phaseDeadline;
    mapping(bytes32 => ITMPCore.TaskEvaluatorConfig) taskEvaluatorConfigs;
    mapping(bytes32 => ITMPCore.TaskAuctionConfig) taskAuctionConfigs;
    mapping(bytes32 => ITMPCore.TaskMetadata) taskMetadata;
    mapping(bytes32 => ITMPCore.TaskPitchConfig) taskPitchConfigs;
    uint256 reentrancyStatus;
    bool paused;
    mapping(bytes32 => bool) taskHasSubmissions;
    mapping(bytes32 => mapping(address => bool)) taskRejectedWorkers;
    mapping(bytes32 => uint256) taskActiveSubmissionCount;
    mapping(bytes32 => mapping(address => bytes32[])) taskSubmissionHashes;
    // O(1) existence check for taskSubmissionHashes; set alongside every push in submitWork.
    mapping(bytes32 => mapping(address => mapping(bytes32 => bool))) taskSubmissionHashExists;
    // Rev008: multi-hook support
    address[] defaultHooks;
    mapping(bytes32 => address[]) taskHooks;
    // Rev011: explicit upgrade-step counter, tracking the same revision numbering already used
    // throughout this codebase's comments (rev007, rev008, ...). Zero on every diamond deployed
    // before this field existed. Seeded at initialize() time from LibRevision.CURRENT_REVISION on
    // a fresh deploy, and bumped by each versioned upgrade step script after it applies its
    // delta. Rev020 retired the pre-rev011 bootstrap that used to migrate a zero-versioned
    // diamond into tracking; a diamond still reading zero would have to be cut forward by hand.
    uint256 diamondVersion;
    // Rev017: protocol-level floor on assignEvaluator's appealWindowSecs. Admin-settable rather
    // than a compiled-in constant because nobody yet knows the right value, and a facet upgrade
    // is too heavy an instrument for tuning one number. Appended to the end of the struct per
    // AGENTS.md's storage-layout rule. Zero means "never set" on every diamond that predates
    // this field, NOT "no minimum" -- reading it through LibTaskMarket._minAppealWindowSecs
    // substitutes the default, so the guard is live from the moment the facet is cut in and
    // does not depend on anyone remembering to call the setter.
    uint32 minAppealWindowSecs;
    // Rev024: per-chain floor on the gas that must remain before a swallowed ERC-8004
    // giveFeedback call. The registry's cost differs by chain (about 220k on Base, up to about
    // 1.8M on Tempo), so one compiled-in constant is either too low for one chain or changes
    // behaviour on another. Appended at the end per the storage-layout rule. Zero means "never
    // set": LibTaskMarket._minFeedbackGas substitutes MIN_FEEDBACK_GAS, so a diamond that is
    // never configured keeps the rev023 floor of 450,000.
    uint256 minFeedbackGas;
    // Rev025: settlement terms and clocks, in the order the rev025 spec fixes. Read taskTerms only
    // through LibTerms.terms, which normalizes a pre-rev025 task on first read. taskAwarded marks
    // each worker paid a nonzero award; rateTask accepts only those.
    mapping(bytes32 => ITMPCore.TaskTerms) taskTerms;
    mapping(bytes32 => ITMPCore.TaskClock) taskClocks;
    mapping(bytes32 => mapping(address => bool)) taskAwarded;
    // Rev025: owner-set bounds on requester-chosen terms; zero fields read as the defaults in
    // LibTerms.
    ITMPCore.TermsBounds termsBounds;
    // Rev025: owner-set per-chain limits on tags and hooks per task; zero fields read as the
    // defaults in LibTaskLimits.
    ITMPCore.TaskLimits taskLimits;
    // Rev025: owner-set per-chain floor on an evaluator's evaluationWindow. Zero means "never
    // set": LibTaskMarket._minEvaluationWindowSecs substitutes DEFAULT_MIN_EVALUATION_WINDOW_SECS.
    uint32 minEvaluationWindowSecs;
    // Rev025: owner-set ERC-8004 identity registry. When set, requester feedback on cancelTask and
    // refundExpired is sent only for an agent ID the requester owns there; zero keeps the
    // forwarder-authenticated requester check.
    address identityRegistry;
}

library LibAppStorage {
    bytes32 internal constant APPSTORAGE_SLOT = keccak256("taskmarket.appstorage.v1");

    function appStorage() internal pure returns (AppStorage storage s) {
        bytes32 slot = APPSTORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}
