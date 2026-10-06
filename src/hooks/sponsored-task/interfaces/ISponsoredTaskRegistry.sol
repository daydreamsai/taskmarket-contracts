// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISponsoredTaskRegistry {
    function isVault(address vault) external view returns (bool);
    function vaultIdOf(address vault) external view returns (bytes32);
    function vaultOf(bytes32 vaultId) external view returns (address);
    function registerVault(address vault, bytes32 vaultId, uint32 implementationVersion) external;
}
