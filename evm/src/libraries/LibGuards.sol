// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { LibProject } from "./LibProject.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { IPGTRForwarder } from "../interfaces/IPGTRForwarder.sol";
import { IPGTRPaymentForwarder } from "../interfaces/IPGTRPaymentForwarder.sol";

/// @title LibGuards — forwarder, pause and reentrancy guards and effective-sender resolution
library LibGuards {
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

    /// @notice Reverts NotRequester unless `caller` may act as the task's requester. Every
    ///         requester entrypoint checks through here, so who may act for a requester is decided
    ///         in one place: task.requester, except on a task an operator created in a project,
    ///         where the grant's terms decide between the operator and the project owner.
    function _requireRequester(AppStorage storage s, bytes32 taskId, address caller) internal view {
        if (s.taskOperators[taskId] == address(0)) {
            if (caller != s.tasks[taskId].requester) revert ITMPCore.NotRequester();
        } else if (!LibProject.mayAct(s, taskId, caller)) {
            revert ITMPCore.NotRequester();
        }
    }

    /// @notice Reverts ForwardedPaymentMismatch unless the calling forwarder reports a payment of
    ///         exactly `expected` for this call. A forwarder that cannot report one (v1) is not
    ///         supported on any payment path.
    function _requireReportedPayment(uint256 expected) internal view {
        try IPGTRPaymentForwarder(msg.sender).pgtrPaymentAmount() returns (uint256 paid) {
            if (paid != expected) revert ITMPCore.ForwardedPaymentMismatch();
        } catch {
            revert ITMPCore.ForwardedPaymentMismatch();
        }
    }

    /// @notice The task-funding check: as _requireReportedPayment, except inside createProjectTask
    ///         (rev027), where the project has already paid `projectPrepaid` from its budget, so
    ///         the funding must equal that and the forwarder must report no payment.
    function _requireFunding(AppStorage storage s, uint256 expected) internal view {
        uint256 prepaid = s.projectPrepaid;
        if (prepaid == 0) {
            _requireReportedPayment(expected);
            return;
        }
        if (expected != prepaid) revert ITMPCore.ForwardedPaymentMismatch();
        _requireReportedPayment(0);
    }

    /// @notice Reverts StakePaymentMismatch unless the calling forwarder reports a payment equal
    ///         to stakeAmount for this call. A forwarder that cannot report one (v1) is not
    ///         supported, even for a zero stake.
    /// @dev Caller must already have passed _requireForwarder.
    function _requireStakePayment(uint256 stakeAmount) internal view {
        try IPGTRPaymentForwarder(msg.sender).pgtrPaymentAmount() returns (uint256 paid) {
            if (paid != stakeAmount) revert ITMPCore.StakePaymentMismatch();
        } catch {
            revert ITMPCore.StakePaymentMismatch();
        }
    }
}
