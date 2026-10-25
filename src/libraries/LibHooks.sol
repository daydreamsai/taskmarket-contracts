// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage, LibAppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";

/// @title LibHooks — hook resolution, bounded hook calls and check*/on* dispatch
library LibHooks {
    // Hooks return at most a single bool (32 bytes) per ITMPHook -- checkFund, checkClaim,
    // checkSelectWorker, checkSubmit, checkEvaluate, and checkComplete all return exactly
    // one bool, and on* hooks return nothing at all. Anything beyond 32 bytes of return
    // data is therefore already an attacker signal, not a legitimate response to preserve.
    uint256 internal constant HOOK_MAX_RETURN_BYTES = 32;
    // Fixed gas stipend forwarded to every hook call, independent of the caller's own
    // remaining gas. Bounds plain compute/loop griefing by a hook; independent of, and in
    // addition to, the bounded-copy guarantee in _safeHookCall below. Sized generously
    // enough for a realistic production hook (TaskTokenRewardHook.checkClaim/checkComplete
    // cold-writes several storage slots and makes two further nested external calls into
    // EpochBudget/RewardVault, each with their own cold SSTORE writes) rather than the
    // bare minimum -- it is still a hard, fixed cap, far below a full transaction's gas
    // budget, so it does not weaken the DoS guard's intent.
    //
    // Rev026: this is the default and the floor. The stipend a hook call actually gets is the
    // owner-set s.hookGasStipend once set (see _hookGasStipend), because one figure cannot fit
    // every chain: a new storage slot costs about 20k gas on Base but about 250k on Tempo, where
    // a hook that books several new slots in one call (a sponsored-funding reservation measured
    // about 6.0M) cannot fit in 1M.
    uint256 internal constant HOOK_GAS_STIPEND = 1_000_000;
    // Rev026: highest stipend setHookGasStipend accepts. An after-hook path must have the stipend
    // left before each hook call (_dispatchAfterHooksFullGas), on top of the settlement work
    // around it (about 3.5M on Tempo), so a stipend near a chain's per-transaction gas cap would
    // make cancel, expiry and verdicts unreachable; 8M keeps that under the 2^24 cap.
    uint256 internal constant MAX_HOOK_GAS_STIPEND = 8_000_000;
    // Covers the cold hook access, context encoding and the post-call event around a hook call.
    uint256 internal constant HOOK_GAS_MARGIN = 100_000;

    // -------------------------------------------------------------------------
    // Hook helpers — low-level
    // -------------------------------------------------------------------------

    /// @notice The effective hook gas stipend: the owner-configured value, or HOOK_GAS_STIPEND
    ///         when it has never been set (every diamond upgraded into rev026 reads zero here).
    function _hookGasStipend(AppStorage storage s) internal view returns (uint256) {
        uint256 configured = s.hookGasStipend;
        return configured == 0 ? HOOK_GAS_STIPEND : configured;
    }

    /// @notice Builds a TaskContext snapshot for hook callbacks.
    function _buildContext(bytes32 taskId, AppStorage storage s) internal view returns (ITMPCore.TaskContext memory) {
        ITMPCore.Task storage t = s.tasks[taskId];
        ITMPCore.TaskEvaluatorConfig storage ec = s.taskEvaluatorConfigs[taskId];
        return ITMPCore.TaskContext({
            taskId: taskId,
            requester: t.requester,
            evaluator: ec.evaluator,
            paymentToken: address(s.usdcToken),
            reward: t.reward,
            evaluatorStake: ec.evaluatorStake,
            evaluatorFeeBps: ec.evaluatorFeeBps,
            submissionDeadline: t.expiryTime,
            evaluationWindow: ec.evaluationWindow,
            appealWindow: ec.appealWindow,
            disputeResolver: ec.disputeResolver,
            currentState: t.status,
            mode: t.mode,
            tags: s.taskTags[taskId]
        });
    }

    /// @notice Returns the hook list for a task (Rev008).
    ///         task.hookContract is deprecated dead storage; taskHooks is authoritative.
    function _resolveHooks(bytes32 taskId, AppStorage storage s) internal view returns (address[] memory) {
        return s.taskHooks[taskId];
    }

    /// @notice Bounded low-level call: forwards a fixed gas stipend to `hook` and copies at
    ///         most HOOK_MAX_RETURN_BYTES of return data into memory, regardless of the
    ///         actual returndatasize(). A plain `target.call(callData)` unconditionally
    ///         copies the full return blob into memory as part of constructing the
    ///         `(bool, bytes memory)` tuple -- even when the bytes value is discarded via
    ///         `(bool ok,)` -- and that copy's cost is quadratic in size, so an oversized
    ///         return blob can force an out-of-gas in the caller regardless of what the
    ///         caller does with the data. Bounding the copy here is a hard guarantee
    ///         independent of gas amounts or EVM gas-repricing; the gas stipend is a
    ///         separate, additional guard against plain compute/loop griefing.
    function _safeHookCall(address hook, bytes memory callData) private returns (bool ok, bytes memory ret) {
        uint256 maxCopy = HOOK_MAX_RETURN_BYTES;
        uint256 gasStipend = _hookGasStipend(LibAppStorage.appStorage());
        ret = new bytes(maxCopy);
        // Memory-safe: reads callData and writes only inside ret, which is allocated at maxCopy
        // bytes while the copy is capped at maxCopy, then shortens ret's length in place.
        assembly ("memory-safe") {
            ok := call(gasStipend, hook, 0, add(callData, 0x20), mload(callData), 0, 0)
            let copyLen := returndatasize()
            if gt(copyLen, maxCopy) { copyLen := maxCopy }
            returndatacopy(add(ret, 0x20), 0, copyLen)
            mstore(ret, copyLen)
        }
    }

    /// @notice Calls check* on every hook in order. Reverts with errSelector if any hook rejects.
    function _dispatchCheckHooks(address[] memory hooks, bytes memory callData, bytes4 errSelector) internal {
        for (uint256 i; i < hooks.length; i++) {
            (bool ok, bytes memory ret) = _safeHookCall(hooks[i], callData);
            if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) {
                // Memory-safe: writes four bytes of scratch space and reverts.
                assembly ("memory-safe") {
                    mstore(0x00, errSelector)
                    revert(0x00, 0x04)
                }
            }
        }
    }

    /// @notice Calls on* on every hook in order. Failures are swallowed individually.
    function _dispatchAfterHooks(address[] memory hooks, bytes memory callData) internal {
        for (uint256 i; i < hooks.length; i++) {
            (bool ok,) = _safeHookCall(hooks[i], callData);
            if (!ok) emit ITMPCore.HookCallFailed(hooks[i]);
        }
    }

    /// @notice Calls on* on every hook like _dispatchAfterHooks, but reverts when too little gas
    ///         remains to give a hook its full stipend. A call forwards at most 63/64 of the gas
    ///         left, so on a tight limit a swallowed hook is silently handed less than the stipend
    ///         and its payout or release is skipped. Used for every settlement hook (onComplete,
    ///         onForfeit, onCancel, onExpire). The guard never blocks cancel or expiry fund
    ///         recovery outright: it only demands more gas (at most MAX_HOOKS stipends), which
    ///         any caller can supply, so a relayed limit cannot drop a hook's release unnoticed.
    function _dispatchAfterHooksFullGas(address[] memory hooks, bytes memory callData) internal {
        uint256 stipend = _hookGasStipend(LibAppStorage.appStorage());
        for (uint256 i; i < hooks.length; i++) {
            if (gasleft() < (stipend * 64) / 63 + HOOK_GAS_MARGIN) {
                revert ITMPCore.InsufficientGasForHook();
            }
            (bool ok,) = _safeHookCall(hooks[i], callData);
            if (!ok) emit ITMPCore.HookCallFailed(hooks[i]);
        }
    }

    // -------------------------------------------------------------------------
    // Hook helpers — typed dispatch (keep abi.encodeCall out of facet stack frames)
    // -------------------------------------------------------------------------

    /// @notice Calls checkFund on all hooks, reverts if any reject. Emits HookRegistered per hook.
    function _checkFundHooks(bytes32 taskId, address[] memory hooks, bytes calldata hookData, AppStorage storage s)
        internal
    {
        bytes memory callData = abi.encodeCall(ITMPHook.checkFund, (taskId, _buildContext(taskId, s), hookData));
        for (uint256 i; i < hooks.length; i++) {
            (bool ok, bytes memory ret) = _safeHookCall(hooks[i], callData);
            if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) {
                revert ITMPCore.HookCheckFundRejected();
            }
            emit ITMPCore.HookRegistered(taskId, hooks[i]);
        }
    }

    function _checkClaimHooks(bytes32 taskId, address worker, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        if (hooks.length == 0) return;
        _dispatchCheckHooks(
            hooks,
            abi.encodeCall(ITMPHook.checkClaim, (taskId, _buildContext(taskId, s), worker)),
            ITMPCore.HookCheckClaimRejected.selector
        );
    }

    function _checkSelectWorkerHooks(bytes32 taskId, address worker, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        if (hooks.length == 0) return;
        _dispatchCheckHooks(
            hooks,
            abi.encodeCall(ITMPHook.checkSelectWorker, (taskId, _buildContext(taskId, s), worker)),
            ITMPCore.HookCheckSelectWorkerRejected.selector
        );
    }

    function _checkSubmitHooks(bytes32 taskId, address worker, bytes32 deliverable, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        if (hooks.length == 0) return;
        _dispatchCheckHooks(
            hooks,
            abi.encodeCall(ITMPHook.checkSubmit, (taskId, _buildContext(taskId, s), worker, deliverable)),
            ITMPCore.HookCheckSubmitRejected.selector
        );
    }

    function _checkEvaluateHooks(bytes32 taskId, address evaluator, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        if (hooks.length == 0) return;
        _dispatchCheckHooks(
            hooks,
            abi.encodeCall(ITMPHook.checkEvaluate, (taskId, _buildContext(taskId, s), evaluator)),
            ITMPCore.HookCheckEvaluateRejected.selector
        );
    }

    function _checkCompleteHooks(bytes32 taskId, AppStorage storage s, ITMPCore.Verdict memory verdict) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        if (hooks.length == 0) return;
        _dispatchCheckHooks(
            hooks,
            abi.encodeCall(ITMPHook.checkComplete, (taskId, _buildContext(taskId, s), verdict)),
            ITMPCore.HookCheckCompleteRejected.selector
        );
    }

    function _onCompleteHooks(bytes32 taskId, AppStorage storage s, ITMPCore.Verdict memory verdict) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        _dispatchAfterHooksFullGas(
            hooks, abi.encodeCall(ITMPHook.onComplete, (taskId, _buildContext(taskId, s), verdict))
        );
    }

    function _onForfeitHooks(bytes32 taskId, address forfeiter, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        _dispatchAfterHooksFullGas(
            hooks, abi.encodeCall(ITMPHook.onForfeit, (taskId, _buildContext(taskId, s), forfeiter))
        );
    }

    function _onCancelHooks(bytes32 taskId, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        _dispatchAfterHooksFullGas(hooks, abi.encodeCall(ITMPHook.onCancel, (taskId, _buildContext(taskId, s))));
    }

    function _onExpireHooks(bytes32 taskId, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        _dispatchAfterHooksFullGas(hooks, abi.encodeCall(ITMPHook.onExpire, (taskId, _buildContext(taskId, s))));
    }
}
