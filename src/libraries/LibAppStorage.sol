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
    // before this field existed; the one-time transition into version tracking still relies on
    // the legacy selector-presence detection in DiamondFullUpgrade.s.sol. Bumped by each
    // versioned upgrade step script after it applies its delta.
    uint256 diamondVersion;
    // Rev017: protocol-level floor on assignEvaluator's appealWindowSecs. Admin-settable rather
    // than a compiled-in constant because nobody yet knows the right value, and a facet upgrade
    // is too heavy an instrument for tuning one number. Appended to the end of the struct per
    // AGENTS.md's storage-layout rule. Zero means "never set" on every diamond that predates
    // this field, NOT "no minimum" -- reading it through LibTaskMarket._minAppealWindowSecs
    // substitutes the default, so the guard is live from the moment the facet is cut in and
    // does not depend on anyone remembering to call the setter.
    uint32 minAppealWindowSecs;
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
