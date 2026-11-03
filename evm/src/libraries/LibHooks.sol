// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage, LibAppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHookDispatch } from "../interfaces/ITMPHookDispatch.sol";
import { ITMPHookV2 } from "../interfaces/ITMPHookV2.sol";
import { LibHooksV2 } from "./LibHooksV2.sol";
import { LibSettlement } from "./LibSettlement.sol";

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
    ///         Rev028: for a V2 task, the addresses of its V2 attachments in dispatch order, so
    ///         getTaskHooks reads the same for V1 and V2 tasks.
    function _resolveHooks(bytes32 taskId, AppStorage storage s) internal view returns (address[] memory hooks) {
        if (s.taskHookVersion[taskId] == LibHooksV2.VERSION_V2) {
            ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
            hooks = new address[](list.length);
            for (uint256 i; i < list.length; ++i) {
                hooks[i] = list[i].hook;
            }
            return hooks;
        }
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
    // Rev028: typed dispatch through HookDispatchFacet
    // -------------------------------------------------------------------------
    // Every facet reaches hooks through these stubs, which call the diamond itself
    // (ITMPHookDispatch). The dispatch code then lives once, in HookDispatchFacet, instead of in
    // every facet. A V1 task (created before the rev028 cut) gets the V1 dispatch it always had;
    // every later task gets V2. A revert inside the dispatch is bubbled unchanged, so a V1 check
    // rejection still reverts with its HookCheck*Rejected selector.

    function _self(bytes memory callData) private returns (bytes memory ret) {
        bool ok;
        (ok, ret) = address(this).call(callData);
        if (!ok) {
            // Memory-safe: reverts with the returned data.
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _isV2(AppStorage storage s, bytes32 taskId) internal view returns (bool) {
        return s.taskHookVersion[taskId] == LibHooksV2.VERSION_V2;
    }

    function _hasHooks(AppStorage storage s, bytes32 taskId) internal view returns (bool) {
        return _isV2(s, taskId) ? s.taskHooksV2[taskId].length > 0 : s.taskHooks[taskId].length > 0;
    }

    /// @notice Attaches a new task's V2 hooks and runs beforeCreate (every task created after the cut).
    function _attach(bytes32 taskId, ITMPCore.HookConfig calldata hookConfig) internal {
        _self(abi.encodeCall(ITMPHookDispatch.hookAttach, (taskId, hookConfig.contracts, hookConfig.data)));
    }

    /// @notice The before-callbacks of a vetoable action (the V1 check where V1 had one).
    function _before(AppStorage storage s, bytes32 taskId, uint8 action, address who, bytes32 extra) internal {
        if (_isV2(s, taskId)) {
            if (s.taskHooksV2[taskId].length == 0) return;
        } else if (
            s.taskHooks[taskId].length == 0
                || (action != LibHooksV2.A_CLAIM
                    && action != LibHooksV2.A_SELECT_WORKER
                    && action != LibHooksV2.A_ACCEPT_AUCTION
                    && action != LibHooksV2.A_SUBMIT_WORK
                    && action != LibHooksV2.A_EVALUATE)
        ) {
            // A V1 task has a check hook only for claim, worker selection, submit and evaluate.
            return;
        }
        _self(abi.encodeCall(ITMPHookDispatch.hookBefore, (taskId, action, who, extra)));
    }

    /// @notice The observer after-callback of a V2 task's action. `vetoable` is false for the
    ///         non-vetoable exits, where a changed hook codehash does not block the action.
    function _observe(AppStorage storage s, bytes32 taskId, uint8 action, bool vetoable) internal {
        if (!_isV2(s, taskId) || s.taskHooksV2[taskId].length == 0) return;
        _self(abi.encodeCall(ITMPHookDispatch.hookObserve, (taskId, action, vetoable)));
    }

    function _checkClaimHooks(bytes32 taskId, address worker, AppStorage storage s) internal {
        _before(s, taskId, LibHooksV2.A_CLAIM, worker, bytes32(0));
    }

    function _checkSelectWorkerHooks(bytes32 taskId, address worker, AppStorage storage s) internal {
        _before(s, taskId, LibHooksV2.A_SELECT_WORKER, worker, bytes32(0));
    }

    function _checkSubmitHooks(bytes32 taskId, address worker, bytes32 deliverable, AppStorage storage s) internal {
        _before(s, taskId, LibHooksV2.A_SUBMIT_WORK, worker, deliverable);
    }

    function _checkEvaluateHooks(bytes32 taskId, address evaluator, AppStorage storage s) internal {
        _before(s, taskId, LibHooksV2.A_EVALUATE, evaluator, bytes32(0));
    }

    /// @notice V1 checkComplete. On a dispute resolution (`disputed`) the context passed to the
    ///         hooks shows currentState == Disputed (rev028).
    function _checkCompleteHooks(bytes32 taskId, AppStorage storage s, ITMPCore.Verdict memory verdict, bool disputed)
        internal
    {
        if (_isV2(s, taskId) || s.taskHooks[taskId].length == 0) return;
        _self(abi.encodeCall(ITMPHookDispatch.hookCheckCompleteV1, (taskId, verdict, disputed)));
    }

    /// @notice V2 beforeAccept and the transforming hook's validated result, for a V2 task.
    function _acceptV2(
        AppStorage storage s,
        bytes32 taskId,
        ITMPCore.Verdict memory verdict,
        bool vetoable,
        bool disputed,
        uint256 budget
    ) internal returns (bool changed, ITMPCore.Award[] memory awards, uint16 hookFeeBps, address feeHook) {
        if (!_isV2(s, taskId) || s.taskHooksV2[taskId].length == 0) return (false, awards, 0, address(0));
        bytes memory ret =
            _self(abi.encodeCall(ITMPHookDispatch.hookAcceptV2, (taskId, verdict, vetoable, disputed, budget)));
        return abi.decode(ret, (bool, ITMPCore.Award[], uint16, address));
    }

    function _settle(bytes32 taskId, uint8 kind, ITMPCore.Verdict memory verdict, address who) private {
        _self(abi.encodeCall(ITMPHookDispatch.hookSettle, (taskId, kind, verdict, who)));
    }

    /// @notice Settlement record, then onComplete (V1) or afterComplete (V2).
    function _onCompleteHooks(bytes32 taskId, AppStorage storage, ITMPCore.Verdict memory verdict) internal {
        _settle(taskId, LibHooksV2.KIND_COMPLETE, verdict, address(0));
    }

    function _onForfeitHooks(bytes32 taskId, address forfeiter, AppStorage storage) internal {
        ITMPCore.Verdict memory none;
        _settle(taskId, LibHooksV2.KIND_FORFEIT, none, forfeiter);
    }

    /// @notice Rev028: an evaluator timeout forfeits the evaluator's stake. V1 never called a hook
    ///         here and still does not; the forfeit only joins the settlement record's running
    ///         total. A V2 task also gets afterForfeit.
    function _onEvaluatorForfeit(AppStorage storage s, bytes32 taskId, address evaluator) internal {
        if (_isV2(s, taskId)) {
            ITMPCore.Verdict memory none;
            _settle(taskId, LibHooksV2.KIND_FORFEIT, none, evaluator);
        } else {
            LibSettlement.forfeit(s, taskId);
        }
    }

    /// @notice Strict variants for a non-exit action (an accept, a cancel, a rejected delivery): the
    ///         gas for every V2 after-callback is required up front, so a gas estimate covers it.
    function _onCompleteHooksStrict(bytes32 taskId, ITMPCore.Verdict memory verdict) internal {
        _settle(taskId, LibHooksV2.KIND_COMPLETE | LibHooksV2.KIND_STRICT, verdict, address(0));
    }

    function _onCancelHooksStrict(bytes32 taskId) internal {
        ITMPCore.Verdict memory none;
        _settle(taskId, LibHooksV2.KIND_CANCEL | LibHooksV2.KIND_STRICT, none, address(0));
    }

    function _onForfeitHooksStrict(bytes32 taskId, address forfeiter) internal {
        ITMPCore.Verdict memory none;
        _settle(taskId, LibHooksV2.KIND_FORFEIT | LibHooksV2.KIND_STRICT, none, forfeiter);
    }

    function _onCancelHooks(bytes32 taskId, AppStorage storage) internal {
        ITMPCore.Verdict memory none;
        _settle(taskId, LibHooksV2.KIND_CANCEL, none, address(0));
    }

    function _onExpireHooks(bytes32 taskId, AppStorage storage) internal {
        ITMPCore.Verdict memory none;
        _settle(taskId, LibHooksV2.KIND_EXPIRE, none, address(0));
    }
}
