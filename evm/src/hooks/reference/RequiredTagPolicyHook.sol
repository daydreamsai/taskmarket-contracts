// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { BaseTMPHook } from "../base/BaseTMPHook.sol";

/// @title RequiredTagPolicyHook
/// @notice Accepts task funding only when the immutable task tags contain one required tag.
/// @dev Tags cannot be changed by Taskmarket's updateTask flow, so a task that passes this
///      creation-time policy cannot be moved out of compliance later.
contract RequiredTagPolicyHook is BaseTMPHook {
    error RequiredTagZero();

    bytes32 public immutable requiredTag;

    constructor(address taskmarketDiamond_, bytes32 requiredTag_) BaseTMPHook(taskmarketDiamond_) {
        if (requiredTag_ == bytes32(0)) revert RequiredTagZero();
        requiredTag = requiredTag_;
    }

    function _checkFund(bytes32, ITMPCore.TaskContext calldata ctx, bytes calldata)
        internal
        view
        override
        returns (bool)
    {
        uint256 length = ctx.tags.length;
        for (uint256 i; i < length; ++i) {
            if (ctx.tags[i] == requiredTag) return true;
        }
        return false;
    }
}
