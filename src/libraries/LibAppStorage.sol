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
