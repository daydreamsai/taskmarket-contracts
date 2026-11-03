// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";
import { BaseTMPHookV2 } from "../../src/hooks/base/BaseTMPHookV2.sol";

/// @dev Task Hook V2 form of the CompletionReceiptHook reference: records the terminal
///      after-callback a task received, with the same receipts(taskId) shape and outcome numbers.
contract MockCompletionReceiptHookV2 is BaseTMPHookV2 {
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

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    /// @notice afterComplete 21, afterCancel 22, afterExpire 23, afterForfeit 24.
    function hookCapabilities() external pure override returns (uint32) {
        return (uint32(1) << 21) | (uint32(1) << 22) | (uint32(1) << 23) | (uint32(1) << 24);
    }

    function afterComplete(bytes32 taskId, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _record(taskId, Outcome.Completed, address(0));
    }

    function afterCancel(bytes32 taskId, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _record(taskId, Outcome.Cancelled, address(0));
    }

    function afterExpire(bytes32 taskId, TaskContextV2 calldata, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _record(taskId, Outcome.Expired, address(0));
    }

    function afterForfeit(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _record(taskId, Outcome.Forfeited, ctx.actor);
    }

    function _record(bytes32 taskId, Outcome outcome, address actor) private {
        receipts[taskId] = Receipt(outcome, actor, bytes32(0), uint64(block.timestamp));
    }
}
