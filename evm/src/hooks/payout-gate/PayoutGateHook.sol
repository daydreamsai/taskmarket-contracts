// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTMPHookV2 } from "../base/BaseTMPHookV2.sol";
import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { ITMPHookV2 } from "../../interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../../interfaces/ITMPHooksV2.sol";

/// @title PayoutGateHook -- holds a task's payout until another task has paid out
/// @notice One shared Task Hook V2 hook per chain (rev028). A task attaches it at creation with the
///         configuration `abi.encode(bytes32 gatingTaskId, uint64 deadline, bytes32[] gatesTaskIds)`.
///         Two modes:
///         - Gated task (gatesTaskIds empty): the gate holds this task's payout. A zero
///           gatingTaskId means the gating task is linked later.
///         - Gating task (gatesTaskIds non-empty, at most MAX_GATES_PER_TASK; gatingTaskId and
///           deadline zero): this new task becomes the gating task of each listed task, linked
///           automatically at creation. Each listed task must carry this gate with no gating task
///           yet, must not have settled, and must have the same requester as the new task, so a
///           stranger's task can never open someone else's gate. The new task itself holds nothing.
///         A human sign-off is modelled as a gating task.
///         The gate opens when ANY of these holds:
///         - the gating task has ended Accepted, read from the diamond's settlement record;
///         - the deadline (fixed at creation) has passed, so a stuck or failed gating task cannot
///           trap the funds;
///         - the call settles a dispute (the diamond shows `Disputed` to `beforeAccept`).
///         Until then it vetoes acceptSubmission, acceptSubmissions and finalizeVerdict. It never
///         holds the non-vetoable exits (expiry refund, forfeit, timeouts, lapsed review, finalize
///         after expiry). A gating task left unset at creation may be linked once, later, by the
///         gated task's requester through the diamond's callTaskHook, so one task's payout can wait
///         for another's.
/// @dev Must not be deployed on a chain until that chain's diamond runs rev028.
contract PayoutGateHook is BaseTMPHookV2 {
    /// @notice Capability bits: before Create (0) and before Accept (13). Check only, no result power.
    uint32 public constant CAPABILITIES = (uint32(1) << 0) | (uint32(1) << 13) | (uint32(1) << 30);
    /// @notice The deadline must be at least this far after creation.
    uint64 public constant MIN_DEADLINE_WINDOW = 1 hours;
    /// @notice The deadline may be at most this far after creation.
    uint64 public constant MAX_DEADLINE_WINDOW = 180 days;
    /// @notice The most tasks one gating task may gate.
    uint256 public constant MAX_GATES_PER_TASK = 16;

    struct Gate {
        uint64 deadline;
        bool set;
        bytes32 gatingTaskId;
    }

    mapping(bytes32 => Gate) private _gates;

    event PayoutGateSet(bytes32 indexed taskId, bytes32 gatingTaskId, uint64 deadline);
    event PayoutGateLinked(bytes32 indexed taskId, bytes32 indexed gatingTaskId);

    error PayoutGate__InvalidConfig();
    error PayoutGate__DeadlineOutOfWindow(uint64 deadline, uint64 earliest, uint64 latest);
    error PayoutGate__AlreadySet();
    error PayoutGate__UnknownTask();
    error PayoutGate__NotRequester();
    error PayoutGate__AlreadyLinked();
    error PayoutGate__InvalidGatingTask();
    error PayoutGate__TaskSettled();
    error PayoutGate__Closed();
    error PayoutGate__RequesterMismatch();
    error PayoutGate__NotGated();

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return CAPABILITIES;
    }

    /// @notice The gate of `taskId`. A task with no gate here reads all zero.
    function gateOf(bytes32 taskId)
        external
        view
        returns (bytes32 gatingTaskId, uint64 deadline, bool gatingPaid, bool open)
    {
        Gate storage g = _gates[taskId];
        gatingPaid = _gatingPaid(g.gatingTaskId);
        return (g.gatingTaskId, g.deadline, gatingPaid, g.set && (gatingPaid || block.timestamp >= g.deadline));
    }

    /// @notice Whether the gate of `taskId` is open now, outside a dispute resolution. False for a
    ///         task with no gate here, matching gateOf.
    function isOpen(bytes32 taskId) public view returns (bool) {
        Gate storage g = _gates[taskId];
        return g.set && (block.timestamp >= g.deadline || _gatingPaid(g.gatingTaskId));
    }

    /// @notice Only the gated task's requester may call the gate (the late link).
    function hookCallRoles() external pure override returns (uint32) {
        return ROLE_REQUESTER;
    }

    /// @notice Links the task whose payout opens this gate, once, when none was set at creation.
    ///         Reached only through the diamond's callTaskHook, which has checked the caller holds
    ///         the requester role and the task has not settled. `data` is
    ///         `abi.encode(bytes32 gatingTaskId)`. The gating task must exist, not be the gated
    ///         task, not have settled, and have the same requester, as a link made at creation.
    function onCall(bytes32 taskId, TaskContextV2 calldata ctx, address caller, uint32 roles, bytes calldata data)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        if (!_hasRole(roles, ROLE_REQUESTER) || caller != ctx.requester) revert PayoutGate__NotRequester();
        if (data.length != 32) revert PayoutGate__InvalidConfig();
        bytes32 gatingTaskId = abi.decode(data, (bytes32));
        Gate storage g = _gates[taskId];
        if (!g.set) revert PayoutGate__UnknownTask();
        if (g.gatingTaskId != bytes32(0)) revert PayoutGate__AlreadyLinked();
        _requireGatingTask(taskId, gatingTaskId);
        if (ITMPCore(diamond).getTask(gatingTaskId).requester != ctx.requester) {
            revert PayoutGate__RequesterMismatch();
        }
        g.gatingTaskId = gatingTaskId;
        emit PayoutGateLinked(taskId, gatingTaskId);
        return this.onCall.selector;
    }

    function beforeCreate(bytes32 taskId, TaskContextV2 calldata ctx, bytes calldata config, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        (bytes32 gatingTaskId, uint256 deadlineWord, bytes32[] memory gatesTaskIds) =
            abi.decode(config, (bytes32, uint256, bytes32[]));
        if (deadlineWord > type(uint64).max) revert PayoutGate__InvalidConfig();
        if (gatesTaskIds.length > 0) {
            if (gatingTaskId != bytes32(0) || deadlineWord != 0 || gatesTaskIds.length > MAX_GATES_PER_TASK) {
                revert PayoutGate__InvalidConfig();
            }
            for (uint256 i; i < gatesTaskIds.length; ++i) {
                _linkAsGating(gatesTaskIds[i], taskId, ctx.requester);
            }
            return this.beforeCreate.selector;
        }
        uint64 deadline = uint64(deadlineWord);
        uint64 earliest = uint64(block.timestamp) + MIN_DEADLINE_WINDOW;
        uint64 latest = uint64(block.timestamp) + MAX_DEADLINE_WINDOW;
        if (deadline < earliest || deadline > latest) {
            revert PayoutGate__DeadlineOutOfWindow(deadline, earliest, latest);
        }
        if (gatingTaskId != bytes32(0)) _requireGatingTask(taskId, gatingTaskId);
        Gate storage g = _gates[taskId];
        if (g.set) revert PayoutGate__AlreadySet();
        g.set = true;
        g.deadline = deadline;
        g.gatingTaskId = gatingTaskId;
        emit PayoutGateSet(taskId, gatingTaskId, deadline);
        return this.beforeCreate.selector;
    }

    /// @dev Gating mode: the task being created (`gatingTaskId`) becomes `gatedTaskId`'s gating task.
    function _linkAsGating(bytes32 gatedTaskId, bytes32 gatingTaskId, address requester) private {
        Gate storage g = _gates[gatedTaskId];
        if (!g.set) revert PayoutGate__NotGated();
        if (g.gatingTaskId != bytes32(0)) revert PayoutGate__AlreadyLinked();
        if (gatedTaskId == gatingTaskId) revert PayoutGate__InvalidGatingTask();
        ITMPCore.Task memory gated = ITMPCore(diamond).getTask(gatedTaskId);
        if (gated.requester != requester) revert PayoutGate__RequesterMismatch();
        if (
            gated.status == ITMPCore.TaskStatus.Accepted || gated.status == ITMPCore.TaskStatus.Expired
                || gated.status == ITMPCore.TaskStatus.Cancelled
        ) revert PayoutGate__TaskSettled();
        g.gatingTaskId = gatingTaskId;
        emit PayoutGateLinked(gatedTaskId, gatingTaskId);
    }

    function beforeAccept(bytes32 taskId, TaskContextV2 calldata ctx, ITMPCore.Verdict calldata, bytes calldata)
        external
        view
        override
        onlyDiamond
        returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory)
    {
        // A dispute resolver's ruling overrules the parties and every gate.
        // A task with no gate here (a gating-mode task) holds nothing.
        if (ctx.currentState != ITMPCore.TaskStatus.Disputed && _gates[taskId].set && !isOpen(taskId)) {
            revert PayoutGate__Closed();
        }
        return _allowAccept();
    }

    /// @dev The gating task must exist on the diamond, must not be the gated task itself, and must
    ///      not have settled. A settled task is refused because it can no longer move: one that
    ///      ended before the rev028 cut has no settlement record and could never open the gate, and
    ///      linking one that already settled would open or never open the gate at once.
    function _requireGatingTask(bytes32 taskId, bytes32 gatingTaskId) private view {
        if (gatingTaskId == bytes32(0) || gatingTaskId == taskId) revert PayoutGate__InvalidGatingTask();
        ITMPCore.Task memory gating = ITMPCore(diamond).getTask(gatingTaskId);
        if (
            gating.requester == address(0) || gating.status == ITMPCore.TaskStatus.Accepted
                || gating.status == ITMPCore.TaskStatus.Expired || gating.status == ITMPCore.TaskStatus.Cancelled
        ) revert PayoutGate__InvalidGatingTask();
    }

    /// @dev True once the gating task's settlement record shows it ended Accepted.
    function _gatingPaid(bytes32 gatingTaskId) private view returns (bool) {
        if (gatingTaskId == bytes32(0)) return false;
        ITMPHookV2.SettlementAmounts memory r = ITMPHooksV2(diamond).getTaskSettlement(gatingTaskId);
        return r.recorded && r.terminalStatus == uint8(ITMPCore.TaskStatus.Accepted);
    }
}
