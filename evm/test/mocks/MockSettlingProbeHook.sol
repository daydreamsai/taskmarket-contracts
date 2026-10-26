// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPHook } from "../../src/interfaces/ITMPHook.sol";
import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";

interface ISettlingView {
    function isSettling() external view returns (bool);
}

interface IReserveRecovery {
    function recoverReserve(bytes32 taskId) external;
}

/// @dev Co-hook that, inside checkComplete, records whether the diamond reports a settlement in
///      progress and tries to recover another hook's reservation for the same task. Never blocks.
contract MockSettlingProbeHook is ITMPHook {
    address public diamond;
    address public recoveryTarget;

    bool public checkCompleteCalled;
    bool public sawSettling;
    bool public recoverAttempted;
    bool public recoverSucceeded;
    bytes public recoverRevertData;

    constructor(address diamond_) {
        diamond = diamond_;
    }

    function setRecoveryTarget(address target) external {
        recoveryTarget = target;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITMPHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function checkFund(bytes32, ITMPCore.TaskContext calldata, bytes calldata) external pure override returns (bool) {
        return true;
    }

    function checkClaim(bytes32, ITMPCore.TaskContext calldata, address) external pure override returns (bool) {
        return true;
    }

    function checkSelectWorker(bytes32, ITMPCore.TaskContext calldata, address) external pure override returns (bool) {
        return true;
    }

    function checkSubmit(bytes32, ITMPCore.TaskContext calldata, address, bytes32)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function checkEvaluate(bytes32, ITMPCore.TaskContext calldata, address) external pure override returns (bool) {
        return true;
    }

    function checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata)
        external
        override
        returns (bool)
    {
        checkCompleteCalled = true;
        sawSettling = ISettlingView(diamond).isSettling();
        if (recoveryTarget != address(0)) {
            recoverAttempted = true;
            try IReserveRecovery(recoveryTarget).recoverReserve(taskId) {
                recoverSucceeded = true;
            } catch (bytes memory reason) {
                recoverRevertData = reason;
            }
        }
        return true;
    }

    function onComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata) external override { }

    function onForfeit(bytes32, ITMPCore.TaskContext calldata, address) external override { }

    function onCancel(bytes32, ITMPCore.TaskContext calldata) external override { }

    function onExpire(bytes32, ITMPCore.TaskContext calldata) external override { }
}
