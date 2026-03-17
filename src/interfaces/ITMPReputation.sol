// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ITMPReputation
/// @notice Optional ERC-8004 reputation integration extension to TMP.
///         Implementations that record on-chain feedback via an ERC-8004
///         reputation registry SHOULD implement this interface and return true
///         from supportsInterface(type(ITMPReputation).interfaceId).
interface ITMPReputation is IERC165 {
    /// @notice Address of the ERC-8004 Reputation Registry used for feedback.
    ///         Returns address(0) if reputation integration is disabled.
    function reputationRegistry() external view returns (address);

    /// @notice Emitted when a reputation registry is configured or changed.
    event ReputationRegistryUpdated(address indexed newRegistry);
}
