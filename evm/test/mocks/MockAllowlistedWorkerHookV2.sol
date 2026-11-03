// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";
import { TMP_BOUNTY, TMP_CLAIM } from "../../src/interfaces/ITMPModes.sol";
import { BaseTMPHookV2 } from "../../src/hooks/base/BaseTMPHookV2.sol";

/// @dev Task Hook V2 form of the AllowlistedWorkerHook reference: creation is limited to bounty
///      and claim tasks; claim, worker selection, submit and every award of an accept are limited
///      to one worker.
contract MockAllowlistedWorkerHookV2 is BaseTMPHookV2 {
    address public immutable allowedWorker;

    error NotAllowedWorker();
    error ModeNotAllowed();

    constructor(address diamond_, address allowedWorker_) BaseTMPHookV2(diamond_) {
        allowedWorker = allowedWorker_;
    }

    /// @notice beforeCreate 0, beforeClaim 3, beforeSelectWorker 5, beforeSubmitWork 9, beforeAccept 13.
    function hookCapabilities() external pure override returns (uint32) {
        return (uint32(1) << 0) | (uint32(1) << 3) | (uint32(1) << 5) | (uint32(1) << 9) | (uint32(1) << 13);
    }

    function beforeCreate(bytes32, TaskContextV2 calldata ctx, bytes calldata, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4)
    {
        if (ctx.mode != TMP_BOUNTY && ctx.mode != TMP_CLAIM) revert ModeNotAllowed();
        return this.beforeCreate.selector;
    }

    function beforeClaim(bytes32, TaskContextV2 calldata, address worker, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4)
    {
        _only(worker);
        return this.beforeClaim.selector;
    }

    function beforeSelectWorker(bytes32, TaskContextV2 calldata, address worker, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4)
    {
        _only(worker);
        return this.beforeSelectWorker.selector;
    }

    function beforeSubmitWork(bytes32, TaskContextV2 calldata, address worker, bytes32, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4)
    {
        _only(worker);
        return this.beforeSubmitWork.selector;
    }

    function beforeAccept(bytes32, TaskContextV2 calldata, ITMPCore.Verdict calldata verdict, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory)
    {
        for (uint256 i; i < verdict.awards.length; ++i) {
            _only(verdict.awards[i].worker);
        }
        return _allowAccept();
    }

    function _only(address worker) private view {
        if (worker != allowedWorker) revert NotAllowedWorker();
    }
}
