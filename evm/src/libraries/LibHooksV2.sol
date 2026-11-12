// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LibHooksV2 -- rev028 Task Hook V2 constants and the transient values a dispatch reads
/// @dev Action ids follow the rev028 spec's action table. The vetoable actions 0-15 each have a
///      before-callback whose capability bit equals the action id.
library LibHooksV2 {
    uint8 internal constant VERSION_V2 = 2;

    // Vetoable actions (before-callback bit = action id).
    uint8 internal constant A_CREATE = 0;
    uint8 internal constant A_ASSIGN_EVALUATOR = 1;
    uint8 internal constant A_UPDATE = 2;
    uint8 internal constant A_CLAIM = 3;
    uint8 internal constant A_SUBMIT_PITCH = 4;
    uint8 internal constant A_SELECT_WORKER = 5;
    uint8 internal constant A_SUBMIT_PROOF = 6;
    uint8 internal constant A_SUBMIT_BID = 7;
    uint8 internal constant A_ACCEPT_AUCTION = 8;
    uint8 internal constant A_SUBMIT_WORK = 9;
    uint8 internal constant A_REJECT_SUBMISSION = 10;
    uint8 internal constant A_EVALUATE = 11;
    uint8 internal constant A_APPEAL = 12;
    uint8 internal constant A_ACCEPT = 13;
    uint8 internal constant A_CANCEL = 14;
    uint8 internal constant A_RATE = 15;
    // Non-vetoable exits (no before-callback).
    uint8 internal constant A_FORFEIT = 16;
    uint8 internal constant A_EXPIRE = 17;
    uint8 internal constant A_TIMEOUT = 18;
    uint8 internal constant A_LAPSED_REVIEW = 19;
    uint8 internal constant A_FINALIZE_AFTER_EXPIRY = 20;
    uint8 internal constant A_RESOLVE_DISPUTE = 21;
    // A call to one of the task's hooks through callTaskHook.
    uint8 internal constant A_HOOK_CALL = 22;

    // Capability bits beyond the before-callbacks.
    uint8 internal constant BIT_AFTER_COMPLETE = 21;
    uint8 internal constant BIT_AFTER_CANCEL = 22;
    uint8 internal constant BIT_AFTER_EXPIRE = 23;
    uint8 internal constant BIT_AFTER_FORFEIT = 24;
    uint8 internal constant BIT_OBSERVER = 25;
    uint8 internal constant BIT_REALLOCATE = 26;
    uint8 internal constant BIT_HOOK_FEE = 27;
    /// @notice The hook receives calls through callTaskHook (onCall) from the roles it declares.
    uint8 internal constant BIT_HOOK_CALL = 30;

    // Caller roles passed to onCall, as flags. One wallet can hold several. Later revisions may add
    // flags in the free bits (5-30), so a hook tests the flags it needs and never compares the set.
    uint32 internal constant ROLE_REQUESTER = 1 << 0;
    uint32 internal constant ROLE_PROJECT = 1 << 1;
    uint32 internal constant ROLE_WORKER = 1 << 2;
    uint32 internal constant ROLE_SUBMITTER = 1 << 3;
    uint32 internal constant ROLE_EVALUATOR = 1 << 4;
    // Set alone: the caller holds none of the other roles.
    uint32 internal constant ROLE_STRANGER = 1 << 31;

    /// @notice Bits this revision defines: before 0-15, 21-27 and 30. Everything else is masked off.
    uint32 internal constant DEFINED_MASK = 0x4FE0FFFF;
    uint32 internal constant TRANSFORM_MASK = (uint32(1) << 26) | (uint32(1) << 27);

    // Terminal kinds for hookSettle.
    uint8 internal constant KIND_COMPLETE = 0;
    uint8 internal constant KIND_CANCEL = 1;
    uint8 internal constant KIND_EXPIRE = 2;
    uint8 internal constant KIND_FORFEIT = 3;
    /// @notice Or-ed into a kind for a non-exit action: every after-callback's gas is required.
    uint8 internal constant KIND_STRICT = 0x80;

    // Phases and failure classes in HookCallFailedV2.
    uint8 internal constant PHASE_BEFORE = 0;
    uint8 internal constant PHASE_AFTER = 1;
    uint8 internal constant FAIL_REVERT = 1;
    uint8 internal constant FAIL_EMPTY_REVERT = 2;
    uint8 internal constant FAIL_REJECTED = 3;
    uint8 internal constant FAIL_RESULT_INVALID = 4;
    /// @notice A best-effort callback skipped because too little gas was left for its budget.
    uint8 internal constant FAIL_GAS = 5;

    // HookIncompatible reasons.
    uint8 internal constant R_INTERFACE = 1;
    uint8 internal constant R_MANIFEST = 2;
    uint8 internal constant R_VERSION = 3;
    uint8 internal constant R_CAPABILITIES = 4;
    uint8 internal constant R_CONFIG = 5;
    uint8 internal constant R_DUPLICATE = 6;

    uint256 internal constant MAX_HOOKS_V2 = 8;
    uint256 internal constant MAX_DEFAULT_HOOKS_V2 = 2;
    uint256 internal constant MAX_ACTION_DATA = 2048;
    /// @notice Floor and ceiling of the owner-set gas budget per capability.
    uint256 internal constant GAS_FLOOR = 1_000_000;
    uint256 internal constant GAS_MAX = 8_000_000;
    uint256 internal constant GAS_MARGIN = 100_000;
    /// @notice Most gas a non-exit action requires up front for its after-callbacks. With about
    ///         3.5M of settlement work around it, this keeps an accept or a cancel under Tempo's
    ///         29.9M per-transaction cap however many hooks the task has; callbacks past it are
    ///         best effort.
    uint256 internal constant MAX_STRICT_HOOK_GAS = 16_000_000;
    /// @notice Most gas the best-effort callbacks of one forced exit (a dispute ruling, a
    ///         settlement after expiry, a lapsed review) spend in one dispatch. Once hooks have
    ///         spent it, or would spend more than it with their next budget, the rest are skipped
    ///         and reported, so the settlement around them keeps its gas however many hooks the
    ///         task carries. The first callback always runs, whatever its budget.
    uint256 internal constant MAX_EXIT_HOOK_GAS = 6_000_000;
    /// @notice Gas held back per remaining hook so that skipping it (event and sequence write)
    ///         cannot run out of gas.
    uint256 internal constant SKIP_RESERVE = 40_000;
    /// @notice Gas for each manifest read at attach (supportsInterface, hookCapabilities, minDiamondVersion).
    uint256 internal constant MANIFEST_GAS = 50_000;
    /// @notice Highest maxHookFeeBps the owner may set.
    uint16 internal constant MAX_HOOK_FEE_BPS_CAP = 1000;

    bytes32 private constant ACTOR_SLOT = keccak256("taskmarket.rev028.actor");
    bytes32 private constant PRIOR_BASE = keccak256("taskmarket.rev028.prior");
    bytes32 private constant DATA_SLOT = keccak256("taskmarket.rev028.actionData");
    bytes32 private constant ACTIVE_SLOT = keccak256("taskmarket.rev028.actionData.active");

    /// @notice Records the caller of the outermost diamond action, for TaskContextV2.actor.
    function setActor(address actor) internal {
        bytes32 slot = ACTOR_SLOT;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            tstore(slot, actor)
        }
    }

    function actorRaw() internal view returns (address a) {
        bytes32 slot = ACTOR_SLOT;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            a := tload(slot)
        }
    }

    /// @notice Records a task's status before an action writes it, for TaskContextV2.priorStatus.
    ///         One snapshot per action (the task ID and its status), cleared when the action ends
    ///         (LibGuards._nonReentrantAfter), so a later action in the same transaction never
    ///         reads a stale one.
    function snap(bytes32 taskId, uint8 status) internal {
        uint256 slot = uint256(PRIOR_BASE);
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            tstore(slot, taskId)
            tstore(add(slot, 1), add(status, 1))
        }
    }

    function clearSnap() internal {
        uint256 slot = uint256(PRIOR_BASE);
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            tstore(add(slot, 1), 0)
        }
    }

    /// @notice The snapshot taken this transaction, or `current` when none was.
    function prior(bytes32 taskId, uint8 current) internal view returns (uint8) {
        uint256 slot = uint256(PRIOR_BASE);
        bytes32 id;
        uint256 v;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            id := tload(slot)
            v := tload(add(slot, 1))
        }
        return v == 0 || id != taskId ? current : uint8(v - 1);
    }

    /// @notice Stores per-action data for the call under way (length word, then words).
    function setActionData(bytes memory data) internal {
        uint256 base = uint256(DATA_SLOT);
        uint256 len = data.length;
        // Memory-safe: reads data and writes transient storage only.
        assembly ("memory-safe") {
            tstore(base, len)
            let words := div(add(len, 31), 32)
            for { let i := 0 } lt(i, words) { i := add(i, 1) } {
                tstore(add(base, add(i, 1)), mload(add(data, add(32, mul(i, 32)))))
            }
        }
    }

    function clearActionData() internal {
        uint256 base = uint256(DATA_SLOT);
        bytes32 flag = ACTIVE_SLOT;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            tstore(base, 0)
            tstore(flag, 0)
        }
    }

    /// @notice Marks a withActionData call as under way, so it cannot be entered again.
    function enterActionData() internal {
        bytes32 flag = ACTIVE_SLOT;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            tstore(flag, 1)
        }
    }

    function actionDataActive() internal view returns (bool active) {
        bytes32 flag = ACTIVE_SLOT;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            active := tload(flag)
        }
    }

    function actionData() internal view returns (bytes memory data) {
        uint256 base = uint256(DATA_SLOT);
        uint256 len;
        // Memory-safe: transient storage only.
        assembly ("memory-safe") {
            len := tload(base)
        }
        data = new bytes(len);
        // Memory-safe: writes only inside data, allocated at len bytes rounded up by new bytes.
        assembly ("memory-safe") {
            let words := div(add(len, 31), 32)
            for { let i := 0 } lt(i, words) { i := add(i, 1) } {
                mstore(add(data, add(32, mul(i, 32))), tload(add(base, add(i, 1))))
            }
        }
    }
}
