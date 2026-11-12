// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage, LibAppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHookDispatch } from "../interfaces/ITMPHookDispatch.sol";
import { ITMPHookV2 } from "../interfaces/ITMPHookV2.sol";
import { LibHooksV2 } from "./LibHooksV2.sol";
import { LibSettlement } from "./LibSettlement.sol";

/// @title LibHooks — hook gas stipend, hook resolution and the typed dispatch stubs
library LibHooks {
    // Fixed gas stipend forwarded to every hook call, independent of the caller's own
    // remaining gas. Bounds plain compute/loop griefing by a hook; independent of, and in
    // addition to, the bounded-copy guarantee of the dispatch call. Sized generously
    // enough for a realistic production hook rather than the bare minimum -- it is still a
    // hard, fixed cap, far below a full transaction's gas budget, so it does not weaken the
    // DoS guard's intent.
    //
    // Rev026: this is the default and the floor. The stipend a hook call actually gets is the
    // owner-set s.hookGasStipend once set (see _hookGasStipend), because one figure cannot fit
    // every chain: a new storage slot costs about 20k gas on Base but about 250k on Tempo, where
    // a hook that books several new slots in one call (a sponsored-funding reservation measured
    // about 6.0M) cannot fit in 1M.
    uint256 internal constant HOOK_GAS_STIPEND = 1_000_000;
    // Rev026: highest stipend setHookGasStipend accepts. An after-hook path must have the stipend
    // left before each hook call (the strict after-callbacks), on top of the settlement work
    // around it (about 3.5M on Tempo), so a stipend near a chain's per-transaction gas cap would
    // make cancel, expiry and verdicts unreachable; 8M keeps that under the 2^24 cap.
    uint256 internal constant MAX_HOOK_GAS_STIPEND = 8_000_000;

    // -------------------------------------------------------------------------
    // Hook helpers — low-level
    // -------------------------------------------------------------------------

    /// @notice The effective hook gas stipend: the owner-configured value, or HOOK_GAS_STIPEND
    ///         when it has never been set (every diamond upgraded into rev026 reads zero here).
    function _hookGasStipend(AppStorage storage s) internal view returns (uint256) {
        uint256 configured = s.hookGasStipend;
        return configured == 0 ? HOOK_GAS_STIPEND : configured;
    }

    /// @notice Builds the V1-shaped TaskContext snapshot that getTaskContext returns. No hook is called
    ///         with it since rev030; it stays a public view for integrations.
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

    /// @notice The addresses of a task's hooks in dispatch order. Rev030: only V2 attachments exist;
    ///         a task created before the rev028 cut (dispatch version 0) has no hooks to dispatch,
    ///         so its list reads empty whatever legacy V1 list its storage still holds.
    function _resolveHooks(bytes32 taskId, AppStorage storage s) internal view returns (address[] memory hooks) {
        ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
        hooks = new address[](list.length);
        for (uint256 i; i < list.length; ++i) {
            hooks[i] = list[i].hook;
        }
    }

    // -------------------------------------------------------------------------
    // Rev028: typed dispatch through HookDispatchFacet
    // -------------------------------------------------------------------------
    // Every facet reaches hooks through these stubs, which call the diamond itself
    // (ITMPHookDispatch). The dispatch code then lives once, in HookDispatchFacet, instead of in
    // every facet. Rev030: every hook is a V2 hook. A task created before the rev028 cut has
    // dispatch version 0 and no V2 attachments, so it behaves as a task with no hooks. A revert
    // inside the dispatch is bubbled unchanged.

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

    /// @notice Attaches a new task's V2 hooks and runs beforeCreate (every task created after the cut).
    function _attach(bytes32 taskId, ITMPCore.HookConfig calldata hookConfig) internal {
        _self(abi.encodeCall(ITMPHookDispatch.hookAttach, (taskId, hookConfig.contracts, hookConfig.data)));
    }

    /// @notice The before-callbacks of a vetoable action.
    function _before(AppStorage storage s, bytes32 taskId, uint8 action, address who, bytes32 extra) internal {
        if (s.taskHooksV2[taskId].length == 0) return;
        _self(abi.encodeCall(ITMPHookDispatch.hookBefore, (taskId, action, who, extra)));
    }

    /// @notice The observer after-callback of a V2 task's action. `vetoable` is false for the
    ///         non-vetoable exits, where a changed hook codehash does not block the action.
    function _observe(AppStorage storage s, bytes32 taskId, uint8 action, bool vetoable) internal {
        if (s.taskHooksV2[taskId].length == 0) return;
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

    /// @notice V2 beforeAccept and the transforming hook's validated result.
    function _acceptV2(
        AppStorage storage s,
        bytes32 taskId,
        ITMPCore.Verdict memory verdict,
        bool vetoable,
        bool disputed,
        uint256 budget
    ) internal returns (bool changed, ITMPCore.Award[] memory awards, uint16 hookFeeBps, address feeHook) {
        if (s.taskHooksV2[taskId].length == 0) return (false, awards, 0, address(0));
        bytes memory ret =
            _self(abi.encodeCall(ITMPHookDispatch.hookAcceptV2, (taskId, verdict, vetoable, disputed, budget)));
        return abi.decode(ret, (bool, ITMPCore.Award[], uint16, address));
    }

    function _settle(bytes32 taskId, uint8 kind, ITMPCore.Verdict memory verdict, address who) private {
        _self(abi.encodeCall(ITMPHookDispatch.hookSettle, (taskId, kind, verdict, who)));
    }

    /// @notice Settlement record, then afterComplete.
    function _onCompleteHooks(bytes32 taskId, AppStorage storage, ITMPCore.Verdict memory verdict) internal {
        _settle(taskId, LibHooksV2.KIND_COMPLETE, verdict, address(0));
    }

    function _onForfeitHooks(bytes32 taskId, address forfeiter, AppStorage storage) internal {
        ITMPCore.Verdict memory none;
        _settle(taskId, LibHooksV2.KIND_FORFEIT, none, forfeiter);
    }

    /// @notice Rev028: an evaluator timeout forfeits the evaluator's stake. A task without V2 hooks
    ///         (dispatch version 0 included) has no hook to call; the forfeit only joins the
    ///         settlement record's running total. A V2 task also gets afterForfeit.
    function _onEvaluatorForfeit(AppStorage storage s, bytes32 taskId, address evaluator) internal {
        if (_isV2(s, taskId)) {
            ITMPCore.Verdict memory none;
            _settle(taskId, LibHooksV2.KIND_FORFEIT, none, evaluator);
        } else {
            LibSettlement.forfeit(s, taskId);
        }
    }

    /// @notice Strict variants for a non-exit action (an accept, a cancel, a rejected delivery): the
    ///         gas for every after-callback is required up front, so a gas estimate covers it.
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
