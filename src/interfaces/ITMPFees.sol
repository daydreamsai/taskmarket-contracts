// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title ITMPFees
/// @notice Optional fee-information extension to TMP (ERC-8195).
///         Implementations that expose platform fee configuration SHOULD
///         implement this interface and return true from
///         supportsInterface(type(ITMPFees).interfaceId).
interface ITMPFees is IERC165 {
    /// @notice Platform fee in basis points deducted from reward on task completion.
    ///         Example: 500 = 5%.
    function defaultFeeBps() external view returns (uint16);

    /// @notice Address that receives platform fees.
    function feeRecipient() external view returns (address);

    /// @notice Cumulative platform fees collected since deployment.
    function totalFeesCollected() external view returns (uint256);

    /// @notice Per-task fee in basis points stamped at task creation.
    ///         Returns the task-specific override; use defaultFeeBps if no override is set.
    /// @param taskId Task identifier
    function feeForTask(bytes32 taskId) external view returns (uint16);
}
