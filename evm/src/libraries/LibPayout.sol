// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { LibSettlement } from "./LibSettlement.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";

/// @title LibPayout -- rev028 award transfers shared by the accept and verdict paths
library LibPayout {
    /// @notice Books worker stats and rating rights for the final nonzero awards and the protocol
    ///         fee, then transfers them (transferAwards). Used when a transforming hook's result
    ///         replaced the core awards. Returns the awards' total; the caller refunds what is left
    ///         of its budget.
    function payAwards(
        AppStorage storage s,
        bytes32 taskId,
        address requester,
        ITMPCore.Award[] memory awards,
        uint16 feeBps,
        uint16 hookFeeBps,
        address feeHook
    ) internal returns (uint256 total) {
        uint256 totalFee;
        for (uint256 i; i < awards.length; ++i) {
            uint256 amt = awards[i].amount;
            if (amt == 0) continue;
            total += amt;
            totalFee += (amt * feeBps) / 10000;
            // A worker named twice in one verdict completes the task once.
            if (!s.taskAwarded[taskId][awards[i].worker]) {
                s.workerStats[awards[i].worker].completedTasks++;
                s.taskAwarded[taskId][awards[i].worker] = true;
            }
        }
        if (totalFee > 0) s.totalFeesCollected += totalFee;
        transferAwards(s, taskId, requester, awards, feeBps, hookFeeBps, feeHook);
    }

    /// @notice Transfers each nonzero award net of the protocol fee and the hook fee (both from the
    ///         worker side, rounded down), the protocol fee to the fee recipient and the hook fee to
    ///         `feeHook`, and adds the amounts to the settlement tallies. Books nothing else.
    function transferAwards(
        AppStorage storage s,
        bytes32 taskId,
        address requester,
        ITMPCore.Award[] memory awards,
        uint16 feeBps,
        uint16 hookFeeBps,
        address feeHook
    ) internal {
        uint256 totalFee;
        uint256 totalHookFee;
        uint256 totalNet;
        uint256 count;
        // Multi-winner payouts require iterating recipients. State is committed before the loop.
        // slither-disable-next-line calls-loop
        for (uint256 i; i < awards.length; ++i) {
            uint256 amt = awards[i].amount;
            if (amt == 0) continue;
            uint256 fee = (amt * feeBps) / 10000;
            uint256 hookFee = (amt * hookFeeBps) / 10000;
            uint256 net = amt - fee - hookFee;
            totalFee += fee;
            totalHookFee += hookFee;
            totalNet += net;
            ++count;
            if (!s.usdcToken.transfer(awards[i].worker, net)) revert ITMPCore.WorkerPaymentFailed();
            emit ITMPCore.TaskCompleted(taskId, requester, awards[i].worker, net, fee);
        }
        if (totalFee > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, totalFee)) revert ITMPCore.FeeTransferFailed();
        }
        if (totalHookFee > 0) {
            if (!s.usdcToken.transfer(feeHook, totalHookFee)) revert ITMPCore.FeeTransferFailed();
        }
        LibSettlement.add(taskId, LibSettlement.HOOK_FEE, totalHookFee);
        LibSettlement.add(taskId, LibSettlement.WORKER, totalNet);
        LibSettlement.add(taskId, LibSettlement.PROTOCOL_FEE, totalFee);
        LibSettlement.add(taskId, LibSettlement.AWARDS, count);
    }
}
