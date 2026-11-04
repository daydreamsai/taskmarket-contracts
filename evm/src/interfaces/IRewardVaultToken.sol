// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev `RewardVault.token` is a public immutable typed as an IERC20, which `IRewardVault` cannot
///      declare without clashing, so the reward hooks read it through this interface.
interface IRewardVaultToken {
    function token() external view returns (address);
}
