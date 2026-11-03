// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPCore } from "./ITMPCore.sol";

/// @title ITMPHookV2 -- rev028 Task Hook V2: typed lifecycle callbacks, capabilities and bounded
///        settlement results
/// @notice Every task created after the rev028 cut dispatches to V2 hooks only. Tasks created before
///         the cut keep the V1 `ITMPHook` dispatch unchanged until they are terminal.
///
///         Before-callbacks (`before*`) run for a vetoable action. A hook allows the action by
///         returning its own function selector; a revert, out-of-gas, a wrong selector or oversized
///         return data vetoes the whole action. The diamond calls a before-callback only when the
///         matching capability bit is set.
///
///         After-callbacks (`after*`) are best-effort: a failure is swallowed and reported in
///         `HookCallFailedV2`. Each one carries `seq`, the per-task-and-hook sequence number, which
///         grows by one per after-callback whether or not it succeeds, so a hook can detect a missed
///         call and reconcile from `getTaskSettlement`.
///
///         The non-vetoable exits (forfeit, expiry refund, requester and evaluator timeouts,
///         lapsed-review settlement, finalize after expiry and dispute resolution) never call a
///         vetoable before-callback. On dispute resolution `beforeAccept` is still called, best
///         effort, with `ctx.currentState == Disputed`, so a transforming hook can return its
///         result and a check hook can see the ruling; its veto is ignored there.
interface ITMPHookV2 is IERC165 {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice One V2 hook attached to a task, fixed at creation.
    struct Attachment {
        address hook;
        // Callback and result flags declared by the hook, masked to the bits this revision defines.
        uint32 capabilities;
        uint16 minDiamondVersion;
        // True when the hook holds a result power (bit 26 or 27); at most one per task.
        bool transforming;
        // keccak256 of this hook's configuration bytes, emitted in HookAttached.
        bytes32 configHash;
        // Hook runtime codehash observed at attach; compared before every vetoable callback.
        bytes32 codehash;
        // The caller roles the hook accepts on onCall (hookCallRoles), read at attach when it
        // declares capability bit 30; zero otherwise.
        uint32 callRoles;
    }

    /// @notice What a V2 callback sees of the task.
    struct TaskContextV2 {
        bytes32 taskId;
        // The authenticated caller of the action (address(0) for a permissionless exit's keeper is
        // never used: the caller is always reported).
        address actor;
        address requester;
        address worker;
        address evaluator;
        address disputeResolver;
        address paymentToken;
        uint256 reward;
        uint256 evaluatorStake;
        uint16 evaluatorFeeBps;
        uint16 feeBps;
        bytes4 mode;
        // The task's status when the action began.
        ITMPCore.TaskStatus priorStatus;
        // The task's status as the callback runs. On dispute resolution `beforeAccept` sees
        // Disputed; every after-callback sees the settled status.
        ITMPCore.TaskStatus currentState;
        uint64 expiryTime;
        uint256 projectId;
        ITMPCore.TaskTerms terms;
    }

    /// @notice The transforming hook's settlement result, returned by `beforeAccept`.
    struct SettlementDelta {
        // Must equal beforeAccept's selector.
        bytes4 selector;
        // Zero means no change to awards; otherwise the number of awards returned beside it.
        uint16 awardCount;
        // Hook fee taken from the worker side, at most maxHookFeeBps; zero means none.
        uint16 hookFeeBps;
    }

    /// @notice Totals that moved when a task settled (also the onchain settlement record).
    struct SettlementAmounts {
        // Net amount paid to workers (awards less the protocol fee and any hook fee).
        uint128 workerPaid;
        // Everything paid back to the requester (or, for a project task, its pool).
        uint128 requesterRefund;
        // Stake forfeited by a worker or an evaluator, accumulated across forfeits.
        uint128 forfeited;
        uint128 evaluatorFee;
        uint128 protocolFee;
        uint128 hookFee;
        uint16 awardCount;
        uint8 terminalStatus;
        uint40 settledAt;
        bool recorded;
    }

    // -------------------------------------------------------------------------
    // Capability bits (see the rev028 spec)
    // -------------------------------------------------------------------------
    // 0-15  before-callback for each vetoable action, in Action order (Create .. Rate)
    // 16-20 reserved
    // 21-24 afterComplete, afterCancel, afterExpire, afterForfeit
    // 25    afterAction for every other action (the observer group)
    // 26    result power: reduce or reallocate awards among eligible workers
    // 27    result power: hook fee within maxHookFeeBps
    // 28-29 reserved (28 redirect, 29 separately funded value)
    // 30    onCall: the hook receives calls through the diamond's callTaskHook from the roles
    //       hookCallRoles declares
    // 31    reserved

    // -------------------------------------------------------------------------
    // Manifest
    // -------------------------------------------------------------------------

    function hookCapabilities() external view returns (uint32);
    function minDiamondVersion() external view returns (uint16);
    /// @notice The caller roles (ROLE_* flags, see LibHooksV2) this hook accepts on onCall. Read
    ///         and pinned at attach when capability bit 30 is declared; must be constant.
    function hookCallRoles() external view returns (uint32);

    // -------------------------------------------------------------------------
    // Before-callbacks, one per vetoable action. Each returns its own selector to allow.
    // -------------------------------------------------------------------------

    /// @notice Create: `config` is this hook's own configuration bytes from createTask.
    function beforeCreate(bytes32 taskId, TaskContextV2 calldata ctx, bytes calldata config, bytes calldata actionData)
        external
        returns (bytes4);
    function beforeAssignEvaluator(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        address evaluator,
        bytes calldata actionData
    ) external returns (bytes4);
    function beforeUpdate(bytes32 taskId, TaskContextV2 calldata ctx, bytes calldata actionData)
        external
        returns (bytes4);
    function beforeClaim(bytes32 taskId, TaskContextV2 calldata ctx, address worker, bytes calldata actionData)
        external
        returns (bytes4);
    function beforeSubmitPitch(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        address worker,
        bytes32 pitchHash,
        bytes calldata actionData
    ) external returns (bytes4);
    function beforeSelectWorker(bytes32 taskId, TaskContextV2 calldata ctx, address worker, bytes calldata actionData)
        external
        returns (bytes4);
    function beforeSubmitProof(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        address worker,
        bytes32 proofHash,
        bytes calldata actionData
    ) external returns (bytes4);
    function beforeSubmitBid(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        address bidder,
        uint256 price,
        bytes calldata actionData
    ) external returns (bytes4);
    function beforeAcceptAuction(bytes32 taskId, TaskContextV2 calldata ctx, address worker, bytes calldata actionData)
        external
        returns (bytes4);
    function beforeSubmitWork(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        address worker,
        bytes32 deliverableHash,
        bytes calldata actionData
    ) external returns (bytes4);
    function beforeRejectSubmission(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        address worker,
        bytes calldata actionData
    ) external returns (bytes4);
    function beforeEvaluate(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        ITMPCore.Verdict calldata proposed,
        bytes calldata actionData
    ) external returns (bytes4);
    function beforeAppeal(bytes32 taskId, TaskContextV2 calldata ctx, address appellant, bytes calldata actionData)
        external
        returns (bytes4);
    /// @notice Accept: acceptSubmission, acceptSubmissions and finalizeVerdict (vetoable), and
    ///         resolveDispute (best effort, `ctx.currentState == Disputed`, veto ignored). A
    ///         transforming hook returns its result; any other hook returns an empty delta.
    function beforeAccept(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        ITMPCore.Verdict calldata verdict,
        bytes calldata actionData
    ) external returns (bytes4, SettlementDelta memory, ITMPCore.Award[] memory);
    function beforeCancel(bytes32 taskId, TaskContextV2 calldata ctx, bytes calldata actionData)
        external
        returns (bytes4);
    function beforeRate(bytes32 taskId, TaskContextV2 calldata ctx, address worker, bytes calldata actionData)
        external
        returns (bytes4);

    /// @notice A call relayed by the diamond's callTaskHook (capability bit 30). The diamond has
    ///         resolved `caller`, computed its `roles` on the task from current state, checked
    ///         that it holds at least one role this hook accepts, that the hook is attached and
    ///         that the task has not settled. Test single flags in `roles`, never the whole set.
    ///         Return this function's selector to accept; anything else, or a revert, refuses.
    function onCall(bytes32 taskId, TaskContextV2 calldata ctx, address caller, uint32 roles, bytes calldata data)
        external
        returns (bytes4);

    // -------------------------------------------------------------------------
    // After-callbacks (best effort)
    // -------------------------------------------------------------------------

    function afterComplete(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata amounts, uint64 seq)
        external;
    function afterCancel(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata amounts, uint64 seq)
        external;
    function afterExpire(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata amounts, uint64 seq)
        external;
    function afterForfeit(bytes32 taskId, TaskContextV2 calldata ctx, SettlementAmounts calldata amounts, uint64 seq)
        external;
    /// @notice Observer group: every state-changing action without its own after-callback.
    function afterAction(
        bytes32 taskId,
        TaskContextV2 calldata ctx,
        uint8 action,
        bytes calldata actionData,
        uint64 seq
    ) external;
}
