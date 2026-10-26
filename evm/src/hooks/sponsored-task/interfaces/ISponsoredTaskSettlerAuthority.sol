// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISponsoredTaskSettlerAuthority
/// @notice A pluggable authorizer for `SponsoredTaskSettler`, such as a message-bridge receiver.
/// @dev While a settler has no authority set, it checks authorizations against its own settler set.
///      An authority receives the settler's EIP-712 digest, which is already bound to the remote
///      chain id and the settler address, and the opaque authorization bytes the relayer passed.
interface ISponsoredTaskSettlerAuthority {
    function isAuthorized(bytes32 digest, bytes[] calldata authorization) external view returns (bool);
}
