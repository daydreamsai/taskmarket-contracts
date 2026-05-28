// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { IReputationRegistry } from "../interfaces/IReputationRegistry.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title RatingFacet — task ratings, ERC-8004 reputation, and confidence scoring
/// @notice Owns all reputation and rating concerns: workerStats updates, the IReputationRegistry
///         external call, and Bühlmann credibility calculations.
contract RatingFacet {
    bytes4 private constant BOUNTY = TMP_BOUNTY;
    bytes4 private constant CLAIM = TMP_CLAIM;
    bytes4 private constant PITCH = TMP_PITCH;
    bytes4 private constant BENCHMARK = TMP_BENCHMARK;
    bytes4 private constant AUCTION = TMP_AUCTION;

    /// @notice Rate a completed task and submit ERC-8004 feedback.
    ///         The requester is the authenticated actor (pgtrSender).
    ///         For Bounty/Benchmark modes, each (taskId, worker) pair can be rated once.
    /// @param taskId        Task identifier
    /// @param worker        Worker address being rated
    /// @param rating        Rating (0-100)
    /// @param workerAgentId ERC-8004 agentId of worker, or 0 if unknown
    /// @param raterAgentId  ERC-8004 agentId of the requester giving the rating, or 0 if unknown
    /// @param feedbackURI   URI of the canonical off-chain feedback file
    /// @param feedbackHash  keccak256 hash of the feedback file content
    function rateTask(
        bytes32 taskId,
        address worker,
        uint8 rating,
        uint256 workerAgentId,
        uint256 raterAgentId,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireForwarder(s);
        LibTaskMarket._requireNotPaused(s);

        address requester = LibTaskMarket._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (requester != task.requester) revert ITMPCore.NotRequester();
        if (task.status != ITMPCore.TaskStatus.Accepted) revert ITMPCore.TaskNotAccepted();
        if (rating > 100) revert ITMPCore.RatingMustBe0To100();

        if (task.mode == BOUNTY || task.mode == BENCHMARK) {
            if (worker == address(0)) revert ITMPCore.WorkerRequired();
        } else {
            if (worker != task.worker) revert ITMPCore.WorkerMismatch();
        }

        if (s.taskWorkerRated[taskId][worker]) revert ITMPCore.WorkerAlreadyRated();
        s.taskWorkerRated[taskId][worker] = true;

        if (task.rating == 0) {
            task.rating = rating;
        }

        s.workerStats[worker].ratedTasks++;
        s.workerStats[worker].totalStars += rating;

        emit ITMPCore.TaskRated(taskId, worker, rating, raterAgentId);

        if (workerAgentId != 0 && s.reputationRegistry != address(0)) {
            try IReputationRegistry(s.reputationRegistry)
                .giveFeedback(
                    workerAgentId,
                    int128(int256(uint256(rating))),
                    0,
                    "tmp.task.rating",
                    _modeName(task.mode),
                    "",
                    feedbackURI,
                    feedbackHash
                ) { }
                catch { }
        }
    }

    /// @notice Bühlmann credibility of a worker's reputation (0-1000).
    ///         credibility = floor(ratedTasks / (ratedTasks + 10) * 1000)
    function getCredibility(address worker) external view returns (uint256) {
        uint256 n = LibAppStorage.appStorage().workerStats[worker].ratedTasks;
        if (n == 0) return 0;
        return (n * 1000) / (n + 10);
    }

    /// @notice Average rating for a worker scaled to 0-1000.
    ///         averageRating = totalStars * 10 / ratedTasks
    function getAverageRating(address worker) external view returns (uint256) {
        ITMPCore.WorkerStats storage ws = LibAppStorage.appStorage().workerStats[worker];
        if (ws.ratedTasks == 0) return 0;
        return (ws.totalStars * 10) / ws.ratedTasks;
    }

    /// @dev Returns the canonical ERC-8004 tag2 string for a mode selector.
    function _modeName(bytes4 mode) private pure returns (string memory) {
        if (mode == BOUNTY) return "tmp.mode.bounty";
        if (mode == CLAIM) return "tmp.mode.claim";
        if (mode == PITCH) return "tmp.mode.pitch";
        if (mode == BENCHMARK) return "tmp.mode.benchmark";
        if (mode == AUCTION) return "tmp.mode.auction";
        return "";
    }
}
