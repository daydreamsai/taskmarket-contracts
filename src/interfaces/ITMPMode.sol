// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @notice Canonical bytes4 mode selectors.
///         Values are the first 4 bytes of keccak256 of the mode name string.
///         New modes can be introduced by any implementer without breaking existing tooling.

/// @dev bytes4(keccak256("TMP.mode.bounty"))
bytes4 constant TMP_BOUNTY    = bytes4(keccak256("TMP.mode.bounty"));

/// @dev bytes4(keccak256("TMP.mode.claim"))
bytes4 constant TMP_CLAIM     = bytes4(keccak256("TMP.mode.claim"));

/// @dev bytes4(keccak256("TMP.mode.pitch"))
bytes4 constant TMP_PITCH     = bytes4(keccak256("TMP.mode.pitch"));

/// @dev bytes4(keccak256("TMP.mode.benchmark"))
bytes4 constant TMP_BENCHMARK = bytes4(keccak256("TMP.mode.benchmark"));

/// @dev bytes4(keccak256("TMP.mode.auction"))
bytes4 constant TMP_AUCTION   = bytes4(keccak256("TMP.mode.auction"));

/// @title ITMPMode
/// @notice Mode-management extension to TMP.
///         Provides the canonical mode selector constants and mode-specific
///         evaluator resolution.
///
///         Implementations that support ITMPMode SHOULD return true from
///         supportsInterface(type(ITMPMode).interfaceId).
interface ITMPMode {
    /// @notice Returns the address responsible for evaluating work on a given task.
    ///         BOUNTY/CLAIM/PITCH/AUCTION → task.requester
    ///         BENCHMARK → ERC-8004 Validation Registry address
    /// @param taskId Task identifier
    /// @return evaluator Address that can call acceptSubmission() for this task
    function evaluatorFor(bytes32 taskId) external view returns (address evaluator);
}
