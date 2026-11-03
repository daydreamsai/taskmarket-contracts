// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";
import { ITMPHookV2 } from "./ITMPHookV2.sol";

/// @title ITMPHookDispatch -- rev028 internal hook dispatch, callable only by the diamond itself
/// @notice The facets reach every hook (V1 and V2) through these selectors with a call to
///         `address(this)`, so the dispatch code lives once, in HookDispatchFacet, rather than in
///         each facet. Every function reverts NotSelf for any other caller. Not part of the public
///         protocol surface.
interface ITMPHookDispatch {
    error NotSelf();

    /// @notice Attaches a new task's V2 hooks (protocol defaults first, then `hooks`) and runs
    ///         beforeCreate. `data` is empty or `abi.encode(bytes[] configs)`, one per entry in
    ///         `hooks`.
    function hookAttach(bytes32 taskId, address[] calldata hooks, bytes calldata data) external;

    /// @notice Reads and checks a hook's V2 manifest (setDefaultHooksV2 uses it).
    function hookReadManifest(address hook, uint8 index) external view returns (ITMPHookV2.Attachment memory);

    /// @notice Runs the before-callbacks of a vetoable action (the V1 check hook for a V1 task where
    ///         one exists). `who` and `extra` are the action's typed parameters.
    function hookBefore(bytes32 taskId, uint8 action, address who, bytes32 extra) external;

    /// @notice Runs the observer after-callback of a V2 task's action.
    function hookObserve(bytes32 taskId, uint8 action, bool vetoable) external;

    /// @notice Calls onCall on the task's attachment `index` for `caller` holding `roles`.
    function hookCall(bytes32 taskId, uint8 index, address caller, uint32 roles, bytes calldata data) external;

    /// @notice V1 checkComplete; on a dispute resolution the context shows Disputed.
    function hookCheckCompleteV1(bytes32 taskId, ITMPCore.Verdict calldata verdict, bool disputed) external;

    /// @notice V2 beforeAccept on every hook declaring it, and the transforming hook's validated
    ///         result. `awards` is what the core would pay; `budget` its most.
    function hookAcceptV2(
        bytes32 taskId,
        ITMPCore.Verdict calldata verdict,
        bool vetoable,
        bool disputed,
        uint256 budget
    ) external returns (bool changed, ITMPCore.Award[] memory awards, uint16 hookFeeBps, address feeHook);

    /// @notice Writes the settlement record (or the forfeit running total) and runs the terminal
    ///         after-callbacks: V1 on* for a V1 task, V2 after* for a V2 task. `kind` is one of
    ///         LibHooksV2.KIND_*; `verdict` is used for complete, `who` for forfeit.
    function hookSettle(bytes32 taskId, uint8 kind, ITMPCore.Verdict calldata verdict, address who) external;
}
