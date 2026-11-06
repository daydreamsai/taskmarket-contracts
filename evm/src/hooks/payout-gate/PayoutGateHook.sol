// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTMPHookV2 } from "../base/BaseTMPHookV2.sol";
import { ITMPCore } from "../../interfaces/ITMPCore.sol";
import { ITMPHookV2 } from "../../interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../../interfaces/ITMPHooksV2.sol";
import { ITMPProject } from "../../interfaces/ITMPProject.sol";

/// @title PayoutGateHook -- holds a task's payout until another task has paid out
/// @notice A standalone Task Hook V2 hook, shared per chain and deployed on its own (like the proof
///         gate). It is not part of any diamond revision. A task attaches it at creation with the
///         configuration `abi.encode(bytes32 gatingTaskId, uint64 deadline, bytes32[] gatesTaskIds)`,
///         a gated task or a gating task. Two modes:
///         - Gated task (gatesTaskIds empty): the gate holds this task's payout. A zero
///           gatingTaskId means the gating task is linked later.
///         - Gating task (gatesTaskIds non-empty, at most MAX_GATES_PER_TASK; gatingTaskId and
///           deadline zero): this new task becomes the gating task of each listed task, linked
///           automatically at creation. Each listed task must carry this gate with no gating task
///           yet, must not have settled, and must have the same requester as the new task.
///         The gate opens when ANY of these holds:
///         - the gating task has ended Accepted, read from the diamond's settlement record;
///         - the deadline has passed, so a stuck or failed gating task cannot trap the funds;
///         - the call settles a dispute (the diamond shows `Disputed` to `beforeAccept`).
///         Until then it vetoes acceptSubmission, acceptSubmissions and finalizeVerdict. It never
///         holds the non-vetoable exits (expiry refund, forfeit, timeouts, lapsed review, finalize
///         after expiry).
///
///         What version 2 adds, all through the diamond's callTaskHook (`onCall`):
///         - Link or re-link. A gating task left unset at creation is linked once. If the linked
///           gating task later ends Cancelled or Expired, it will never pay, and the gate stays
///           CLOSED (never silently opened: a cancelled sign-off task must not release a payout it
///           was meant to hold). The caller may then link a replacement gating task, once. A second
///           failure waits for the deadline.
///         - Extend the deadline. Upward only, never past `createdAt + MAX_DEADLINE_WINDOW`, and
///           only while the gate is still closed.
///         - Caller roles. The requester (caller == ctx.requester) or a project operator holding
///           ROLE_PROJECT may call. A project operator may also link a gating task in the same
///           project as the gated task, besides one with the same requester of record.
///         The deadline is the hard backstop: no gate can hold a payout past 180 days from creation.
/// @dev Needs a diamond that dispatches Task Hook V2 (diamondVersion 28 or later). See
///      docs/extensions/ext-005-payout-gate-settlement-extension-and-project-links.md.
contract PayoutGateHook is BaseTMPHookV2 {
    /// @notice Capability bits: before Create (0), before Accept (13) and onCall (30). Check only.
    uint32 public constant CAPABILITIES = (uint32(1) << 0) | (uint32(1) << 13) | (uint32(1) << 30);
    /// @notice The deadline must be at least this far after creation.
    uint64 public constant MIN_DEADLINE_WINDOW = 1 hours;
    /// @notice The deadline may be at most this far after creation, at creation and after any extension.
    uint64 public constant MAX_DEADLINE_WINDOW = 180 days;
    /// @notice The most tasks one gating task may gate.
    uint256 public constant MAX_GATES_PER_TASK = 16;
    /// @notice onCall action: link a gating task (or re-link after the gating task failed).
    uint8 public constant CALL_LINK = 1;
    /// @notice onCall action: extend the deadline.
    uint8 public constant CALL_EXTEND = 2;

    struct Gate {
        uint64 deadline;
        bool set;
        bool relinked;
        uint64 createdAt;
        bytes32 gatingTaskId;
    }

    mapping(bytes32 => Gate) private _gates;

    event PayoutGateSet(bytes32 indexed taskId, bytes32 gatingTaskId, uint64 deadline);
    event PayoutGateLinked(bytes32 indexed taskId, bytes32 indexed gatingTaskId);
    event PayoutGateRelinked(
        bytes32 indexed taskId, bytes32 indexed previousGatingTaskId, bytes32 indexed gatingTaskId
    );
    event PayoutGateExtended(bytes32 indexed taskId, uint64 previousDeadline, uint64 deadline);

    error PayoutGate__InvalidConfig();
    error PayoutGate__DeadlineOutOfWindow(uint64 deadline, uint64 earliest, uint64 latest);
    error PayoutGate__ExtensionOutOfWindow(uint256 deadline, uint64 current, uint64 latest);
    error PayoutGate__AlreadySet();
    error PayoutGate__UnknownTask();
    error PayoutGate__NotAuthorized();
    error PayoutGate__AlreadyLinked();
    error PayoutGate__RelinkUsed();
    error PayoutGate__AlreadyOpen();
    error PayoutGate__InvalidGatingTask();
    error PayoutGate__TaskSettled();
    error PayoutGate__Closed();
    error PayoutGate__RequesterMismatch();
    error PayoutGate__NotGated();

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return CAPABILITIES;
    }

    /// @notice The gate of `taskId`. A task with no gate here reads all zero. Same outputs as
    ///         PayoutGateHook.gateOf, so one reader serves both.
    function gateOf(bytes32 taskId)
        external
        view
        returns (bytes32 gatingTaskId, uint64 deadline, bool gatingPaid, bool open)
    {
        Gate storage g = _gates[taskId];
        gatingPaid = _gatingPaid(g.gatingTaskId);
        return (g.gatingTaskId, g.deadline, gatingPaid, g.set && (gatingPaid || block.timestamp >= g.deadline));
    }

    /// @notice The gate of `taskId` with what the V2 calls need: when it was created, the latest
    ///         deadline an extension may reach, whether the gating task failed (ended Cancelled or
    ///         Expired) and whether the one re-link is used.
    function gateDetailsOf(bytes32 taskId)
        external
        view
        returns (
            bytes32 gatingTaskId,
            uint64 deadline,
            uint64 maxDeadline,
            bool gatingPaid,
            bool gatingFailed,
            bool relinked,
            bool open
        )
    {
        Gate storage g = _gates[taskId];
        gatingPaid = _gatingPaid(g.gatingTaskId);
        return (
            g.gatingTaskId,
            g.deadline,
            g.set ? g.createdAt + MAX_DEADLINE_WINDOW : 0,
            gatingPaid,
            _gatingFailed(g.gatingTaskId),
            g.relinked,
            g.set && (gatingPaid || block.timestamp >= g.deadline)
        );
    }

    /// @notice Whether the gate of `taskId` is open now, outside a dispute resolution. False for a
    ///         task with no gate here, matching gateOf.
    function isOpen(bytes32 taskId) public view returns (bool) {
        Gate storage g = _gates[taskId];
        return g.set && (block.timestamp >= g.deadline || _gatingPaid(g.gatingTaskId));
    }

    /// @notice The requester, or a project operator, may call the gate. Pinned at attach.
    function hookCallRoles() external pure override returns (uint32) {
        return ROLE_REQUESTER | ROLE_PROJECT;
    }

    /// @notice Reached only through the diamond's callTaskHook, which has checked the caller holds
    ///         a role this hook accepts and the task has not settled. `data` is
    ///         `abi.encode(uint8 action, bytes32 value)`: CALL_LINK with a gating task id, or
    ///         CALL_EXTEND with the new deadline as a uint256 word.
    function onCall(bytes32 taskId, TaskContextV2 calldata ctx, address caller, uint32 roles, bytes calldata data)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        bool asRequester = _hasRole(roles, ROLE_REQUESTER) && caller == ctx.requester;
        if (!asRequester && !_hasRole(roles, ROLE_PROJECT)) revert PayoutGate__NotAuthorized();
        if (data.length != 64) revert PayoutGate__InvalidConfig();
        (uint8 action, bytes32 value) = abi.decode(data, (uint8, bytes32));
        Gate storage g = _gates[taskId];
        if (!g.set) revert PayoutGate__UnknownTask();
        if (isOpen(taskId)) revert PayoutGate__AlreadyOpen();
        if (action == CALL_LINK) _link(g, taskId, value, ctx, roles);
        else if (action == CALL_EXTEND) _extend(g, taskId, uint256(value));
        else revert PayoutGate__InvalidConfig();
        return this.onCall.selector;
    }

    function _link(Gate storage g, bytes32 taskId, bytes32 gatingTaskId, TaskContextV2 calldata ctx, uint32 roles)
        private
    {
        bytes32 previous = g.gatingTaskId;
        if (previous != bytes32(0)) {
            // A live or paid gating task keeps its place. Only one that ended Cancelled or Expired
            // can be replaced, and only once.
            if (!_gatingFailed(previous)) revert PayoutGate__AlreadyLinked();
            if (g.relinked) revert PayoutGate__RelinkUsed();
            if (gatingTaskId == previous) revert PayoutGate__InvalidGatingTask();
        }
        _requireGatingTask(taskId, gatingTaskId);
        if (!_sameOwner(gatingTaskId, ctx, roles)) revert PayoutGate__RequesterMismatch();
        g.gatingTaskId = gatingTaskId;
        if (previous == bytes32(0)) {
            emit PayoutGateLinked(taskId, gatingTaskId);
        } else {
            g.relinked = true;
            emit PayoutGateRelinked(taskId, previous, gatingTaskId);
        }
    }

    function _extend(Gate storage g, bytes32 taskId, uint256 newDeadline) private {
        uint64 latest = g.createdAt + MAX_DEADLINE_WINDOW;
        if (newDeadline <= g.deadline || newDeadline > latest) {
            revert PayoutGate__ExtensionOutOfWindow(newDeadline, g.deadline, latest);
        }
        uint64 previous = g.deadline;
        g.deadline = uint64(newDeadline);
        emit PayoutGateExtended(taskId, previous, uint64(newDeadline));
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
        if (gatingTaskId != bytes32(0)) {
            _requireGatingTask(taskId, gatingTaskId);
        }
        Gate storage g = _gates[taskId];
        if (g.set) revert PayoutGate__AlreadySet();
        g.set = true;
        g.deadline = deadline;
        g.createdAt = uint64(block.timestamp);
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
    ///      not have settled (one that ended before the rev028 cut has no settlement record and
    ///      could never open the gate).
    function _requireGatingTask(bytes32 taskId, bytes32 gatingTaskId) private view {
        if (gatingTaskId == bytes32(0) || gatingTaskId == taskId) revert PayoutGate__InvalidGatingTask();
        ITMPCore.Task memory gating = ITMPCore(diamond).getTask(gatingTaskId);
        if (
            gating.requester == address(0) || gating.status == ITMPCore.TaskStatus.Accepted
                || gating.status == ITMPCore.TaskStatus.Expired || gating.status == ITMPCore.TaskStatus.Cancelled
        ) revert PayoutGate__InvalidGatingTask();
    }

    /// @dev A forged link can never point at someone else's task: the gating task has the gated
    ///      task's requester of record, or, for a caller holding ROLE_PROJECT, sits in the gated
    ///      task's project.
    function _sameOwner(bytes32 gatingTaskId, TaskContextV2 calldata ctx, uint32 roles) private view returns (bool) {
        if (ITMPCore(diamond).getTask(gatingTaskId).requester == ctx.requester) return true;
        return _hasRole(roles, ROLE_PROJECT) && ctx.projectId != 0
            && ITMPProject(diamond).projectOf(gatingTaskId) == ctx.projectId;
    }

    /// @dev True once the gating task's settlement record shows it ended Accepted.
    function _gatingPaid(bytes32 gatingTaskId) private view returns (bool) {
        if (gatingTaskId == bytes32(0)) return false;
        ITMPHookV2.SettlementAmounts memory r = ITMPHooksV2(diamond).getTaskSettlement(gatingTaskId);
        return r.recorded && r.terminalStatus == uint8(ITMPCore.TaskStatus.Accepted);
    }

    /// @dev True once the gating task ended without paying: Cancelled or Expired. A rejected
    ///      submission is not a settlement (the task stays live), so it is not a failure here.
    function _gatingFailed(bytes32 gatingTaskId) private view returns (bool) {
        if (gatingTaskId == bytes32(0)) return false;
        ITMPCore.TaskStatus st = ITMPCore(diamond).getTask(gatingTaskId).status;
        return st == ITMPCore.TaskStatus.Cancelled || st == ITMPCore.TaskStatus.Expired;
    }
}
