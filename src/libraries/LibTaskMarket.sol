// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";
import { IPGTRForwarder } from "../interfaces/IPGTRForwarder.sol";

/// @title LibTaskMarket — shared internal helpers for TaskMarket facets
/// @dev All helpers take AppStorage as an explicit parameter so they can be called
///      from any facet. Functions that call external contracts must be `internal`
///      (not `private`) so they are accessible across facets via library linkage.
library LibTaskMarket {
    uint256 internal constant NOT_ENTERED = 1;
    uint256 internal constant ENTERED = 2;

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
    uint256 internal constant HOOK_GAS_STIPEND = 1_000_000;

    // Rev017: default floor for assignEvaluator's appealWindowSecs, used whenever
    // s.minAppealWindowSecs has never been set. Five minutes is sized for a worker that
    // discovers an adverse verdict by polling on a bounded schedule rather than by watching
    // the chain continuously: a minute is barely distinguishable from zero for such a worker,
    // which would leave the degenerate case this guard exists to close only nominally closed.
    // It is not an opinion on how long a dispute window ought to be -- that stays the
    // requester's choice, same as evaluationWindowSecs -- and it is admin-settable precisely
    // so it can be corrected in either direction without a facet upgrade.
    uint32 internal constant DEFAULT_MIN_APPEAL_WINDOW_SECS = 5 minutes;

    // -------------------------------------------------------------------------
    // Errors (not in ITMPCore since they are implementation-specific)
    // -------------------------------------------------------------------------

    /// @notice Revert when a function is called while the contract is paused.
    error EnforcedPause();

    /// @notice Revert on reentrancy attempt.
    error ReentrancyGuardReentrantCall();

    // -------------------------------------------------------------------------
    // Guards
    // -------------------------------------------------------------------------

    function _requireForwarder(AppStorage storage s) internal view {
        if (!s.trustedForwarders[msg.sender]) revert ITMPCore.NotTrustedForwarder();
    }

    function _requireNotPaused(AppStorage storage s) internal view {
        if (s.paused) revert EnforcedPause();
    }

    function _nonReentrantBefore(AppStorage storage s) internal {
        if (s.reentrancyStatus == ENTERED) revert ReentrancyGuardReentrantCall();
        s.reentrancyStatus = ENTERED;
    }

    function _nonReentrantAfter(AppStorage storage s) internal {
        s.reentrancyStatus = NOT_ENTERED;
    }

    // -------------------------------------------------------------------------
    // PGTR forwarder resolution
    // -------------------------------------------------------------------------

    /// @notice Returns the authenticated actor for this call.
    ///         If msg.sender is a trusted PGTR forwarder, returns pgtrSender().
    ///         Otherwise returns msg.sender.
    function _effectiveSender(AppStorage storage s) internal view returns (address) {
        if (s.trustedForwarders[msg.sender]) {
            return IPGTRForwarder(msg.sender).pgtrSender();
        }
        return msg.sender;
    }

    // -------------------------------------------------------------------------
    // Evaluator configuration — shared by the two entry points that may write it
    // -------------------------------------------------------------------------

    /// @notice Writes a task's evaluator configuration and pulls any evaluator stake.
    /// @dev Two entry points may configure an evaluator: CoreFacet.createTask, which takes the
    ///      configuration atomically with the task itself, and EvaluatorFacet.assignEvaluator,
    ///      which appoints one to an already-live task. They share this body deliberately. If
    ///      each kept its own copy, the creation path would sooner or later validate less than
    ///      the assignment path and become the way to bypass the difference -- the guard that is
    ///      cheapest to skip is the one nobody has written yet. Every check on the evaluator
    ///      terms themselves belongs here, so a later revision tightening one of them tightens
    ///      both paths without having to know both paths exist.
    ///
    ///      Only the checks that depend on the caller's own context stay with the caller, because
    ///      they genuinely differ: on creation the requester is the authenticated sender by
    ///      construction and the task is Open by construction, so `NotRequester` and
    ///      `TaskNotOpen` have nothing to test.
    /// @param taskId    Task identifier
    /// @param requester Authenticated requester; the address any stake is pulled from
    /// @param cfg       Evaluator terms to store
    /// @param s         AppStorage
    function _applyEvaluatorConfig(
        bytes32 taskId,
        address requester,
        ITMPCore.TaskEvaluatorConfig memory cfg,
        AppStorage storage s
    ) internal {
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (cfg.evaluator == address(0)) revert ITMPCore.InvalidEvaluator();
        if (cfg.evaluator == requester) revert ITMPCore.EvaluatorCannotBeRequester();
        if (cfg.disputeResolver == requester) revert ITMPCore.DisputeResolverCannotBeRequester();
        if (evalCfg.evaluator != address(0)) revert ITMPCore.EvaluatorAlreadyAssigned();
        if (cfg.evaluatorFeeBps > 10000) revert ITMPCore.FeeBpsTooHigh();
        if (cfg.appealWindow < _minAppealWindowSecs(s)) revert ITMPCore.AppealWindowTooShort();

        evalCfg.evaluator = cfg.evaluator;
        evalCfg.evaluatorStake = cfg.evaluatorStake;
        evalCfg.evaluatorFeeBps = cfg.evaluatorFeeBps;
        evalCfg.evaluationWindow = cfg.evaluationWindow;
        evalCfg.appealWindow = cfg.appealWindow;
        evalCfg.disputeResolver = cfg.disputeResolver;

        if (cfg.evaluatorStake > 0) {
            // Pull stake from the requester. Pulling from an arbitrary evaluator address would
            // let a malicious requester drain any address that has pre-approved this contract.
            // requester = _effectiveSender(s) = authenticated PGTR forwarder caller; not arbitrary
            // slither-disable-next-line arbitrary-send-erc20
            if (!s.usdcToken.transferFrom(requester, address(this), cfg.evaluatorStake)) {
                revert ITMPCore.StakeTransferFailed();
            }
        }

        // Emitted identically whichever entry point wrote the config, so an indexer sees one
        // event vocabulary for "this task has an evaluator" rather than having to infer it from
        // TaskCreated on the creation path.
        emit ITMPEvaluator.EvaluatorAssigned(taskId, cfg.evaluator, cfg.evaluatorStake);
    }

    // -------------------------------------------------------------------------
    // Hook helpers — low-level
    // -------------------------------------------------------------------------

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

    /// @notice The effective minimum appeal window: the admin-configured value, or the compiled
    ///         default when it has never been set. A stored zero is treated as unset rather than
    ///         as "no minimum", because a zero floor is exactly the hole this guard exists to
    ///         close -- and every diamond upgraded into rev017 starts with a zero in this slot.
    ///         AdminFacet's setter rejects zero for the same reason, so unset and
    ///         deliberately-zero are not states that can be confused.
    function _minAppealWindowSecs(AppStorage storage s) internal view returns (uint32) {
        uint32 configured = s.minAppealWindowSecs;
        return configured == 0 ? DEFAULT_MIN_APPEAL_WINDOW_SECS : configured;
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
        uint256 gasStipend = HOOK_GAS_STIPEND;
        ret = new bytes(maxCopy);
        assembly {
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
                assembly {
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
        _dispatchAfterHooks(hooks, abi.encodeCall(ITMPHook.onComplete, (taskId, _buildContext(taskId, s), verdict)));
    }

    function _onForfeitHooks(bytes32 taskId, address forfeiter, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        _dispatchAfterHooks(hooks, abi.encodeCall(ITMPHook.onForfeit, (taskId, _buildContext(taskId, s), forfeiter)));
    }

    function _onCancelHooks(bytes32 taskId, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        _dispatchAfterHooks(hooks, abi.encodeCall(ITMPHook.onCancel, (taskId, _buildContext(taskId, s))));
    }

    function _onExpireHooks(bytes32 taskId, AppStorage storage s) internal {
        address[] memory hooks = _resolveHooks(taskId, s);
        _dispatchAfterHooks(hooks, abi.encodeCall(ITMPHook.onExpire, (taskId, _buildContext(taskId, s))));
    }
}
