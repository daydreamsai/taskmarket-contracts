// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title ITMPFees
/// @notice Optional fee-information extension to TMP.
///         Implementations that expose platform fee configuration SHOULD
///         implement this interface and return true from
///         supportsInterface(type(ITMPFees).interfaceId).
interface ITMPFees {
    /// @notice Platform fee in basis points applied to completed task payments.
    ///         Example: 500 = 5%.
    function defaultFeeBps() external view returns (uint16);

    /// @notice Address that receives platform fees.
    function feeRecipient() external view returns (address);

    /// @notice Cumulative platform fees collected since deployment.
    function totalFeesCollected() external view returns (uint256);

    /// @notice Per-task fee override in basis points.
    ///         Returns 0 if no per-task override is set (use defaultFeeBps).
    /// @param taskId Task identifier
    function feeForTask(bytes32 taskId) external view returns (uint16);
}
