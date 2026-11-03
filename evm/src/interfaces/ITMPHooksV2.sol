// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { ITMPHookV2 } from "./ITMPHookV2.sol";

/// @title ITMPHooksV2 -- rev028 diamond-side Task Hook V2 surface: views, owner settings, the
///        per-action data entrypoint, the settlement record, errors and events
interface ITMPHooksV2 {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice A V1-only hook was supplied to createTask after the rev028 cut.
    error HookV1Retired(uint8 index);
    /// @notice A hook failed attach: see the HOOK_INCOMPATIBLE_* reasons in LibHooksV2.
    error HookIncompatible(uint8 index, uint8 reason);
    error MultipleTransformingHooks();
    /// @notice The hook's runtime codehash differs from the one recorded at attach.
    error HookCodeChanged(uint8 index);
    /// @notice A transforming hook returned a result the diamond cannot apply on a vetoable action.
    error HookResultInvalid(uint8 index);
    /// @notice A before-callback vetoed the action. `reason` is the hook's return or revert data, at
    ///         most 256 bytes, so a rejection can be decoded (for example a hook's custom error).
    error HookRejected(uint8 index, uint8 action, bytes reason);
    error InsufficientGasForHooks();
    error TooManyDefaultHooks();
    error HookCapabilityGasOutOfRange();
    error MaxHookFeeBpsOutOfRange();
    error ActionDataTooLong();
    error ActionDataCallFailed();
    /// @notice callTaskHook named a hook that is not one of the task's V2 attachments.
    error HookNotAttached();
    /// @notice callTaskHook named a hook that does not declare capability bit 30.
    error HookCallNotDeclared();
    /// @notice The caller holds none of the roles the hook accepts.
    error HookCallRoleRefused(uint32 roles);
    /// @notice callTaskHook on an Accepted, Cancelled or Expired task.
    error TaskAlreadySettled();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event HookAttached(
        bytes32 indexed taskId,
        uint8 index,
        address indexed hook,
        uint32 capabilities,
        bytes32 codehash,
        bytes configBytes
    );
    event HookActionData(bytes32 indexed taskId, uint8 indexed action, bytes32 dataHash);
    event HookCallFailedV2(
        bytes32 indexed taskId,
        uint8 index,
        address indexed hook,
        uint8 action,
        uint8 phase,
        uint8 failureClass,
        bytes32 revertHash,
        uint64 seq
    );
    /// @notice Written once when a task becomes terminal (V1 and V2 tasks alike).
    event TaskSettled(bytes32 indexed taskId, ITMPHookV2.SettlementAmounts amounts);
    event DefaultHooksV2Set(address[] hooks);
    event HookCapabilityGasSet(uint8 indexed bit, uint256 gasBudget);
    event MaxHookFeeBpsSet(uint16 maxHookFeeBps);
    /// @notice A caller holding `roles` on the task called `hook` through callTaskHook.
    event TaskHookCalled(
        bytes32 indexed taskId, address indexed hook, address indexed caller, uint32 roles, bytes32 dataHash
    );
    /// @notice A transforming hook's result was applied to a settlement.
    event HookSettlementApplied(bytes32 indexed taskId, uint8 index, uint16 awardCount, uint256 hookFee);

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getTaskHooksV2(bytes32 taskId) external view returns (ITMPHookV2.Attachment[] memory);
    /// @notice 0 for a task created before the rev028 cut (V1 dispatch), 2 for every later task.
    function getTaskHookVersion(bytes32 taskId) external view returns (uint8);
    function getTaskSettlement(bytes32 taskId) external view returns (ITMPHookV2.SettlementAmounts memory);
    function getDefaultHooksV2() external view returns (ITMPHookV2.Attachment[] memory);
    /// @notice The effective gas budget forwarded to a callback with capability `bit`.
    function hookCapabilityGas(uint8 bit) external view returns (uint256);
    function maxHookFeeBps() external view returns (uint16);
    function hookCallSeq(bytes32 taskId, uint8 index) external view returns (uint64);

    // -------------------------------------------------------------------------
    // Owner settings
    // -------------------------------------------------------------------------

    /// @notice Replaces the protocol default V2 hooks (at most two), attached first to new tasks.
    function setDefaultHooksV2(address[] calldata hooks) external;
    function setHookCapabilityGas(uint8 bit, uint256 gasBudget) external;
    function setMaxHookFeeBps(uint16 bps) external;

    // -------------------------------------------------------------------------
    // Hook calls
    // -------------------------------------------------------------------------

    /// @notice Any wallet, directly or through the trusted forwarder, calls `hook`, one of the
    ///         task's V2 attachments that declares capability bit 30, with `data`. The diamond
    ///         computes the caller's roles on the task and refuses a caller holding none the hook
    ///         accepts. Refused on a settled task. The hook's refusal reverts with HookRejected
    ///         carrying its reason.
    function callTaskHook(bytes32 taskId, address hook, bytes calldata data) external;

    /// @notice The caller roles (LibHooksV2 ROLE_* flags) `who` holds on `taskId` now.
    function taskCallerRoles(bytes32 taskId, address who) external view returns (uint32);

    // -------------------------------------------------------------------------
    // Per-action data
    // -------------------------------------------------------------------------

    /// @notice Runs `call` (a diamond action, same caller) with `actionData` passed to every V2
    ///         hook the action calls. The data is never stored; its keccak256 is emitted in
    ///         HookActionData. At most MAX_ACTION_DATA (2048) bytes.
    function withActionData(bytes calldata actionData, bytes calldata call) external returns (bytes memory);
}
