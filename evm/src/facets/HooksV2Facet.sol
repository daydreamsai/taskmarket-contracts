// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibHooksV2 } from "../libraries/LibHooksV2.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHookV2 } from "../interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../interfaces/ITMPHooksV2.sol";
import { ITMPHookDispatch } from "../interfaces/ITMPHookDispatch.sol";
import { ITMPProject } from "../interfaces/ITMPProject.sol";

/// @title HooksV2Facet -- rev028 Task Hook V2 views, owner settings, per-action data and the
///        settlement record
contract HooksV2Facet is ITMPHooksV2 {
    modifier onlyOwner() {
        LibDiamond.enforceIsContractOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getTaskHooksV2(bytes32 taskId) external view returns (ITMPHookV2.Attachment[] memory) {
        return LibAppStorage.appStorage().taskHooksV2[taskId];
    }

    function getTaskHookVersion(bytes32 taskId) external view returns (uint8) {
        return LibAppStorage.appStorage().taskHookVersion[taskId];
    }

    function getTaskSettlement(bytes32 taskId) external view returns (ITMPHookV2.SettlementAmounts memory) {
        return LibAppStorage.appStorage().taskSettlements[taskId];
    }

    function getDefaultHooksV2() external view returns (ITMPHookV2.Attachment[] memory) {
        return LibAppStorage.appStorage().defaultHooksV2;
    }

    function hookCapabilityGas(uint8 bit) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.appStorage();
        uint256 v = s.hookCapabilityGas[bit];
        if (v != 0) return v;
        uint256 stipend = LibHooks._hookGasStipend(s);
        return stipend > LibHooksV2.GAS_FLOOR ? stipend : LibHooksV2.GAS_FLOOR;
    }

    function maxHookFeeBps() external view returns (uint16) {
        return LibAppStorage.appStorage().maxHookFeeBps;
    }

    function hookCallSeq(bytes32 taskId, uint8 index) external view returns (uint64) {
        return LibAppStorage.appStorage().hookCallSeq[taskId][index];
    }

    // -------------------------------------------------------------------------
    // Owner settings
    // -------------------------------------------------------------------------

    function setDefaultHooksV2(address[] calldata hooks) external onlyOwner {
        AppStorage storage s = LibAppStorage.appStorage();
        if (hooks.length > LibHooksV2.MAX_DEFAULT_HOOKS_V2) revert TooManyDefaultHooks();
        delete s.defaultHooksV2;
        bool transforming = false;
        for (uint256 i; i < hooks.length; i++) {
            for (uint256 j; j < i; j++) {
                if (hooks[j] == hooks[i]) revert ITMPCore.DuplicateHookAddress();
            }
            ITMPHookV2.Attachment memory a = _inspect(hooks[i], i);
            if (a.transforming) {
                if (transforming) revert MultipleTransformingHooks();
                transforming = true;
            }
            a.configHash = keccak256("");
            s.defaultHooksV2.push(a);
        }
        emit DefaultHooksV2Set(hooks);
    }

    function setHookCapabilityGas(uint8 bit, uint256 gasBudget) external onlyOwner {
        if (bit > 31 || gasBudget < LibHooksV2.GAS_FLOOR || gasBudget > LibHooksV2.GAS_MAX) {
            revert HookCapabilityGasOutOfRange();
        }
        LibAppStorage.appStorage().hookCapabilityGas[bit] = gasBudget;
        emit HookCapabilityGasSet(bit, gasBudget);
    }

    function setMaxHookFeeBps(uint16 bps) external onlyOwner {
        if (bps > LibHooksV2.MAX_HOOK_FEE_BPS_CAP) revert MaxHookFeeBpsOutOfRange();
        LibAppStorage.appStorage().maxHookFeeBps = bps;
        emit MaxHookFeeBpsSet(bps);
    }

    // -------------------------------------------------------------------------
    // Hook calls
    // -------------------------------------------------------------------------

    /// @inheritdoc ITMPHooksV2
    function callTaskHook(bytes32 taskId, address hook, bytes calldata data) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);
        address caller = LibGuards._effectiveSender(s);
        ITMPCore.TaskStatus st = s.tasks[taskId].status;
        if (s.tasks[taskId].requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        if (
            st == ITMPCore.TaskStatus.Accepted || st == ITMPCore.TaskStatus.Expired
                || st == ITMPCore.TaskStatus.Cancelled
        ) revert TaskAlreadySettled();
        (uint256 index, uint32 accepted) = _attachment(s, taskId, hook);
        uint32 roles = _roles(s, taskId, caller);
        if (roles & accepted == 0) revert HookCallRoleRefused(roles);
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeCall(ITMPHookDispatch.hookCall, (taskId, uint8(index), caller, roles, data)));
        if (!ok) {
            // Memory-safe: reverts with the returned data.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        emit TaskHookCalled(taskId, hook, caller, roles, keccak256(data));
        LibGuards._nonReentrantAfter(s);
    }

    /// @inheritdoc ITMPHooksV2
    function taskCallerRoles(bytes32 taskId, address who) external view returns (uint32) {
        return _roles(LibAppStorage.appStorage(), taskId, who);
    }

    /// @dev The attachment index of `hook` and the roles it accepts; refuses a hook that is not
    ///      attached or does not receive calls.
    function _attachment(AppStorage storage s, bytes32 taskId, address hook)
        private
        view
        returns (uint256 index, uint32 accepted)
    {
        ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
        uint256 n = list.length;
        for (; index < n; ++index) {
            if (list[index].hook == hook) break;
        }
        if (index == n) revert HookNotAttached();
        if (list[index].capabilities & (uint32(1) << LibHooksV2.BIT_HOOK_CALL) == 0) revert HookCallNotDeclared();
        accepted = list[index].callRoles;
    }

    /// @dev The caller's roles from current state; ROLE_STRANGER alone when it holds none.
    function _roles(AppStorage storage s, bytes32 taskId, address who) private view returns (uint32 roles) {
        ITMPCore.Task storage t = s.tasks[taskId];
        if (who == address(0)) return LibHooksV2.ROLE_STRANGER;
        if (who == t.requester) roles |= LibHooksV2.ROLE_REQUESTER;
        if (_isProject(s, taskId, who)) roles |= LibHooksV2.ROLE_PROJECT;
        if (who == t.worker) roles |= LibHooksV2.ROLE_WORKER;
        if (s.taskSubmissionHashes[taskId][who].length != 0) roles |= LibHooksV2.ROLE_SUBMITTER;
        if (who == s.taskEvaluatorConfigs[taskId].evaluator) roles |= LibHooksV2.ROLE_EVALUATOR;
        if (roles == 0) roles = LibHooksV2.ROLE_STRANGER;
    }

    /// @dev The owner of the task's project, the operator that created the task, or an operator
    ///      with an accepted, unrevoked grant on that project.
    function _isProject(AppStorage storage s, bytes32 taskId, address who) private view returns (bool) {
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return false;
        if (who == s.projects[projectId].owner || who == s.taskOperators[taskId]) return true;
        ITMPProject.Grant storage g = s.projectGrants[projectId][who];
        return g.accepted && !g.revoked;
    }

    // -------------------------------------------------------------------------
    // Per-action data
    // -------------------------------------------------------------------------

    /// @inheritdoc ITMPHooksV2
    /// @dev Runs `call` through the diamond with a delegatecall to itself, so the action sees the
    ///      same msg.sender (the trusted forwarder) and authenticates the same caller it would
    ///      have without the data. The data lives in transient storage for the call only.
    function withActionData(bytes calldata data, bytes calldata call) external returns (bytes memory) {
        if (data.length > LibHooksV2.MAX_ACTION_DATA) revert ActionDataTooLong();
        if (call.length >= 4 && bytes4(call[:4]) == this.withActionData.selector) revert ActionDataCallFailed();
        // Never nested, and never from inside an action under way (a hook called mid-dispatch): it
        // would replace, then clear, the outer action's data.
        if (LibHooksV2.actionDataActive() || LibAppStorage.appStorage().reentrancyStatus == LibGuards.ENTERED) {
            revert ActionDataCallFailed();
        }
        LibHooksV2.enterActionData();
        LibHooksV2.setActionData(data);
        (bool ok, bytes memory ret) = address(this).delegatecall(call);
        LibHooksV2.clearActionData();
        if (!ok) {
            // Memory-safe: reverts with the returned data.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    /// @dev setDefaultHooksV2 reads the same manifest checks a task's attach applies.
    function _inspect(address h, uint256 i) private returns (ITMPHookV2.Attachment memory a) {
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeCall(ITMPHookDispatch.hookReadManifest, (h, uint8(i))));
        if (!ok) {
            // Memory-safe: reverts with the returned data.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        a = abi.decode(ret, (ITMPHookV2.Attachment));
    }
}
