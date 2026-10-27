// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SponsoredTaskCreationFee } from "./SponsoredTaskCreationFee.sol";
import { SponsoredTasksVault } from "./SponsoredTasksVault.sol";
import { ISponsoredTaskRegistry } from "./interfaces/ISponsoredTaskRegistry.sol";

/// @title SponsoredTaskFactory
/// @notice Permissionless deterministic deployment and discovery for one-token vaults.
/// @dev The implementation, controller, and fee policy are fixed for this factory version. A new
///      factory is deployed for a future implementation rather than changing existing vaults.
///      Creating a vault pays the one-time creation fee (`SponsoredTaskCreationFee`) from the caller.
contract SponsoredTaskFactory is SponsoredTaskCreationFee {
    uint32 public constant IMPLEMENTATION_VERSION = 1;

    address public immutable implementation;
    address public immutable controller;
    address public immutable feePolicy;
    ISponsoredTaskRegistry public immutable registry;

    address[] private _vaults;
    mapping(address vault => bool registered) public isVault;
    mapping(address vault => bytes32 vaultId) public vaultIdOf;
    mapping(bytes32 vaultId => address vault) public vaultOf;

    error ZeroAddress();
    error InvalidContract(address account);
    error VaultAlreadyExists(address vault);

    event VaultCreated(
        bytes32 indexed vaultId,
        address indexed vault,
        address indexed vaultOwner,
        address creator,
        address token,
        uint256 settlementChain,
        uint32 implementationVersion,
        bytes32 userSalt
    );

    constructor(
        address controller_,
        address feePolicy_,
        ISponsoredTaskRegistry registry_,
        CreationFeeConfig memory creationFee_
    ) SponsoredTaskCreationFee(creationFee_) {
        if (controller_ == address(0) || feePolicy_ == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        if (controller_.code.length == 0) revert InvalidContract(controller_);
        if (feePolicy_.code.length == 0) revert InvalidContract(feePolicy_);
        if (address(registry_).code.length == 0) revert InvalidContract(address(registry_));

        controller = controller_;
        feePolicy = feePolicy_;
        registry = registry_;
        implementation = address(new SponsoredTasksVault());
    }

    /// @notice Create a vault owned by an EOA or contract wallet such as a Safe.
    /// @dev Including `msg.sender` in the deployment salt prevents another account from consuming
    ///      the caller's chosen salt. Funding is deliberately separate and permissionless. The caller
    ///      pays the creation fee and must have approved this factory for it.
    function createVault(address token, address vaultOwner, bytes32 userSalt)
        external
        returns (address vault, bytes32 vaultId)
    {
        if (token == address(0) || vaultOwner == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert InvalidContract(token);

        bytes32 deploymentSalt = _deploymentSalt(msg.sender, vaultOwner, token, userSalt);
        vault = Clones.predictDeterministicAddress(implementation, deploymentSalt, address(this));
        if (isVault[vault] || vault.code.length != 0) revert VaultAlreadyExists(vault);

        vault = Clones.cloneDeterministic(implementation, deploymentSalt);
        vaultId = keccak256(abi.encode(block.chainid, address(this), vault));

        isVault[vault] = true;
        vaultIdOf[vault] = vaultId;
        vaultOf[vaultId] = vault;
        _vaults.push(vault);

        SponsoredTasksVault(vault).initialize(vaultId, token, vaultOwner, controller, feePolicy);
        registry.registerVault(vault, vaultId, IMPLEMENTATION_VERSION);

        emit VaultCreated(
            vaultId, vault, vaultOwner, msg.sender, token, block.chainid, IMPLEMENTATION_VERSION, userSalt
        );
        _collectCreationFee(vault, msg.sender);
    }

    function predictVault(address creator, address vaultOwner, address token, bytes32 userSalt)
        external
        view
        returns (address)
    {
        bytes32 deploymentSalt = _deploymentSalt(creator, vaultOwner, token, userSalt);
        return Clones.predictDeterministicAddress(implementation, deploymentSalt, address(this));
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    function _deploymentSalt(address creator, address vaultOwner, address token, bytes32 userSalt)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(creator, vaultOwner, token, userSalt));
    }
}
