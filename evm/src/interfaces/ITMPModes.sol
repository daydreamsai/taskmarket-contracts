// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Canonical bytes4 mode selectors.
///         Values are the first 4 bytes of keccak256 of the mode name string.
///         New modes can be introduced by any implementer without breaking existing tooling.

/// @dev bytes4(keccak256("TMP.mode.bounty"))
bytes4 constant TMP_BOUNTY = bytes4(keccak256("TMP.mode.bounty"));

/// @dev bytes4(keccak256("TMP.mode.claim"))
bytes4 constant TMP_CLAIM = bytes4(keccak256("TMP.mode.claim"));

/// @dev bytes4(keccak256("TMP.mode.pitch"))
bytes4 constant TMP_PITCH = bytes4(keccak256("TMP.mode.pitch"));

/// @dev bytes4(keccak256("TMP.mode.benchmark"))
bytes4 constant TMP_BENCHMARK = bytes4(keccak256("TMP.mode.benchmark"));

/// @dev bytes4(keccak256("TMP.mode.auction"))
bytes4 constant TMP_AUCTION = bytes4(keccak256("TMP.mode.auction"));

// ---------------------------------------------------------------------------
// Auction subtype selectors
// ---------------------------------------------------------------------------

/// @dev bytes4(keccak256("TMP.auction.dutch"))
bytes4 constant TMP_AUCTION_DUTCH = bytes4(keccak256("TMP.auction.dutch"));

/// @dev bytes4(keccak256("TMP.auction.english"))
bytes4 constant TMP_AUCTION_ENGLISH = bytes4(keccak256("TMP.auction.english"));

/// @dev bytes4(keccak256("TMP.auction.reverse_dutch"))
bytes4 constant TMP_AUCTION_REVERSE_DUTCH = bytes4(keccak256("TMP.auction.reverse_dutch"));

/// @dev bytes4(keccak256("TMP.auction.reverse_english"))
bytes4 constant TMP_AUCTION_REVERSE_ENGLISH = bytes4(keccak256("TMP.auction.reverse_english"));

/// @title ITMPModes
/// @notice Mode-management extension to TMP.
///         Provides the canonical mode selector constants and a mode view.
///
///         Implementations that support ITMPModes SHOULD return true from
///         supportsInterface(type(ITMPModes).interfaceId).
interface ITMPModes is IERC165 {
    /// @notice Returns the mode selector for a given task.
    /// @param taskId Task identifier
    function taskMode(bytes32 taskId) external view returns (bytes4 mode);
}
