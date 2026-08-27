// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPHook } from "../../interfaces/ITMPHook.sol";
import { ITMPCore } from "../../interfaces/ITMPCore.sol";

/// @title BaseTMPHook
/// @notice Minimal trusted-caller base for TaskMarket lifecycle hooks.
/// @dev Override the internal `_check*` and `_on*` functions to add hook behavior.
///      Every lifecycle callback is accepted only from the configured TaskMarket Diamond.
abstract contract BaseTMPHook is ITMPHook {
    /// @notice TaskMarket Diamond authorized to invoke lifecycle callbacks.
    address public immutable diamond;

    error BaseTMPHook__ZeroDiamond();
    error BaseTMPHook__UnauthorizedCaller(address caller);

    /// @param diamond_ The TaskMarket Diamond that dispatches this hook's callbacks.
    constructor(address diamond_) {
        if (diamond_ == address(0)) revert BaseTMPHook__ZeroDiamond();
        diamond = diamond_;
    }

    modifier onlyDiamond() {
        if (msg.sender != diamond) revert BaseTMPHook__UnauthorizedCaller(msg.sender);
        _;
    }

    function checkFund(bytes32 taskId, ITMPCore.TaskContext calldata ctx, bytes calldata hookData)
        external
        onlyDiamond
        returns (bool)
    {
        return _checkFund(taskId, ctx, hookData);
    }

    function checkClaim(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external
        onlyDiamond
        returns (bool)
    {
        return _checkClaim(taskId, ctx, worker);
    }

    function checkSelectWorker(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external
        onlyDiamond
        returns (bool)
    {
        return _checkSelectWorker(taskId, ctx, worker);
    }

    function checkSubmit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker, bytes32 deliverableHash)
        external
        onlyDiamond
        returns (bool)
    {
        return _checkSubmit(taskId, ctx, worker, deliverableHash);
    }

    function checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address evaluator)
        external
        onlyDiamond
        returns (bool)
    {
        return _checkEvaluate(taskId, ctx, evaluator);
    }

    function checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        external
        onlyDiamond
        returns (bool)
    {
        return _checkComplete(taskId, ctx, verdict);
    }

    function onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        external
        onlyDiamond
    {
        _onComplete(taskId, ctx, verdict);
    }

    function onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) external onlyDiamond {
        _onForfeit(taskId, ctx, worker);
    }

    function onCancel(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external onlyDiamond {
        _onCancel(taskId, ctx);
    }

    function onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external onlyDiamond {
        _onExpire(taskId, ctx);
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(ITMPHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function _checkFund(bytes32, ITMPCore.TaskContext calldata, bytes calldata) internal virtual returns (bool) {
        return true;
    }

    function _checkClaim(bytes32, ITMPCore.TaskContext calldata, address) internal virtual returns (bool) {
        return true;
    }

    function _checkSelectWorker(bytes32, ITMPCore.TaskContext calldata, address) internal virtual returns (bool) {
        return true;
    }

    function _checkSubmit(bytes32, ITMPCore.TaskContext calldata, address, bytes32) internal virtual returns (bool) {
        return true;
    }

    function _checkEvaluate(bytes32, ITMPCore.TaskContext calldata, address) internal virtual returns (bool) {
        return true;
    }

    function _checkComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata)
        internal
        virtual
        returns (bool)
    {
        return true;
    }

    function _onComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata) internal virtual { }

    function _onForfeit(bytes32, ITMPCore.TaskContext calldata, address) internal virtual { }

    function _onCancel(bytes32, ITMPCore.TaskContext calldata) internal virtual { }

    function _onExpire(bytes32, ITMPCore.TaskContext calldata) internal virtual { }
}
