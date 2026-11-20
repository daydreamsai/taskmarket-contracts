// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { LibTaskMarket } from "./LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { TMP_BOUNTY, TMP_BENCHMARK } from "../interfaces/ITMPModes.sol";

/// @title LibAwards -- the award rules every settlement result is held to
/// @dev Rev031: an evaluator verdict, a dispute ruling and a transforming hook's result are checked
///      by the same rules, and the task's primary worker is read from awards the same way.
library LibAwards {
    uint256 internal constant NONE = type(uint256).max;

    // Complexity is inherent: one early return per award rule, kept in a single pass.
    // solhint-disable code-complexity
    /// @dev Returns the selector of the first rule `awards` breaks, or zero when it breaks none:
    ///      - at most the chain's winner cap of entries, zero-amount ones included, since every
    ///        entry is stored with the verdict (TooManyWinners);
    ///      - the paying total fits `budget` (AwardsExceedEscrow);
    ///      - every paying award names a worker who submitted on a Bounty or Benchmark, or the
    ///        locked worker on any other mode (InvalidAwardRecipient, SubmissionNotFound,
    ///        WorkerMismatch);
    ///      - no worker holds two paying awards (DuplicateAwardWorker);
    ///      - on a Bounty or Benchmark every paying award has a rank of 1 or more and no two share
    ///        one (InvalidAwardRank).
    ///      With `verdict` (an evaluator verdict or a dispute ruling), also:
    ///      - no paying award names the task's evaluator or dispute resolver (InvalidWorker);
    ///      - on a Bounty or Benchmark no paying award names a worker the requester rejected
    ///        (SubmissionAlreadyRejected).
    ///      Zero-amount entries pay nothing and name no place, so only the cap applies to them.
    function check(AppStorage storage s, bytes32 taskId, ITMPCore.Award[] memory awards, uint256 budget, bool verdict)
        internal
        view
        returns (bytes4)
    {
        uint256 n = awards.length;
        if (n > LibTaskMarket._maxSubmissionWinners(s)) return ITMPCore.TooManyWinners.selector;
        ITMPCore.Task storage task = s.tasks[taskId];
        bool contest = task.mode == TMP_BOUNTY || task.mode == TMP_BENCHMARK;
        ITMPCore.TaskEvaluatorConfig storage c = s.taskEvaluatorConfigs[taskId];
        uint256 total = 0;
        for (uint256 i; i < n; ++i) {
            ITMPCore.Award memory a = awards[i];
            if (a.amount == 0) continue;
            // total never exceeds budget, so this cannot underflow, and a hostile hook word cannot
            // overflow the sum.
            if (a.amount > budget - total) return ITMPCore.AwardsExceedEscrow.selector;
            total += a.amount;
            if (a.worker == address(0)) return ITMPCore.InvalidAwardRecipient.selector;
            if (verdict && (a.worker == c.evaluator || a.worker == c.disputeResolver)) {
                return ITMPCore.InvalidWorker.selector;
            }
            if (contest) {
                if (a.rank == 0) return ITMPCore.InvalidAwardRank.selector;
                if (s.taskSubmissionHashes[taskId][a.worker].length == 0) return ITMPCore.SubmissionNotFound.selector;
                if (verdict && s.taskRejectedWorkers[taskId][a.worker]) {
                    return ITMPCore.SubmissionAlreadyRejected.selector;
                }
            } else if (a.worker != task.worker) {
                return ITMPCore.WorkerMismatch.selector;
            }
            for (uint256 j; j < i; ++j) {
                ITMPCore.Award memory b = awards[j];
                if (b.amount == 0) continue;
                if (b.worker == a.worker) return ITMPCore.DuplicateAwardWorker.selector;
                if (contest && b.rank == a.rank) return ITMPCore.InvalidAwardRank.selector;
            }
        }
        return bytes4(0);
    }

    // solhint-enable code-complexity

    /// @dev The index of the lowest-ranked paying award, the earliest on a tie, or NONE when no
    ///      award pays. After check() at most one award holds each rank, and on a Claim, Pitch or
    ///      Auction only the locked worker is paid, so this is the task's primary worker.
    function primary(ITMPCore.Award[] memory awards) internal pure returns (uint256 p) {
        p = NONE;
        for (uint256 i; i < awards.length; ++i) {
            if (awards[i].amount == 0) continue;
            if (p == NONE || awards[i].rank < awards[p].rank) p = i;
        }
    }
}
