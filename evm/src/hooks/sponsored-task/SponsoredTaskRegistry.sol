// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { SponsoredTaskTypes } from "./SponsoredTaskTypes.sol";
import { ISponsoredTasksVault } from "./interfaces/ISponsoredTasksVault.sol";
import { ISponsoredTaskRegistry } from "./interfaces/ISponsoredTaskRegistry.sol";

/// @title SponsoredTaskRegistry
/// @notice Canonical, chain-local attestation registry for official sponsored task vaults.
/// @dev Hooks and cross-chain gateways reject vaults that were not registered atomically by an
///      explicitly authorized factory. This prevents a lookalike contract from advertising an
///      unbacked project-token sponsor while no-oping reserve or settlement calls.
contract SponsoredTaskRegistry is ISponsoredTaskRegistry, Ownable2Step {
    struct VaultRecord {
        bytes32 vaultId;
        address factory;
        address token;
        address initialVaultOwner;
        address controller;
        uint256 settlementChain;
        uint32 implementationVersion;
    }

    mapping(address factory => bool authorized) public authorizedFactories;
    mapping(address vault => VaultRecord record) private _vaults;
    mapping(bytes32 vaultId => address vault) public override vaultOf;

    error ZeroAddress();
    error InvalidContract(address account);
    error UnauthorizedFactory(address factory);
    error VaultAlreadyRegistered(address vault, bytes32 vaultId);
    error VaultIdentityMismatch(bytes32 expected, bytes32 actual);
    error VaultNotActive();
    error InvalidVaultConfiguration();

    event FactoryAuthorizationUpdated(address indexed factory, bool authorized);
    event VaultRegistered(
        bytes32 indexed vaultId,
        address indexed vault,
        address indexed factory,
        address token,
        address initialVaultOwner,
        address controller,
        uint256 settlementChain,
        uint32 implementationVersion
    );

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function setFactory(address factory, bool authorized) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (authorized && factory.code.length == 0) revert InvalidContract(factory);
        authorizedFactories[factory] = authorized;
        emit FactoryAuthorizationUpdated(factory, authorized);
    }

    /// @inheritdoc ISponsoredTaskRegistry
    function registerVault(address vault, bytes32 vaultId, uint32 implementationVersion) external override {
        if (!authorizedFactories[msg.sender]) revert UnauthorizedFactory(msg.sender);
        if (vault == address(0) || vaultId == bytes32(0)) revert ZeroAddress();
        if (vault.code.length == 0) revert InvalidContract(vault);
        if (_vaults[vault].vaultId != bytes32(0) || vaultOf[vaultId] != address(0)) {
            revert VaultAlreadyRegistered(vault, vaultId);
        }

        ISponsoredTasksVault vaultContract = ISponsoredTasksVault(vault);
        bytes32 actualVaultId = vaultContract.vaultId();
        if (actualVaultId != vaultId) {
            revert VaultIdentityMismatch(vaultId, actualVaultId);
        }
        if (vaultContract.status() != SponsoredTaskTypes.VaultStatus.Active || vaultContract.epoch() != 1) {
            revert VaultNotActive();
        }

        address token = vaultContract.token();
        address initialVaultOwner = vaultContract.owner();
        address controller = vaultContract.controller();
        uint256 settlementChain = vaultContract.settlementChain();
        if (
            token == address(0) || token.code.length == 0 || initialVaultOwner == address(0) || controller == address(0)
                || controller.code.length == 0 || settlementChain != block.chainid || implementationVersion == 0
        ) revert InvalidVaultConfiguration();

        _vaults[vault] = VaultRecord({
            vaultId: vaultId,
            factory: msg.sender,
            token: token,
            initialVaultOwner: initialVaultOwner,
            controller: controller,
            settlementChain: settlementChain,
            implementationVersion: implementationVersion
        });
        vaultOf[vaultId] = vault;
        emit VaultRegistered(
            vaultId, vault, msg.sender, token, initialVaultOwner, controller, settlementChain, implementationVersion
        );
    }

    function isVault(address vault) external view override returns (bool) {
        return _vaults[vault].vaultId != bytes32(0);
    }

    function vaultIdOf(address vault) external view override returns (bytes32) {
        return _vaults[vault].vaultId;
    }

    function vaultRecord(address vault) external view returns (VaultRecord memory) {
        return _vaults[vault];
    }
}
