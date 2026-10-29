// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPFeedback } from "../interfaces/ITMPFeedback.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";
import { ITMPProject } from "../interfaces/ITMPProject.sol";

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
    // Rev025: settlement terms and clocks, in the order the rev025 spec fixes. A pre-rev025 task
    // live at the rev025 cut was normalized to version 1 then (rev026 removed normalizeTerms). taskAwarded marks
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
    // Rev025: owner-set ERC-8004 identity registry. Stored and readable, but no longer read by
    // requester feedback, which uses the forwarder-supplied requesterAgentIds binding below. Kept
    // because storage is append-only.
    address identityRegistry;
    // Rev025: the ERC-8004 agent ID each requester's feedback goes to (0 = unbound), set or
    // replaced by the nonzero ID a trusted forwarder passes when relaying the requester's own
    // accept, cancel or refund (LibFeedback.resolveRequester).
    mapping(address => uint256) requesterAgentIds;
    // Rev025: owner-set feedback value per event key. An unset key reads as LibFeedback's default.
    mapping(bytes32 => ITMPFeedback.FeedbackValue) feedbackValues;
    // Rev026: escrow liabilities, kept by LibEscrow. totalLiabilities is the sum of every tracked
    // task's booked amount. liabilitiesInitialised is set by a fresh deploy and by the rev026
    // initialisation once every live task is booked; until then the surplus sweep is closed,
    // because the unbooked balance still holds pre-rev026 tasks' escrow.
    uint256 totalLiabilities;
    mapping(bytes32 => ITMPEscrow.EscrowRecord) escrowRecords;
    bool liabilitiesInitialised;
    // Rev026: owner-set gas stipend forwarded to each hook call on this chain. Zero means "never
    // set": LibHooks._hookGasStipend substitutes HOOK_GAS_STIPEND, so a diamond upgraded into
    // rev026 keeps the stipend it had.
    uint256 hookGasStipend;
    // Rev027: the reserved worker of a Claim task created with one (zero for every other task).
    // Only that worker may claim or decline the task, until createdAt + acceptWindowSecs. Not a
    // settlement term: it is who does the work, like task.worker. workerAgentIds is the ERC-8004
    // agent ID reserved-task worker feedback goes to, bound like requesterAgentIds but only from
    // the worker's own forwarder-relayed decline. Appended at the end per the storage-layout rule;
    // both read as zero on a diamond upgraded into rev027.
    mapping(bytes32 => address) reservedWorkers;
    mapping(address => uint256) workerAgentIds;
    // Rev027: projects, kept by ProjectFacet and LibProject. IDs run from 1; a task's zero
    // projectId means it belongs to no project. A project's budget is its pool in the funding pool contract (fundingPool, below).
    // projectPrepaid is nonzero only inside createProjectTask: it is what the project paid for
    // the task being created, so the creation payment checks expect that amount and no forwarded
    // payment. Appended at the end per the storage-layout rule.
    uint256 projectCount;
    mapping(uint256 => ITMPProject.ProjectRecord) projects;
    mapping(uint256 => bytes32[]) projectTaskIds;
    mapping(bytes32 => uint256) taskProjects;
    mapping(bytes32 => address) taskCreators;
    uint256 projectPrepaid;
    // Rev027: operator grants per project and operator, and the operator that created a project
    // task (zero for an owner-created one).
    mapping(uint256 => mapping(address => ITMPProject.Grant)) projectGrants;
    mapping(bytes32 => address) taskOperators;
    // Rev027: what a project task still holds of what its pool spent on it (the reward and
    // evaluator stake it was created or topped up with), kept by LibProject. It falls with the
    // task's escrow and is zero once the task is terminal; the sum over a pool's tasks is the
    // pool's outstanding.
    mapping(bytes32 => uint256) taskPoolDraws;
    // Rev027: the funding pool contract a project's budget lives in, set once by
    // ProjectFacet.initFundingPool and never changed. Zero until then.
    address fundingPool;
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
