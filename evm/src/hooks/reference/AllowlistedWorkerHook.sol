// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { ITMPRegistry } from "../../interfaces/ITMPRegistry.sol";
import { TMP_BOUNTY, TMP_CLAIM } from "../../interfaces/ITMPModes.sol";
import { BaseTMPHook } from "../base/BaseTMPHook.sol";

/// @title AllowlistedWorkerHook
/// @notice Restricts Bounty and Claim tasks to one immutable worker address.
/// @dev Only Bounty and Claim are supported because their worker entry and deliverable paths
///      invoke checkSubmit/checkClaim. Pitch, Benchmark, and Auction are rejected at funding:
///      submitPitch, submitProof, and submitBid do not invoke a worker-policy hook.
///      This immutable variant intentionally has no administrator or mutable allowlist.
contract AllowlistedWorkerHook is BaseTMPHook {
    error AllowedWorkerZeroAddress();

    address public immutable allowedWorker;

    constructor(address taskmarketDiamond_, address allowedWorker_) BaseTMPHook(taskmarketDiamond_) {
        if (allowedWorker_ == address(0)) revert AllowedWorkerZeroAddress();
        allowedWorker = allowedWorker_;
    }

    function _checkFund(bytes32, ITMPCore.TaskContext calldata ctx, bytes calldata)
        internal
        pure
        override
        returns (bool)
    {
        return ctx.mode == TMP_BOUNTY || ctx.mode == TMP_CLAIM;
    }

    function _checkClaim(bytes32, ITMPCore.TaskContext calldata, address worker) internal view override returns (bool) {
        return worker == allowedWorker;
    }

    function _checkSelectWorker(bytes32, ITMPCore.TaskContext calldata, address worker)
        internal
        view
        override
        returns (bool)
    {
        return worker == allowedWorker;
    }

    function _checkSubmit(bytes32, ITMPCore.TaskContext calldata, address worker, bytes32)
        internal
        view
        override
        returns (bool)
    {
        return worker == allowedWorker;
    }

    /// @dev evaluate() stores the verdict before dispatching checkEvaluate and assigns its first
    ///      award recipient to task.worker for supported Bounty tasks, even when that award is zero.
    ///      Read the committed verdict to reject the whole transaction before that state persists.
    function _checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata, address)
        internal
        view
        override
        returns (bool)
    {
        return _areAllAwardRecipientsAllowed(ITMPRegistry(diamond).getTaskVerdict(taskId).awards);
    }

    /// @dev resolveDispute() bypasses checkEvaluate and proceeds directly to completion, so
    ///      completion independently validates every award recipient. Zero-value awards remain
    ///      in scope because the first one can still become task.worker.
    function _checkComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata verdict)
        internal
        view
        override
        returns (bool)
    {
        uint256 awardCount = verdict.awards.length;
        for (uint256 i; i < awardCount; ++i) {
            if (verdict.awards[i].worker != allowedWorker) return false;
        }
        return true;
    }

    function _areAllAwardRecipientsAllowed(ITMPCore.Award[] memory awards) private view returns (bool) {
        uint256 awardCount = awards.length;
        for (uint256 i; i < awardCount; ++i) {
            if (awards[i].worker != allowedWorker) return false;
        }
        return true;
    }
}
