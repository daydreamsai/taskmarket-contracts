// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
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

    /// @notice Reverts StakePaymentMismatch unless the calling forwarder reports a payment equal
    ///         to stakeAmount for this call.
    /// @dev Caller must already have passed _requireForwarder. A forwarder that cannot report an
    ///      amount is accepted only for a zero stake, so an earlier forwarder keeps relaying
    ///      unstaked claims while both are trusted.
    /// @notice The payment the calling forwarder reports for this call, and whether it reports
    ///         one at all. A forwarder without pgtrPaymentAmount (v1) reports none.
    function _forwardedPayment() internal view returns (bool reported, uint256 paid) {
        try IPGTRPaymentForwarder(msg.sender).pgtrPaymentAmount() returns (uint256 amount) {
            return (true, amount);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Reverts ForwardedPaymentMismatch when the calling forwarder reports a payment
    ///         other than `expected`; returns false, checking nothing, when it reports none.
    function _requireReportedPayment(uint256 expected) internal view returns (bool reported) {
        uint256 paid;
        (reported, paid) = _forwardedPayment();
        if (reported && paid != expected) revert ITMPCore.ForwardedPaymentMismatch();
    }

    function _requireStakePayment(uint256 stakeAmount) internal view {
        try IPGTRPaymentForwarder(msg.sender).pgtrPaymentAmount() returns (uint256 paid) {
            if (paid != stakeAmount) revert ITMPCore.StakePaymentMismatch();
        } catch {
            if (stakeAmount != 0) revert ITMPCore.StakePaymentMismatch();
        }
    }
}
