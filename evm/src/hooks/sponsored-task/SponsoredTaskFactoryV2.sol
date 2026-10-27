// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { SponsoredTasksVaultV2 } from "./SponsoredTasksVaultV2.sol";
import { ISponsoredTaskRegistry } from "./interfaces/ISponsoredTaskRegistry.sol";

/// @title SponsoredTaskFactoryV2
/// @notice rev030: permissionless deterministic deployment of `SponsoredTasksVaultV2` clones,
///         with a relayable create the vault owner authorizes by signature.
/// @dev Deployed beside the v1 factory, which keeps serving the vaults it made. The
///      implementation, controller, and fee policy are fixed for this factory version.
contract SponsoredTaskFactoryV2 is EIP712 {
    uint32 public constant IMPLEMENTATION_VERSION = 2;

    bytes32 public constant CREATE_VAULT_TYPEHASH =
        keccak256("CreateVault(address token,address vaultOwner,bytes32 userSalt,uint256 nonce,uint256 deadline)");

    address public immutable implementation;
    address public immutable controller;
    address public immutable feePolicy;
    ISponsoredTaskRegistry public immutable registry;

    address[] private _vaults;
    mapping(address vault => bool registered) public isVault;
    mapping(address vault => bytes32 vaultId) public vaultIdOf;
    mapping(bytes32 vaultId => address vault) public vaultOf;
    /// @notice The nonce `vaultOwner`'s next signed create must carry.
    mapping(address vaultOwner => uint256 nonce) public createNonces;

    error ZeroAddress();
    error InvalidContract(address account);
    error VaultAlreadyExists(address vault);
    error CreateSignatureExpired(uint256 deadline);
    error InvalidCreateSignature();

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

    constructor(address controller_, address feePolicy_, ISponsoredTaskRegistry registry_)
        EIP712("SponsoredTaskFactory", "2")
    {
        if (controller_ == address(0) || feePolicy_ == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        if (controller_.code.length == 0) revert InvalidContract(controller_);
        if (feePolicy_.code.length == 0) revert InvalidContract(feePolicy_);
        if (address(registry_).code.length == 0) revert InvalidContract(address(registry_));

        controller = controller_;
        feePolicy = feePolicy_;
        registry = registry_;
        implementation = address(new SponsoredTasksVaultV2());
    }

    /// @notice Create a vault owned by an EOA or contract wallet such as a Safe.
    /// @dev Including `msg.sender` in the deployment salt prevents another account from consuming
    ///      the caller's chosen salt. Funding is deliberately separate and permissionless.
    function createVault(address token, address vaultOwner, bytes32 userSalt)
        external
        returns (address vault, bytes32 vaultId)
    {
        return _createVault(msg.sender, token, vaultOwner, userSalt);
    }

    /// @notice Create a vault the owner authorized by signature, so a relayer can submit it. The
    ///         owner is the creator: the vault gets the address `createVault` from the owner would
    ///         give it, and `VaultCreated` names the owner as creator.
    function createVaultBySig(
        address token,
        address vaultOwner,
        bytes32 userSalt,
        uint256 deadline,
        bytes calldata signature
    ) external returns (address vault, bytes32 vaultId) {
        if (block.timestamp > deadline) revert CreateSignatureExpired(deadline);
        if (vaultOwner == address(0)) revert ZeroAddress();
        uint256 nonce = createNonces[vaultOwner];
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(CREATE_VAULT_TYPEHASH, token, vaultOwner, userSalt, nonce, deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(vaultOwner, digest, signature)) revert InvalidCreateSignature();
        createNonces[vaultOwner] = nonce + 1;
        return _createVault(vaultOwner, token, vaultOwner, userSalt);
    }

    /// @notice The EIP-712 digest a vault owner signs for `createVaultBySig`.
    function createVaultDigest(address token, address vaultOwner, bytes32 userSalt, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return
            _hashTypedDataV4(keccak256(abi.encode(CREATE_VAULT_TYPEHASH, token, vaultOwner, userSalt, nonce, deadline)));
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

    function _createVault(address creator, address token, address vaultOwner, bytes32 userSalt)
        private
        returns (address vault, bytes32 vaultId)
    {
        if (token == address(0) || vaultOwner == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert InvalidContract(token);

        bytes32 deploymentSalt = _deploymentSalt(creator, vaultOwner, token, userSalt);
        vault = Clones.predictDeterministicAddress(implementation, deploymentSalt, address(this));
        if (isVault[vault] || vault.code.length != 0) revert VaultAlreadyExists(vault);

        vault = Clones.cloneDeterministic(implementation, deploymentSalt);
        vaultId = keccak256(abi.encode(block.chainid, address(this), vault));

        isVault[vault] = true;
        vaultIdOf[vault] = vaultId;
        vaultOf[vaultId] = vault;
        _vaults.push(vault);

        SponsoredTasksVaultV2(vault).initialize(vaultId, token, vaultOwner, controller, feePolicy);
        registry.registerVault(vault, vaultId, IMPLEMENTATION_VERSION);

        emit VaultCreated(vaultId, vault, vaultOwner, creator, token, block.chainid, IMPLEMENTATION_VERSION, userSalt);
    }

    function _deploymentSalt(address creator, address vaultOwner, address token, bytes32 userSalt)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(creator, vaultOwner, token, userSalt));
    }
}
