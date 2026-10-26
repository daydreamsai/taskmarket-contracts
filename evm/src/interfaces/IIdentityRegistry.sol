// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title IIdentityRegistry
/// @notice The part of the ERC-8004 Identity Registry (an ERC-721 of agent IDs) the diamond reads.
interface IIdentityRegistry {
    /// @notice The owner of an agent ID; reverts for an ID that does not exist.
    function ownerOf(uint256 agentId) external view returns (address);
}
