// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { AppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";
import { TMP_CLAIM } from "../interfaces/ITMPModes.sol";
import { LibProject } from "./LibProject.sol";

/// @title LibEscrow -- rev026 escrow liabilities and the solvency check
/// @dev A task's booked amount is re-derived from its state with `owed`, the escrow conservation
///      formula, rather than adjusted at each transfer, so the facets keep their payout code and
///      call one helper at the end of each money-moving entrypoint: `book` after funding, `release`
///      after paying out. `release` caps what left the diamond during the call at what the task's
///      liability fell by, so no task can be paid more than was booked for it, and both helpers
///      end with `balanceOf(diamond) >= totalLiabilities`.
library LibEscrow {
    /// @notice What a task holds in escrow: zero once terminal, otherwise its reward (which keeps
    ///         the deferred evaluator fee and is reduced by a paid reject fee), plus a Claim
    ///         worker's stake and the evaluator stake. An auction's stakeAmount is its accepted
    ///         price, part of the reward.
    function owed(AppStorage storage s, bytes32 taskId) internal view returns (uint256) {
        (uint256 funded, uint256 stake) = owedParts(s, taskId);
        return funded + stake;
    }

    /// @notice owed, split into what the requester's side funded (the reward and the evaluator
    ///         stake: for a project task, its pool's money) and a Claim worker's stake.
    function owedParts(AppStorage storage s, bytes32 taskId) internal view returns (uint256 funded, uint256 stake) {
        ITMPCore.Task storage t = s.tasks[taskId];
        ITMPCore.TaskStatus st = t.status;
        if (
            st == ITMPCore.TaskStatus.Accepted || st == ITMPCore.TaskStatus.Expired
                || st == ITMPCore.TaskStatus.Cancelled
        ) return (0, 0);
        funded = t.reward + s.taskEvaluatorConfigs[taskId].evaluatorStake;
        if (t.mode == TMP_CLAIM) stake = t.stakeAmount;
    }

    function balance(AppStorage storage s) internal view returns (uint256) {
        return s.usdcToken.balanceOf(address(this));
    }

    /// @notice Books the growth in a task's liability after a funding call. The funds arrived
    ///         before the call, through the forwarded payment, so the unbooked surplus must cover
    ///         what is booked. `start` opens the record of a task being created; a pre-rev026 task
    ///         the initialisation has not booked is left unbooked.
    function book(AppStorage storage s, bytes32 taskId, address payer, ITMPEscrow.Component component, bool start)
        internal
    {
        ITMPEscrow.EscrowRecord storage rec = s.escrowRecords[taskId];
        if (start) {
            rec.tracked = true;
        } else if (!rec.tracked) {
            emit ITMPEscrow.UnbookedFunding(taskId, payer, component);
            return;
        }
        uint256 o = owed(s, taskId);
        uint256 booked = rec.booked;
        if (o < booked) revert ITMPEscrow.EscrowMismatch(taskId, o, booked);
        uint256 amount = o - booked;
        rec.booked = SafeCast.toUint128(o);
        s.totalLiabilities += amount;
        requireSolvent(s);
        if (amount > 0) emit ITMPEscrow.EscrowFunded(taskId, payer, amount, component);
    }

    /// @notice Releases the fall in a task's liability after a payout call, given the diamond's
    ///         balance when the call began. What left the diamond may not exceed what was
    ///         released. A pre-rev026 task the initialisation missed releases nothing and only
    ///         reports what it paid out, so a migration gap never strands its funds.
    function release(AppStorage storage s, bytes32 taskId, uint256 balanceBefore) internal {
        _release(s, taskId, balanceBefore);
    }

    /// @dev release's body, out of line so the facets that release at many sites carry it once.
    function _release(AppStorage storage s, bytes32 taskId, uint256 balanceBefore) private {
        uint256 balanceAfter = balance(s);
        uint256 paidOut = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        ITMPEscrow.EscrowRecord storage rec = s.escrowRecords[taskId];
        if (!rec.tracked) {
            if (paidOut > 0) emit ITMPEscrow.UnbookedRelease(taskId, paidOut);
            _requireSolvent(balanceAfter, s.totalLiabilities);
            return;
        }
        (uint256 funded, uint256 stake) = owedParts(s, taskId);
        uint256 o = funded + stake;
        uint256 booked = rec.booked;
        if (o > booked) revert ITMPEscrow.EscrowMismatch(taskId, o, booked);
        uint256 released = booked - o;
        if (paidOut > released) revert ITMPEscrow.EscrowOverdrawn(taskId, paidOut, released);
        rec.booked = SafeCast.toUint128(o);
        // Rev027: the pool money a project task no longer holds leaves its pool's outstanding;
        // a Claim worker's stake is not pool money.
        LibProject.finishDraw(s, taskId, funded);
        uint256 total = s.totalLiabilities - released;
        s.totalLiabilities = total;
        _requireSolvent(balanceAfter, total);
        if (released > 0) emit ITMPEscrow.EscrowReleased(taskId, released);
    }

    /// @notice Books a task created before rev026 at what it owes now. Returns false, booking
    ///         nothing, for an unknown, terminal or already-booked task, so a repeated or stale ID
    ///         in the backfill is harmless. A live task owing nothing (a reopened task whose reject
    ///         fee took its whole reward) is still booked at zero, so its later funding is booked.
    function backfill(AppStorage storage s, bytes32 taskId) internal returns (bool) {
        ITMPEscrow.EscrowRecord storage rec = s.escrowRecords[taskId];
        ITMPCore.Task storage t = s.tasks[taskId];
        if (rec.tracked || t.requester == address(0)) return false;
        ITMPCore.TaskStatus st = t.status;
        if (
            st == ITMPCore.TaskStatus.Accepted || st == ITMPCore.TaskStatus.Expired
                || st == ITMPCore.TaskStatus.Cancelled
        ) return false;
        uint256 o = owed(s, taskId);
        rec.tracked = true;
        rec.booked = SafeCast.toUint128(o);
        s.totalLiabilities += o;
        emit ITMPEscrow.EscrowBackfilled(taskId, o);
        return true;
    }

    function requireSolvent(AppStorage storage s) internal view {
        _requireSolvent(balance(s), s.totalLiabilities);
    }

    function _requireSolvent(uint256 bal, uint256 liabilities) private pure {
        if (bal < liabilities) revert ITMPEscrow.EscrowInsolvent(bal, liabilities);
    }
}
