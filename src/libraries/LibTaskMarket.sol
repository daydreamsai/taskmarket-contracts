// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";
import { IPGTRForwarder } from "../interfaces/IPGTRForwarder.sol";

/// @title LibTaskMarket — shared internal helpers for TaskMarket facets
/// @dev All helpers take AppStorage as an explicit parameter so they can be called
///      from any facet. Functions that call external contracts must be `internal`
///      (not `private`) so they are accessible across facets via library linkage.
library LibTaskMarket {
    uint256 internal constant NOT_ENTERED = 1;
    uint256 internal constant ENTERED = 2;

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
    // Hook helpers
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

    /// @notice Calls an after-hook best-effort (swallows failures).
    ///         Does nothing when hook == address(0).
    function _afterHook(address hook, bytes memory data) internal {
        if (hook == address(0)) return;
        // on* hooks are fire-and-forget; failures are swallowed so a buggy hook cannot block
        // fund recovery. HookCallFailed makes failures observable on-chain.
        // slither-disable-next-line unchecked-lowlevel
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = hook.call(data);
        if (!ok) emit ITMPCore.HookCallFailed(hook);
    }

    /// @notice Calls checkFund on a hook contract, reverts if rejected.
    function _checkFundHook(bytes32 taskId, address hookContract, bytes calldata hookData, AppStorage storage s)
        internal
    {
        if (!ITMPHook(hookContract).checkFund(taskId, _buildContext(taskId, s), hookData)) {
            revert ITMPCore.HookCheckFundRejected();
        }
        emit ITMPCore.HookRegistered(taskId, hookContract);
    }
}
