// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { IReputationRegistry } from "../interfaces/IReputationRegistry.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title FeedbackBackfillFacet -- TEMPORARY owner-only delivery of dropped ERC-8004 feedback
/// @notice Added to a live diamond by script/temp/AddFeedbackBackfill.s.sol and removed again by
///         script/temp/RemoveFeedbackBackfill.s.sol once the backfill is verified. It is not part
///         of the revision sequence, the deploy script or FacetSelectors, so a fresh diamond never
///         carries it. It holds no storage of its own.
/// @dev The Diamond keeps no record of which ratings reached the registry, so the caller must not
///      send an entry twice; the off-chain backfill script does that check.
contract FeedbackBackfillFacet {
    error FeedbackNotRated();
    error WorkerAgentIdRequired();
    error ReputationRegistryNotSet();

    event FeedbackBackfilled(bytes32 indexed taskId, address indexed worker, uint256 indexed workerAgentId);

    struct FeedbackBackfill {
        bytes32 taskId;
        address worker;
        uint8 rating;
        uint256 workerAgentId;
        string feedbackURI;
        bytes32 feedbackHash;
    }

    /// @notice Deliver ERC-8004 feedback for ratings whose registry call was dropped (owner only).
    ///         Each entry must be a rating this Diamond recorded. The registry call is not wrapped
    ///         in a try/catch: a failure reverts the whole batch.
    function backfillFeedback(FeedbackBackfill[] calldata entries) external {
        LibDiamond.enforceIsContractOwner();
        AppStorage storage s = LibAppStorage.appStorage();
        if (s.reputationRegistry == address(0)) revert ReputationRegistryNotSet();

        for (uint256 i; i < entries.length; ++i) {
            FeedbackBackfill calldata e = entries[i];
            if (!s.taskWorkerRated[e.taskId][e.worker]) revert FeedbackNotRated();
            if (e.workerAgentId == 0) revert WorkerAgentIdRequired();
            if (e.rating > 100) revert ITMPCore.RatingMustBe0To100();
            LibTaskMarket._requireFeedbackGas();

            IReputationRegistry(s.reputationRegistry)
                .giveFeedback(
                    e.workerAgentId,
                    int128(int256(uint256(e.rating))),
                    0,
                    "tmp.task.rating",
                    _modeName(s.tasks[e.taskId].mode),
                    "",
                    e.feedbackURI,
                    e.feedbackHash
                );
            emit FeedbackBackfilled(e.taskId, e.worker, e.workerAgentId);
        }
    }

    function _modeName(bytes4 mode) private pure returns (string memory) {
        if (mode == TMP_BOUNTY) return "tmp.mode.bounty";
        if (mode == TMP_CLAIM) return "tmp.mode.claim";
        if (mode == TMP_PITCH) return "tmp.mode.pitch";
        if (mode == TMP_BENCHMARK) return "tmp.mode.benchmark";
        if (mode == TMP_AUCTION) return "tmp.mode.auction";
        return "";
    }
}
