// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The EIP-3009 pull a payee makes with the payer's signed authorization, in the
///         bytes-signature form (USDC v2.2) that also accepts ERC-1271 signatures from contract
///         wallets. The token refuses the call unless `msg.sender == to`, so only the named payee
///         can use an authorization.
interface IERC3009Receive {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
