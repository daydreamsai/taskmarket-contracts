// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { BaseTMPHook } from "../base/BaseTMPHook.sol";

/// @title CompletionReceiptHook
/// @notice Records the final lifecycle callback received for each task.
/// @dev The record is informational only: all check hooks allow. Cancellation and expiry
///      overwrite any prior record and never reserve or delete funds, so these paths cannot
///      strand hook-managed state.
contract CompletionReceiptHook is BaseTMPHook {
    enum Outcome {
        None,
        Completed,
        Forfeited,
        Cancelled,
        Expired
    }

    struct Receipt {
        Outcome outcome;
        address actor;
        bytes32 evidenceHash;
        uint64 recordedAt;
    }

    mapping(bytes32 taskId => Receipt receipt) public receipts;

    event ReceiptRecorded(bytes32 indexed taskId, Outcome indexed outcome, address indexed actor, bytes32 evidenceHash);

    constructor(address taskmarketDiamond_) BaseTMPHook(taskmarketDiamond_) { }

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata verdict)
        internal
        override
    {
        _record(taskId, Outcome.Completed, address(0), verdict.evidenceHash);
    }

    function _onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata, address worker) internal override {
        _record(taskId, Outcome.Forfeited, worker, bytes32(0));
    }

    function _onCancel(bytes32 taskId, ITMPCore.TaskContext calldata) internal override {
        _record(taskId, Outcome.Cancelled, address(0), bytes32(0));
    }

    function _onExpire(bytes32 taskId, ITMPCore.TaskContext calldata) internal override {
        _record(taskId, Outcome.Expired, address(0), bytes32(0));
    }

    function _record(bytes32 taskId, Outcome outcome, address actor, bytes32 evidenceHash) private {
        receipts[taskId] = Receipt(outcome, actor, evidenceHash, uint64(block.timestamp));
        emit ReceiptRecorded(taskId, outcome, actor, evidenceHash);
    }
}
