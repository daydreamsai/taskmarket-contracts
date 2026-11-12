// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibHooks } from "../libraries/LibHooks.sol";
import { LibHooksV2 } from "../libraries/LibHooksV2.sol";
import { LibSettlement } from "../libraries/LibSettlement.sol";
import { LibTaskLimits } from "../libraries/LibTaskLimits.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";
import { ITMPHookV2 } from "../interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../interfaces/ITMPHooksV2.sol";
import { ITMPHookDispatch } from "../interfaces/ITMPHookDispatch.sol";
import { IPGTRForwarder } from "../interfaces/IPGTRForwarder.sol";
import { TMP_BOUNTY, TMP_BENCHMARK } from "../interfaces/ITMPModes.sol";

/// @title HookDispatchFacet -- Task Hook V2 dispatch
/// @notice Reached only through a call from the diamond to itself (LibHooks). Typed before- and
///         after-callbacks by capability, a per-capability gas budget, codehash binding, sequence
///         numbers and at most one transforming hook's validated settlement result. Every terminal
///         transition also writes the settlement record here. Rev030: V1 hooks are retired. A task
///         created before the rev028 cut (dispatch version 0) has no V2 attachments, so every
///         callback is a no-op for it and its settlement still completes.
contract HookDispatchFacet is ITMPHookDispatch {
    struct Accept {
        bool changed;
        ITMPCore.Award[] awards;
        uint16 hookFeeBps;
        address feeHook;
        uint256 hookSpent; // gas the callbacks of this dispatch have consumed
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    // -------------------------------------------------------------------------
    // Creation
    // -------------------------------------------------------------------------

    // Complexity is inherent: defaults and requester hooks, config decoding, composition rules.
    // solhint-disable-next-line code-complexity
    function hookAttach(bytes32 taskId, address[] calldata hooks, bytes calldata data) external onlySelf {
        AppStorage storage s = LibAppStorage.appStorage();
        s.taskHookVersion[taskId] = LibHooksV2.VERSION_V2;
        uint256 dLen = s.defaultHooksV2.length;
        uint256 rLen = hooks.length;
        uint256 n = dLen + rLen;
        if (n == 0) return;
        uint256 cap = LibTaskLimits.maxHooks(s);
        if (cap > LibHooksV2.MAX_HOOKS_V2) cap = LibHooksV2.MAX_HOOKS_V2;
        if (n > cap) revert ITMPCore.TooManyHooks();

        bytes[] memory configs = new bytes[](n);
        if (rLen > 0 && data.length > 0) {
            bytes[] memory given = abi.decode(data, (bytes[]));
            if (given.length != rLen) revert ITMPHooksV2.HookIncompatible(uint8(dLen), LibHooksV2.R_CONFIG);
            for (uint256 i; i < rLen; ++i) {
                configs[dLen + i] = given[i];
            }
        }

        ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
        bool transforming = false;
        for (uint256 i; i < n; ++i) {
            ITMPHookV2.Attachment memory a;
            if (i < dLen) {
                a = s.defaultHooksV2[i];
                if (a.hook.codehash != a.codehash) revert ITMPHooksV2.HookCodeChanged(uint8(i));
            } else {
                address h = hooks[i - dLen];
                for (uint256 j; j < i; ++j) {
                    if (list[j].hook == h) revert ITMPCore.DuplicateHookAddress();
                }
                a = inspect(s, h, i);
            }
            a.configHash = keccak256(configs[i]);
            if (a.transforming) {
                if (transforming) revert ITMPHooksV2.MultipleTransformingHooks();
                transforming = true;
            }
            list.push(a);
            emit ITMPHooksV2.HookAttached(taskId, uint8(i), a.hook, a.capabilities, a.codehash, configs[i]);
        }
        if (transforming) _requireNeutralAppeal(s, taskId, list);

        ITMPHookV2.TaskContextV2 memory ctx = _ctx(s, taskId, false);
        bytes memory d = _data(taskId, LibHooksV2.A_CREATE);
        for (uint256 i; i < n; ++i) {
            if (list[i].capabilities & 1 == 0) continue;
            _callBefore(
                s, taskId, i, LibHooksV2.A_CREATE, abi.encodeCall(ITMPHookV2.beforeCreate, (taskId, ctx, configs[i], d))
            );
        }
    }

    /// @dev Rev030: a task with a transforming hook keeps a neutral appeal open. No hook may veto an
    ///      appeal, and an evaluator, if the task has one, must come with a dispute resolver. The
    ///      evaluator terms are applied before the hooks at creation, so they are checked here;
    ///      LibTaskMarket._applyEvaluatorConfig checks the same rule for a later assignEvaluator.
    function _requireNeutralAppeal(AppStorage storage s, bytes32 taskId, ITMPHookV2.Attachment[] storage list)
        private
        view
    {
        uint32 appealBit = uint32(1) << LibHooksV2.A_APPEAL;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].capabilities & appealBit != 0) revert ITMPHooksV2.TransformingHookWithAppealHook();
        }
        ITMPCore.TaskEvaluatorConfig storage cfg = s.taskEvaluatorConfigs[taskId];
        if (cfg.evaluator != address(0) && cfg.disputeResolver == address(0)) {
            revert ITMPHooksV2.TransformingHookNeedsDisputeResolver();
        }
    }

    function hookReadManifest(address hook, uint8 index) external view onlySelf returns (ITMPHookV2.Attachment memory) {
        return inspect(LibAppStorage.appStorage(), hook, index);
    }

    /// @notice Reads and checks a hook's V2 manifest.
    function inspect(AppStorage storage s, address h, uint256 index)
        internal
        view
        returns (ITMPHookV2.Attachment memory a)
    {
        uint256 codeLen = h.code.length;
        if (h == address(0) || codeLen == 0) revert ITMPCore.InvalidHookAddress();
        uint8 idx = uint8(index);
        // Rev030: an EIP-7702 delegated account's code is the 23-byte designator 0xef0100 || address,
        // which its key holder can re-point at will. The pinned codehash would then stop matching
        // and every vetoable callback would revert, so such an account is never a hook.
        if (codeLen == 23 && bytes3(h.code) == 0xef0100) revert ITMPHooksV2.HookDelegatedAccount(idx);
        if (!_supports(h, type(ITMPHookV2).interfaceId)) {
            if (_supports(h, type(ITMPHook).interfaceId)) revert ITMPHooksV2.HookV1Retired(idx);
            revert ITMPHooksV2.HookIncompatible(idx, LibHooksV2.R_INTERFACE);
        }
        (bool ok1, uint256 caps) = _staticWord(h, abi.encodeCall(ITMPHookV2.hookCapabilities, ()));
        (bool ok2, uint256 minV) = _staticWord(h, abi.encodeCall(ITMPHookV2.minDiamondVersion, ()));
        if (!ok1 || !ok2 || caps > type(uint32).max || minV > type(uint16).max) {
            revert ITMPHooksV2.HookIncompatible(idx, LibHooksV2.R_MANIFEST);
        }
        if (minV > s.diamondVersion) revert ITMPHooksV2.HookIncompatible(idx, LibHooksV2.R_VERSION);
        uint32 masked = uint32(caps) & LibHooksV2.DEFINED_MASK;
        if (masked == 0) revert ITMPHooksV2.HookIncompatible(idx, LibHooksV2.R_CAPABILITIES);
        a.hook = h;
        a.capabilities = masked;
        a.minDiamondVersion = uint16(minV);
        a.transforming = masked & LibHooksV2.TRANSFORM_MASK != 0;
        a.codehash = h.codehash;
        if (masked & (uint32(1) << LibHooksV2.BIT_HOOK_CALL) != 0) {
            (bool ok3, uint256 roles) = _staticWord(h, abi.encodeCall(ITMPHookV2.hookCallRoles, ()));
            if (!ok3 || roles == 0 || roles > type(uint32).max) {
                revert ITMPHooksV2.HookIncompatible(idx, LibHooksV2.R_MANIFEST);
            }
            a.callRoles = uint32(roles);
        }
    }

    // -------------------------------------------------------------------------
    // Before-callbacks
    // -------------------------------------------------------------------------

    // Complexity is inherent: one typed encoding per vetoable action.
    // solhint-disable-next-line code-complexity
    function hookBefore(bytes32 taskId, uint8 action, address who, bytes32 extra) external onlySelf {
        AppStorage storage s = LibAppStorage.appStorage();
        ITMPHookV2.TaskContextV2 memory ctx = _ctx(s, taskId, false);
        bytes memory d = _data(taskId, action);
        bytes memory cd;
        if (action == LibHooksV2.A_ASSIGN_EVALUATOR) {
            cd = abi.encodeCall(ITMPHookV2.beforeAssignEvaluator, (taskId, ctx, who, d));
        } else if (action == LibHooksV2.A_UPDATE) {
            cd = abi.encodeCall(ITMPHookV2.beforeUpdate, (taskId, ctx, d));
        } else if (action == LibHooksV2.A_CLAIM) {
            cd = abi.encodeCall(ITMPHookV2.beforeClaim, (taskId, ctx, who, d));
        } else if (action == LibHooksV2.A_SUBMIT_PITCH) {
            cd = abi.encodeCall(ITMPHookV2.beforeSubmitPitch, (taskId, ctx, who, extra, d));
        } else if (action == LibHooksV2.A_SELECT_WORKER) {
            cd = abi.encodeCall(ITMPHookV2.beforeSelectWorker, (taskId, ctx, who, d));
        } else if (action == LibHooksV2.A_SUBMIT_PROOF) {
            cd = abi.encodeCall(ITMPHookV2.beforeSubmitProof, (taskId, ctx, who, extra, d));
        } else if (action == LibHooksV2.A_SUBMIT_BID) {
            cd = abi.encodeCall(ITMPHookV2.beforeSubmitBid, (taskId, ctx, who, uint256(extra), d));
        } else if (action == LibHooksV2.A_ACCEPT_AUCTION) {
            cd = abi.encodeCall(ITMPHookV2.beforeAcceptAuction, (taskId, ctx, who, d));
        } else if (action == LibHooksV2.A_SUBMIT_WORK) {
            cd = abi.encodeCall(ITMPHookV2.beforeSubmitWork, (taskId, ctx, who, extra, d));
        } else if (action == LibHooksV2.A_REJECT_SUBMISSION) {
            cd = abi.encodeCall(ITMPHookV2.beforeRejectSubmission, (taskId, ctx, who, d));
        } else if (action == LibHooksV2.A_EVALUATE) {
            cd = abi.encodeCall(ITMPHookV2.beforeEvaluate, (taskId, ctx, s.taskVerdicts[taskId], d));
        } else if (action == LibHooksV2.A_APPEAL) {
            cd = abi.encodeCall(ITMPHookV2.beforeAppeal, (taskId, ctx, who, d));
        } else if (action == LibHooksV2.A_CANCEL) {
            cd = abi.encodeCall(ITMPHookV2.beforeCancel, (taskId, ctx, d));
        } else if (action == LibHooksV2.A_RATE) {
            cd = abi.encodeCall(ITMPHookV2.beforeRate, (taskId, ctx, who, d));
        } else {
            return;
        }
        ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
        uint32 bit = uint32(1) << action;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].capabilities & bit == 0) continue;
            _callBefore(s, taskId, i, action, cd);
        }
    }

    function _callBefore(AppStorage storage s, bytes32 taskId, uint256 i, uint8 action, bytes memory cd) private {
        ITMPHookV2.Attachment storage a = s.taskHooksV2[taskId][i];
        address hook = a.hook;
        if (hook.codehash != a.codehash) revert ITMPHooksV2.HookCodeChanged(uint8(i));
        uint256 budget = _budget(s, action);
        _requireGas(budget);
        (bool ok, uint256 size, bytes memory ret) = _call(hook, budget, cd, 256);
        if (!ok || size != 32 || _word(ret) != bytes32(_selector(cd))) {
            revert ITMPHooksV2.HookRejected(uint8(i), action, ret);
        }
    }

    function hookCall(bytes32 taskId, uint8 index, address caller, uint32 roles, bytes calldata data)
        external
        onlySelf
    {
        AppStorage storage s = LibAppStorage.appStorage();
        _callBefore(
            s,
            taskId,
            index,
            LibHooksV2.A_HOOK_CALL,
            abi.encodeCall(ITMPHookV2.onCall, (taskId, _ctx(s, taskId, false), caller, roles, data))
        );
    }

    // -------------------------------------------------------------------------
    // Accept: the settlement step
    // -------------------------------------------------------------------------

    function hookAcceptV2(
        bytes32 taskId,
        ITMPCore.Verdict calldata verdict,
        bool vetoable,
        bool disputed,
        uint256 budget
    ) external onlySelf returns (bool changed, ITMPCore.Award[] memory awards, uint16 hookFeeBps, address feeHook) {
        AppStorage storage s = LibAppStorage.appStorage();
        ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
        uint256 n = list.length;
        if (n == 0) return (false, awards, 0, address(0));
        // currentState is the status before the accept writes Accepted, on every accept path (the
        // facets snapshot it first); a dispute resolution shows Disputed.
        ITMPHookV2.TaskContextV2 memory ctx = _ctx(s, taskId, disputed);
        if (!disputed) ctx.currentState = ctx.priorStatus;
        bytes memory cd = abi.encodeCall(
            ITMPHookV2.beforeAccept,
            (taskId, ctx, verdict, _data(taskId, disputed ? LibHooksV2.A_RESOLVE_DISPUTE : LibHooksV2.A_ACCEPT))
        );
        uint32 bit = uint32(1) << LibHooksV2.A_ACCEPT;
        Accept memory r = Accept({ changed: false, awards: awards, hookFeeBps: 0, feeHook: address(0), hookSpent: 0 });
        for (uint256 i; i < n; ++i) {
            ITMPHookV2.Attachment memory a = list[i];
            if (a.capabilities & bit == 0 && !a.transforming) continue;
            _acceptOne(s, taskId, i, n, a, cd, vetoable, budget, r);
        }
        return (r.changed, r.awards, r.hookFeeBps, r.feeHook);
    }

    function _acceptOne(
        AppStorage storage s,
        bytes32 taskId,
        uint256 i,
        uint256 n,
        ITMPHookV2.Attachment memory a,
        bytes memory cd,
        bool vetoable,
        uint256 budget,
        Accept memory r
    ) private {
        uint8 action = LibHooksV2.A_ACCEPT;
        if (vetoable && a.hook.codehash != a.codehash) revert ITMPHooksV2.HookCodeChanged(uint8(i));
        uint256 gasBudget = _budget(s, action);
        if (!vetoable && _skipExit(gasBudget, r.hookSpent, n - i)) {
            // Best effort: a dispute ruling or a settlement after expiry never waits on hook gas,
            // and the hooks of one exit share MAX_EXIT_HOOK_GAS.
            _failed(taskId, i, a.hook, action, LibHooksV2.PHASE_BEFORE, LibHooksV2.FAIL_GAS, "");
            return;
        }
        _requireGas(gasBudget);
        // A settlement result applies only on the vetoable accept path, where the codehash was just
        // checked; a dispute ruling or a settlement after expiry stands as the core computed it.
        bool applies = a.transforming && vetoable;
        uint256 maxCopy = applies ? 32 * (6 + 3 * LibTaskMarket.MAX_SUBMISSION_WINNERS) : 256;
        uint256 g = gasleft();
        (bool ok, uint256 size, bytes memory ret) = _call(a.hook, gasBudget, cd, maxCopy);
        r.hookSpent += g - gasleft();
        if (!ok || size < 32 || _word(ret) != bytes32(ITMPHookV2.beforeAccept.selector)) {
            if (vetoable) revert ITMPHooksV2.HookRejected(uint8(i), action, ret);
            _failed(
                taskId, i, a.hook, action, LibHooksV2.PHASE_BEFORE, ok ? LibHooksV2.FAIL_REJECTED : _class(size), ret
            );
            return;
        }
        if (!applies) return;
        (bool valid, ITMPCore.Award[] memory awards, uint16 feeBps) = _decodeResult(s, taskId, a, ret, size, budget);
        if (!valid) {
            if (vetoable) revert ITMPHooksV2.HookResultInvalid(uint8(i));
            _failed(taskId, i, a.hook, action, LibHooksV2.PHASE_BEFORE, LibHooksV2.FAIL_RESULT_INVALID, ret);
            return;
        }
        if (awards.length == 0 && feeBps == 0) return;
        r.changed = true;
        r.awards = awards;
        r.hookFeeBps = feeBps;
        r.feeHook = a.hook;
        emit ITMPHooksV2.HookSettlementApplied(taskId, uint8(i), uint16(awards.length), feeBps);
    }

    /// @dev Decodes and validates `(bytes4, SettlementDelta, Award[])` without trusting the
    ///      encoding: any malformed word makes the result invalid rather than reverting. An empty
    ///      award list with awardCount zero means "keep the core awards" (returned as a zero-length
    ///      array, which the facet reads as unchanged awards).
    function _decodeResult(
        AppStorage storage s,
        bytes32 taskId,
        ITMPHookV2.Attachment memory a,
        bytes memory ret,
        uint256 size,
        uint256 budget
    ) private view returns (bool valid, ITMPCore.Award[] memory awards, uint16 feeBps) {
        if (size < 192 || size > ret.length) return (false, awards, 0);
        bytes4 sel = ITMPHookV2.beforeAccept.selector;
        if (_wordAt(ret, 2) != bytes32(sel)) return (false, awards, 0);
        uint256 count = uint256(_wordAt(ret, 3));
        uint256 bps = uint256(_wordAt(ret, 4));
        if (uint256(_wordAt(ret, 5)) != 160) return (false, awards, 0);
        uint256 len = uint256(_wordAt(ret, 6));
        if (count != len || len > LibTaskMarket.MAX_SUBMISSION_WINNERS || size != 192 + 96 * len) {
            return (false, awards, 0);
        }
        if (bps > s.maxHookFeeBps || (bps > 0 && a.capabilities & (uint32(1) << LibHooksV2.BIT_HOOK_FEE) == 0)) {
            return (false, awards, 0);
        }
        if (len > 0 && a.capabilities & (uint32(1) << LibHooksV2.BIT_REALLOCATE) == 0) return (false, awards, 0);
        if (uint256(s.tasks[taskId].feeBps) + bps > 10000) return (false, awards, 0);
        awards = new ITMPCore.Award[](len);
        uint256 total = 0;
        for (uint256 k; k < len; ++k) {
            uint256 w = uint256(_wordAt(ret, 7 + 3 * k));
            uint256 amt = uint256(_wordAt(ret, 8 + 3 * k));
            uint256 rank = uint256(_wordAt(ret, 9 + 3 * k));
            if (w > type(uint160).max || rank > type(uint16).max) return (false, awards, 0);
            address worker = address(uint160(w));
            if (amt > 0) {
                if (!_eligible(s, taskId, worker)) return (false, awards, 0);
                for (uint256 j; j < k; ++j) {
                    if (awards[j].worker == worker && awards[j].amount > 0) return (false, awards, 0);
                }
            }
            total += amt;
            if (total > budget) return (false, awards, 0);
            awards[k] = ITMPCore.Award({ worker: worker, amount: amt, rank: uint16(rank) });
        }
        return (true, awards, uint16(bps));
    }

    /// @dev The canonical eligibility set: a worker who submitted on a Bounty or Benchmark, or the
    ///      locked worker of a Claim, Pitch or Auction.
    function _eligible(AppStorage storage s, bytes32 taskId, address worker) private view returns (bool) {
        if (worker == address(0)) return false;
        ITMPCore.Task storage t = s.tasks[taskId];
        if (t.mode == TMP_BOUNTY || t.mode == TMP_BENCHMARK) {
            return s.taskSubmissionHashes[taskId][worker].length > 0;
        }
        return worker == t.worker;
    }

    // -------------------------------------------------------------------------
    // After-callbacks
    // -------------------------------------------------------------------------

    function hookObserve(bytes32 taskId, uint8 action, bool vetoable) external onlySelf {
        AppStorage storage s = LibAppStorage.appStorage();
        if (s.taskHooksV2[taskId].length == 0) return;
        bytes memory d = LibHooksV2.actionData();
        bytes memory cd = abi.encodeCall(ITMPHookV2.afterAction, (taskId, _ctx(s, taskId, false), action, d, uint64(0)));
        // The seq word is the last head word, before the actionData tail (length word plus data).
        uint256 seqOffset = cd.length - 32 - (d.length % 32 == 0 ? d.length : d.length + 32 - (d.length % 32)) - 32;
        _after(s, taskId, action, LibHooksV2.BIT_OBSERVER, vetoable, cd, seqOffset);
    }

    function hookSettle(bytes32 taskId, uint8 kind, ITMPCore.Verdict calldata verdict, address who) external onlySelf {
        AppStorage storage s = LibAppStorage.appStorage();
        // KIND_STRICT marks a non-exit action (an accept, a cancel, a rejected delivery): every
        // after-callback's budget is required up front, so a gas estimate includes it. Exits stay
        // best effort and never revert for hook gas.
        bool strict = kind & LibHooksV2.KIND_STRICT != 0;
        kind &= ~LibHooksV2.KIND_STRICT;
        // A forfeit that also ends the task (a rejected delivery refunded to the requester) writes
        // the record like any other terminal transition.
        ITMPCore.TaskStatus st = s.tasks[taskId].status;
        bool terminal = st == ITMPCore.TaskStatus.Accepted || st == ITMPCore.TaskStatus.Expired
            || st == ITMPCore.TaskStatus.Cancelled;
        ITMPHookV2.SettlementAmounts memory amounts =
            terminal ? LibSettlement.finalize(s, taskId) : LibSettlement.forfeit(s, taskId);

        // A task without V2 attachments (every task created before the rev028 cut included) has no
        // hook to call: its settlement record is written above and nothing else runs.
        if (s.taskHooksV2[taskId].length == 0) return;
        ITMPHookV2.TaskContextV2 memory ctx = _ctx(s, taskId, false);
        bytes memory cd;
        uint8 bit;
        uint8 action;
        if (kind == LibHooksV2.KIND_COMPLETE) {
            cd = abi.encodeCall(ITMPHookV2.afterComplete, (taskId, ctx, amounts, uint64(0)));
            (bit, action) = (LibHooksV2.BIT_AFTER_COMPLETE, LibHooksV2.A_ACCEPT);
        } else if (kind == LibHooksV2.KIND_CANCEL) {
            cd = abi.encodeCall(ITMPHookV2.afterCancel, (taskId, ctx, amounts, uint64(0)));
            (bit, action) = (LibHooksV2.BIT_AFTER_CANCEL, LibHooksV2.A_CANCEL);
        } else if (kind == LibHooksV2.KIND_EXPIRE) {
            cd = abi.encodeCall(ITMPHookV2.afterExpire, (taskId, ctx, amounts, uint64(0)));
            (bit, action) = (LibHooksV2.BIT_AFTER_EXPIRE, LibHooksV2.A_EXPIRE);
        } else {
            cd = abi.encodeCall(ITMPHookV2.afterForfeit, (taskId, ctx, amounts, uint64(0)));
            (bit, action) = (LibHooksV2.BIT_AFTER_FORFEIT, LibHooksV2.A_FORFEIT);
        }
        // Terminal and forfeit after-callbacks never compare codehashes and their failures are
        // swallowed. seq is the last argument word.
        if (strict) _requireGasForAll(s, taskId, bit);
        _after(s, taskId, action, bit, false, cd, cd.length - 32);
    }

    function _after(
        AppStorage storage s,
        bytes32 taskId,
        uint8 action,
        uint8 bit,
        bool vetoable,
        bytes memory cd,
        uint256 seqOffset
    ) private {
        ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
        uint256 n = list.length;
        uint32 mask = uint32(1) << bit;
        // An observer callback is watch-only: it never blocks the action it watches for gas.
        bool bestEffort = !vetoable || bit == LibHooksV2.BIT_OBSERVER;
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            ITMPHookV2.Attachment storage a = list[i];
            if (a.capabilities & mask == 0) continue;
            address hook = a.hook;
            if (vetoable && hook.codehash != a.codehash) revert ITMPHooksV2.HookCodeChanged(uint8(i));
            uint64 seq = s.hookCallSeq[taskId][uint8(i)];
            s.hookCallSeq[taskId][uint8(i)] = seq + 1;
            // Memory-safe: overwrites one word inside cd.
            assembly ("memory-safe") {
                mstore(add(add(cd, 32), seqOffset), seq)
            }
            uint256 budget = _budget(s, bit);
            if (bestEffort && _skipExit(budget, vetoable ? 0 : spent, n - i)) {
                // A best-effort after-callback (terminal exits and observers included) never blocks
                // the action for gas: it is skipped, reported, and its sequence number is spent, so the hook
                // can detect the gap and reconcile from the settlement record.
                emit ITMPHooksV2.HookCallFailedV2(
                    taskId, uint8(i), hook, action, LibHooksV2.PHASE_AFTER, LibHooksV2.FAIL_GAS, bytes32(0), seq
                );
                continue;
            }
            _requireGas(budget);
            uint256 g = gasleft();
            (bool ok, uint256 size, bytes memory ret) = _call(hook, budget, cd, 256);
            spent += g - gasleft();
            if (!ok) {
                emit ITMPHooksV2.HookCallFailedV2(
                    taskId, uint8(i), hook, action, LibHooksV2.PHASE_AFTER, _class(size), keccak256(ret), seq
                );
            }
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _ctx(AppStorage storage s, bytes32 taskId, bool disputed)
        private
        view
        returns (ITMPHookV2.TaskContextV2 memory c)
    {
        ITMPCore.Task storage t = s.tasks[taskId];
        ITMPCore.TaskEvaluatorConfig storage ec = s.taskEvaluatorConfigs[taskId];
        c.taskId = taskId;
        c.actor = _actor(s);
        c.requester = t.requester;
        c.worker = t.worker;
        c.evaluator = ec.evaluator;
        c.disputeResolver = ec.disputeResolver;
        c.paymentToken = address(s.usdcToken);
        c.reward = t.reward;
        c.evaluatorStake = ec.evaluatorStake;
        c.evaluatorFeeBps = ec.evaluatorFeeBps;
        c.feeBps = t.feeBps;
        c.mode = t.mode;
        c.priorStatus = ITMPCore.TaskStatus(LibHooksV2.prior(taskId, uint8(t.status)));
        c.currentState = disputed ? ITMPCore.TaskStatus.Disputed : t.status;
        c.expiryTime = uint64(t.expiryTime);
        c.projectId = s.taskProjects[taskId];
        c.terms = s.taskTerms[taskId];
    }

    /// @dev The caller of the outermost action, resolved through a trusted forwarder.
    function _actor(AppStorage storage s) private view returns (address a) {
        a = LibHooksV2.actorRaw();
        if (a != address(0) && s.trustedForwarders[a]) a = IPGTRForwarder(a).pgtrSender();
    }

    /// @dev The per-action data of the call under way; emits its hash once per action.
    function _data(bytes32 taskId, uint8 action) private returns (bytes memory d) {
        d = LibHooksV2.actionData();
        if (d.length > 0) emit ITMPHooksV2.HookActionData(taskId, action, keccak256(d));
    }

    function _budget(AppStorage storage s, uint8 bit) private view returns (uint256) {
        uint256 v = s.hookCapabilityGas[bit];
        if (v != 0) return v;
        // Unset reads as this chain's hook gas stipend (rev026), so a chain that raised it for its
        // storage costs (Tempo) gives V2 hooks that headroom, and never below the V2 floor.
        uint256 stipend = LibHooks._hookGasStipend(s);
        return stipend > LibHooksV2.GAS_FLOOR ? stipend : LibHooksV2.GAS_FLOOR;
    }

    /// @dev EIP-150: a call forwards at most 63/64 of the gas left, so demand the budget plus margin.
    function _requireGas(uint256 budget) private view {
        if (!_hasGas(budget)) revert ITMPHooksV2.InsufficientGasForHooks();
    }

    /// @dev The gas every hook declaring `bit` would be given, demanded before the first call.
    function _requireGasForAll(AppStorage storage s, bytes32 taskId, uint8 bit) private view {
        ITMPHookV2.Attachment[] storage list = s.taskHooksV2[taskId];
        uint32 mask = uint32(1) << bit;
        uint256 per = (_budget(s, bit) * 64) / 63 + LibHooksV2.GAS_MARGIN;
        uint256 total = 0;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].capabilities & mask != 0) total += per;
        }
        // Capped, so that however many hooks a task carries the action stays reachable under a
        // chain's per-transaction gas limit; callbacks beyond the cap are best effort.
        if (total > LibHooksV2.MAX_STRICT_HOOK_GAS) total = LibHooksV2.MAX_STRICT_HOOK_GAS;
        if (gasleft() < total) revert ITMPHooksV2.InsufficientGasForHooks();
    }

    /// @dev Whether a best-effort callback is skipped: the gas for its budget (and for skipping the
    ///      `remaining` hooks after it) is not there, or the callbacks of this dispatch have already
    ///      spent `spent` and its budget would take them past MAX_EXIT_HOOK_GAS.
    function _skipExit(uint256 budget, uint256 spent, uint256 remaining) private view returns (bool) {
        if (gasleft() < (budget * 64) / 63 + LibHooksV2.GAS_MARGIN + remaining * LibHooksV2.SKIP_RESERVE) return true;
        return spent != 0 && spent + budget > LibHooksV2.MAX_EXIT_HOOK_GAS;
    }

    function _hasGas(uint256 budget) private view returns (bool) {
        return gasleft() >= (budget * 64) / 63 + LibHooksV2.GAS_MARGIN;
    }

    function _class(uint256 size) private pure returns (uint8) {
        return size == 0 ? LibHooksV2.FAIL_EMPTY_REVERT : LibHooksV2.FAIL_REVERT;
    }

    function _failed(bytes32 taskId, uint256 i, address hook, uint8 action, uint8 phase, uint8 cls, bytes memory ret)
        private
    {
        emit ITMPHooksV2.HookCallFailedV2(taskId, uint8(i), hook, action, phase, cls, keccak256(ret), 0);
    }

    /// @dev Bounded call: forwards `gasBudget`, copies at most `maxCopy` bytes of return data and
    ///      reports the full return size, so an oversized return can neither exhaust the caller's
    ///      memory nor pass as valid.
    function _call(address hook, uint256 gasBudget, bytes memory cd, uint256 maxCopy)
        private
        returns (bool ok, uint256 size, bytes memory ret)
    {
        ret = new bytes(maxCopy);
        // Memory-safe: reads cd and writes only inside ret, allocated at maxCopy bytes, then shortens
        // ret's length in place.
        assembly ("memory-safe") {
            ok := call(gasBudget, hook, 0, add(cd, 0x20), mload(cd), 0, 0)
            size := returndatasize()
            let copyLen := size
            if gt(copyLen, maxCopy) { copyLen := maxCopy }
            returndatacopy(add(ret, 0x20), 0, copyLen)
            mstore(ret, copyLen)
        }
    }

    function _staticWord(address h, bytes memory cd) private view returns (bool ok, uint256 v) {
        uint256 gasBudget = LibHooksV2.MANIFEST_GAS;
        uint256 size;
        // Memory-safe: writes the scratch word only.
        assembly ("memory-safe") {
            ok := staticcall(gasBudget, h, add(cd, 0x20), mload(cd), 0, 0)
            size := returndatasize()
            if and(ok, eq(size, 32)) {
                returndatacopy(0x00, 0, 32)
                v := mload(0x00)
            }
        }
        ok = ok && size == 32;
    }

    function _supports(address h, bytes4 id) private view returns (bool) {
        (bool ok, uint256 v) = _staticWord(h, abi.encodeCall(IERC165.supportsInterface, (id)));
        return ok && v == 1;
    }

    function _selector(bytes memory cd) private pure returns (bytes4 sel) {
        // Memory-safe: reads cd's first word.
        assembly ("memory-safe") {
            sel := mload(add(cd, 0x20))
        }
    }

    function _word(bytes memory ret) private pure returns (bytes32 w) {
        if (ret.length < 32) return bytes32(0);
        // Memory-safe: reads ret's first word.
        assembly ("memory-safe") {
            w := mload(add(ret, 0x20))
        }
    }

    /// @dev The k-th word of ret, counted from 1.
    function _wordAt(bytes memory ret, uint256 k) private pure returns (bytes32 w) {
        if (ret.length < 32 * k) return bytes32(0);
        // Memory-safe: reads inside ret.
        assembly ("memory-safe") {
            w := mload(add(ret, mul(k, 0x20)))
        }
    }
}
