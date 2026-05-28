// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPHook } from "../../src/interfaces/ITMPHook.sol";
import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";

/// @dev Configurable mock for ITMPHook.
///      Each check* function can be configured to revert or return false.
///      Counts calls for assertion in tests.
///      lastSeenStatus records the task status observed when checkComplete fires,
///      proving the CEI-compliant call order (state committed before hook).
contract MockTaskHook is ITMPHook {
    bool public revertOnCheckFund;
    bool public rejectOnCheckFund;
    bool public revertOnCheckClaim;
    bool public rejectOnCheckClaim;
    bool public revertOnCheckSelectWorker;
    bool public rejectOnCheckSelectWorker;
    bool public revertOnCheckSubmit;
    bool public rejectOnCheckSubmit;
    bool public revertOnCheckEvaluate;
    bool public rejectOnCheckEvaluate;
    bool public revertOnCheckComplete;
    bool public rejectOnCheckComplete;

    uint256 public checkFundCalls;
    uint256 public checkClaimCalls;
    uint256 public checkSelectWorkerCalls;
    uint256 public checkSubmitCalls;
    uint256 public checkEvaluateCalls;
    uint256 public checkCompleteCalls;
    uint256 public onCompleteCalls;
    uint256 public onForfeitCalls;
    uint256 public onCancelCalls;
    uint256 public onExpireCalls;

    // Records the task status seen when checkComplete fires (CEI order verification).
    uint8 public lastSeenStatusOnCheckComplete;
    address public taskMarketAddress;

    function setTaskMarket(address tm) external {
        taskMarketAddress = tm;
    }

    function setRevertOnCheckFund(bool v) external {
        revertOnCheckFund = v;
    }

    function setRejectOnCheckFund(bool v) external {
        rejectOnCheckFund = v;
    }

    function setRevertOnCheckClaim(bool v) external {
        revertOnCheckClaim = v;
    }

    function setRejectOnCheckClaim(bool v) external {
        rejectOnCheckClaim = v;
    }

    function setRevertOnCheckSelectWorker(bool v) external {
        revertOnCheckSelectWorker = v;
    }

    function setRejectOnCheckSelectWorker(bool v) external {
        rejectOnCheckSelectWorker = v;
    }

    function setRevertOnCheckSubmit(bool v) external {
        revertOnCheckSubmit = v;
    }

    function setRejectOnCheckSubmit(bool v) external {
        rejectOnCheckSubmit = v;
    }

    function setRevertOnCheckEvaluate(bool v) external {
        revertOnCheckEvaluate = v;
    }

    function setRejectOnCheckEvaluate(bool v) external {
        rejectOnCheckEvaluate = v;
    }

    function setRevertOnCheckComplete(bool v) external {
        revertOnCheckComplete = v;
    }

    function setRejectOnCheckComplete(bool v) external {
        rejectOnCheckComplete = v;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITMPHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function checkFund(bytes32, ITMPCore.TaskContext calldata, bytes calldata) external override returns (bool) {
        checkFundCalls++;
        if (revertOnCheckFund) revert("MockTaskHook: checkFund reverted");
        return !rejectOnCheckFund;
    }

    function checkClaim(bytes32, ITMPCore.TaskContext calldata, address) external override returns (bool) {
        checkClaimCalls++;
        if (revertOnCheckClaim) revert("MockTaskHook: checkClaim reverted");
        return !rejectOnCheckClaim;
    }

    function checkSelectWorker(bytes32, ITMPCore.TaskContext calldata, address) external override returns (bool) {
        checkSelectWorkerCalls++;
        if (revertOnCheckSelectWorker) revert("MockTaskHook: checkSelectWorker reverted");
        return !rejectOnCheckSelectWorker;
    }

    function checkSubmit(bytes32, ITMPCore.TaskContext calldata, address, bytes32) external override returns (bool) {
        checkSubmitCalls++;
        if (revertOnCheckSubmit) revert("MockTaskHook: checkSubmit reverted");
        return !rejectOnCheckSubmit;
    }

    function checkEvaluate(bytes32, ITMPCore.TaskContext calldata, address) external override returns (bool) {
        checkEvaluateCalls++;
        if (revertOnCheckEvaluate) revert("MockTaskHook: checkEvaluate reverted");
        return !rejectOnCheckEvaluate;
    }

    function checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata)
        external
        override
        returns (bool)
    {
        checkCompleteCalls++;
        // Record task status to verify CEI order: state must be committed before hook fires.
        if (taskMarketAddress != address(0)) {
            ITMPCore.Task memory t = ITMPCore(taskMarketAddress).getTask(taskId);
            lastSeenStatusOnCheckComplete = uint8(t.status);
        }
        if (revertOnCheckComplete) revert("MockTaskHook: checkComplete reverted");
        return !rejectOnCheckComplete;
    }

    function onComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata) external override {
        onCompleteCalls++;
    }

    function onForfeit(bytes32, ITMPCore.TaskContext calldata, address) external override {
        onForfeitCalls++;
    }

    function onCancel(bytes32, ITMPCore.TaskContext calldata) external override {
        onCancelCalls++;
    }

    function onExpire(bytes32, ITMPCore.TaskContext calldata) external override {
        onExpireCalls++;
    }
}
