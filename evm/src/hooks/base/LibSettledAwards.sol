// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../../interfaces/ITMPDiamond.sol";
import { TMP_AUCTION } from "../../interfaces/ITMPModes.sol";

/// @title LibSettledAwards
/// @notice Rev030: the awards a V2 task's accept actually settled, for a hook that sizes anything
///         from the awards (a bonus, a sponsorship).
/// @dev Every hook's `beforeAccept` is shown the same core verdict, before a transforming hook's
///      result (bit 26 reallocate, bit 27 fee) is applied, so a hook that sizes from `beforeAccept`
///      follows awards that may not be the ones paid. A hook sizes in `afterComplete` instead, from
///      the awards the diamond settled, in this order:
///
///      1. The task's stored verdict, when issued: an evaluator verdict or a dispute ruling, or the
///         awards a transforming hook made a requester acceptance pay, each as paid (the diamond
///         records applied awards in the verdict since rev030).
///      2. The core awards the hook kept in transient storage during `beforeAccept` of this same
///         transaction (`keep`): a requester acceptance no hook changed stores no verdict.
///      3. The single award a single-payee settlement pays (the task's worker, the reward, or an
///         auction's accepted price).
///
///      `keep` and `take` use transient storage only, so nothing outlives the settlement
///      transaction and no proxy storage is used. Each hook passes its own `base` constant, which
///      fixes its slots; a hook that already keeps awards must keep passing the same constant.
library LibSettledAwards {
    /// @dev The settled awards of `taskId` (see the library notice). Clears what `keep` kept.
    function settledAwards(address diamond, bytes32 taskId, bytes32 base)
        internal
        returns (ITMPCore.Award[] memory awards)
    {
        (bool kept, ITMPCore.Award[] memory accepted) = take(base, taskId);
        ITMPCore.Verdict memory v = ITMPDiamond(diamond).getTaskVerdict(taskId);
        if (v.issued) return v.awards;
        if (kept) return accepted;
        return singlePayee(diamond, taskId);
    }

    /// @dev The settled verdict when the hook keeps no awards of its own: the stored verdict, or a
    ///      single-payee APPROVE.
    function settledVerdict(address diamond, bytes32 taskId) internal view returns (ITMPCore.Verdict memory v) {
        v = ITMPDiamond(diamond).getTaskVerdict(taskId);
        if (v.issued) return v;
        v.issued = true;
        v.verdictType = ITMPCore.VerdictType.APPROVE;
        v.score = 1000;
        v.confidence = 1000;
        v.awards = singlePayee(diamond, taskId);
    }

    /// @dev The single award a single-payee settlement pays: the task's worker, at an auction's
    ///      accepted price (stakeAmount) or the reward.
    function singlePayee(address diamond, bytes32 taskId) internal view returns (ITMPCore.Award[] memory awards) {
        ITMPCore.Task memory task = ITMPCore(diamond).getTask(taskId);
        awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({
            worker: task.worker, amount: task.mode == TMP_AUCTION ? task.stakeAmount : task.reward, rank: 1
        });
    }

    // Transient slots: keccak256(abi.encode(taskId, base)) holds the award count plus one (zero
    // when nothing is kept), followed by worker and amount for each award.
    function _slot(bytes32 base, bytes32 taskId) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(taskId, base)));
    }

    /// @dev Keeps the core awards `beforeAccept` was shown, for `afterComplete` in this transaction.
    ///      The diamond bounds the awards (MAX_SUBMISSION_WINNERS).
    function keep(bytes32 base, bytes32 taskId, ITMPCore.Award[] calldata awards) internal {
        uint256 slot = _slot(base, taskId);
        uint256 n = awards.length;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            tstore(slot, add(n, 1))
        }
        for (uint256 i; i < n; ++i) {
            address w = awards[i].worker;
            uint256 amount = awards[i].amount;
            uint256 at = slot + 1 + 2 * i;
            // Memory-safe: transient storage only.
            assembly ("memory-safe") {
                tstore(at, w)
                tstore(add(at, 1), amount)
            }
        }
    }

    /// @dev Reads and clears what `keep` kept for `taskId` in this transaction.
    function take(bytes32 base, bytes32 taskId) internal returns (bool kept, ITMPCore.Award[] memory awards) {
        uint256 slot = _slot(base, taskId);
        uint256 stored;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            stored := tload(slot)
            tstore(slot, 0)
        }
        if (stored == 0) return (false, awards);
        uint256 n = stored - 1;
        awards = new ITMPCore.Award[](n);
        for (uint256 i; i < n; ++i) {
            uint256 at = slot + 1 + 2 * i;
            address w;
            uint256 amount;
            // Memory-safe: transient storage only.
            assembly ("memory-safe") {
                w := tload(at)
                amount := tload(add(at, 1))
            }
            awards[i] = ITMPCore.Award({ worker: w, amount: amount, rank: uint16(i + 1) });
        }
        return (true, awards);
    }
}
