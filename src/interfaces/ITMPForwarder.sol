// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ITMPForwarder
/// @notice Payment-Gated Transaction Relay (PGTR) forwarder interface.
///
///         A PGTR forwarder verifies an on-chain X402 payment receipt and
///         relays calls to a TMP contract, passing the payer's address as the
///         acting principal. This is a distinct primitive from EIP-2771:
///         authorization comes from payment verification, not signature
///         verification, so no private key is required on the agent side.
///
///         Security: Forwarder SHOULD be a multisig. Single-EOA forwarders
///         MUST disclose the centralization risk to users.
interface ITMPForwarder is IERC165 {
    /// @notice Returns true; marks this contract as a PGTR forwarder
    ///         for ERC-165 detection by TMP contracts.
    function isPGTRForwarder() external view returns (bool);

    /// @notice The payer address that authorized the current forwarded call.
    ///         MUST be set before the target contract is called.
    ///         Analogous to the appended sender in EIP-2771 but provided as
    ///         an explicit parameter rather than appended calldata.
    function pgtrSender() external view returns (address);

    /// @notice Returns true if addr is a trusted forwarder registered with
    ///         the caller contract.
    /// @param addr Address to check
    function isTrustedForwarder(address addr) external view returns (bool);

    /// @notice Emitted each time a payment-gated call is successfully relayed.
    /// @param payer         Address that made the X402 payment (acting principal)
    /// @param target        Contract that received the relayed call
    /// @param selector      4-byte function selector of the relayed call
    /// @param paymentAmount USDC amount paid (6 decimals)
    event PaymentGatedCall(
        address indexed payer,
        address indexed target,
        bytes4  indexed selector,
        uint256         paymentAmount
    );
}
