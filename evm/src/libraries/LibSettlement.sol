// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { AppStorage } from "./LibAppStorage.sol";
import { ITMPHookV2 } from "../interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../interfaces/ITMPHooksV2.sol";

/// @title LibSettlement -- rev028 settlement record and the amounts V2 after-callbacks carry
/// @dev The payout sites add what they move to per-task tallies kept in transient storage, so the
///      totals cover exactly the transition under way and need no persistent write until the task
///      settles. When a task becomes terminal, `finalize` writes the record once (forfeited is the
///      running total kept in storage), emits TaskSettled and returns the struct the V2
///      after-callbacks receive; `forfeit` adds the transition's forfeits to the running total.
///      The tallies are totals for the transition: a Claim worker's returned stake is not counted
///      (it was the worker's own money), and requesterRefund counts everything paid back to the
///      requester's side, a forfeited stake paid to the requester included.
library LibSettlement {
    // Transient slots: keccak256(abi.encode(taskId, TALLY_BASE)) + field.
    bytes32 private constant TALLY_BASE = keccak256("taskmarket.rev028.settlement.tally");
    uint256 internal constant WORKER = 0;
    uint256 internal constant REFUND = 1;
    uint256 internal constant EVALUATOR_FEE = 2;
    uint256 internal constant PROTOCOL_FEE = 3;
    uint256 internal constant HOOK_FEE = 4;
    uint256 internal constant FORFEITED = 5;
    uint256 internal constant AWARDS = 6;
    uint256 private constant FIELDS = 7;

    function _slot(bytes32 taskId) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(taskId, TALLY_BASE)));
    }

    /// @notice Adds `amount` to the transition tally `field` of `taskId`.
    function add(bytes32 taskId, uint256 field, uint256 amount) internal {
        if (amount == 0) return;
        uint256 slot = _slot(taskId) + field;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), amount))
        }
    }

    function _take(bytes32 taskId, uint256 field) private returns (uint256 v) {
        uint256 slot = _slot(taskId) + field;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            v := tload(slot)
            tstore(slot, 0)
        }
    }

    /// @notice Writes the settlement record of a task that just became terminal, emits TaskSettled
    ///         and returns it. A second call in the same transaction (a path that settles in two
    ///         steps) adds its tallies to the record already written.
    function finalize(AppStorage storage s, bytes32 taskId) internal returns (ITMPHookV2.SettlementAmounts memory a) {
        ITMPHookV2.SettlementAmounts storage r = s.taskSettlements[taskId];
        a.workerPaid = r.workerPaid + SafeCast.toUint128(_take(taskId, WORKER));
        a.requesterRefund = r.requesterRefund + SafeCast.toUint128(_take(taskId, REFUND));
        a.forfeited = r.forfeited + SafeCast.toUint128(_take(taskId, FORFEITED));
        a.evaluatorFee = r.evaluatorFee + SafeCast.toUint128(_take(taskId, EVALUATOR_FEE));
        a.protocolFee = r.protocolFee + SafeCast.toUint128(_take(taskId, PROTOCOL_FEE));
        a.hookFee = r.hookFee + SafeCast.toUint128(_take(taskId, HOOK_FEE));
        a.awardCount = r.awardCount + SafeCast.toUint16(_take(taskId, AWARDS));
        a.terminalStatus = uint8(s.tasks[taskId].status);
        a.settledAt = uint40(block.timestamp);
        a.recorded = true;
        s.taskSettlements[taskId] = a;
        emit ITMPHooksV2.TaskSettled(taskId, a);
    }

    /// @notice Adds everything this non-terminal transition moved (a forfeited stake, a reject fee
    ///         paid to the worker, a penalty paid to the requester) to the task's running totals,
    ///         and returns the totals so far (recorded stays false), for afterForfeit. finalize
    ///         adds the terminal transition on top, so the record covers the whole task.
    function forfeit(AppStorage storage s, bytes32 taskId) internal returns (ITMPHookV2.SettlementAmounts memory a) {
        ITMPHookV2.SettlementAmounts storage r = s.taskSettlements[taskId];
        r.workerPaid += SafeCast.toUint128(_take(taskId, WORKER));
        r.requesterRefund += SafeCast.toUint128(_take(taskId, REFUND));
        r.forfeited += SafeCast.toUint128(_take(taskId, FORFEITED));
        r.evaluatorFee += SafeCast.toUint128(_take(taskId, EVALUATOR_FEE));
        r.protocolFee += SafeCast.toUint128(_take(taskId, PROTOCOL_FEE));
        r.hookFee += SafeCast.toUint128(_take(taskId, HOOK_FEE));
        r.awardCount += SafeCast.toUint16(_take(taskId, AWARDS));
        a = r;
        a.terminalStatus = uint8(s.tasks[taskId].status);
    }

    /// @notice Drops every tally of `taskId`: for a payment that settles nothing (an updateTask
    ///         reward decrease), so it cannot leak into a later settlement in the same transaction.
    function clear(bytes32 taskId) internal {
        for (uint256 i; i < FIELDS; ++i) {
            _take(taskId, i);
        }
    }
}
