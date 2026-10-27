// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { IERC3009Receive } from "./interfaces/IERC3009Receive.sol";
import { SponsoredTasksVault } from "./SponsoredTasksVault.sol";

/// @title SponsoredTasksVaultV2
/// @notice The v1 vault plus owner actions authorized by the owner's signature and
///         funding authorized by the funder's EIP-3009 signature, so anyone (a relayer) can submit
///         them and pay the gas. Every v1 entry point is unchanged.
/// @dev Signed owner actions are EIP-712 typed data in this vault's own domain (the vault is the
///      verifying contract), checked against the current `owner()` with `SignatureChecker`, so an
///      ERC-1271 owner such as a Safe signs too. Each carries the vault's sequential `ownerNonce`
///      and a `deadline`: a signature works once, only on this vault and chain, only before its
///      deadline, and only while its signer is still the owner. Completing an ownership transfer
///      also advances the nonce. Advancing the nonce with
///      `cancelOwnerSignatures` revokes every outstanding signed action.
/// @dev A relayer that submits one of these calls only pays its gas. It cannot change what was
///      signed, and every token movement pays the recipient or the vault the signer named.
contract SponsoredTasksVaultV2 is SponsoredTasksVault {
    uint32 public constant VAULT_VERSION = 2;

    bytes32 public constant CONFIGURE_MANAGER_TYPEHASH = keccak256(
        "ConfigureManager(bytes32 vaultId,address manager,uint256 cap,bool active,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant WITHDRAW_AVAILABLE_TYPEHASH = keccak256(
        "WithdrawAvailable(bytes32 vaultId,address recipient,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant EMERGENCY_EXIT_TYPEHASH =
        keccak256("EmergencyExitVault(bytes32 vaultId,address recipient,uint256 nonce,uint256 deadline)");

    /// @notice The nonce the owner's next signed action must carry.
    uint256 public ownerNonce;

    error OwnerSignatureExpired(uint256 deadline);
    error InvalidOwnerSignature();

    event OwnerSignatureUsed(address indexed owner, uint256 indexed nonce);

    /// @notice `configureManager`, authorized by the owner's signature instead of the caller.
    function configureManagerBySig(
        address manager,
        uint256 newCap,
        bool active,
        uint256 deadline,
        bytes calldata signature
    ) external onlyActive {
        uint256 nonce = ownerNonce;
        _useOwnerSignature(
            keccak256(abi.encode(CONFIGURE_MANAGER_TYPEHASH, vaultId, manager, newCap, active, nonce, deadline)),
            deadline,
            signature
        );
        _configureManager(manager, newCap, active);
    }

    /// @notice `withdrawAvailable`, authorized by the owner's signature instead of the caller.
    function withdrawAvailableBySig(address recipient, uint256 amount, uint256 deadline, bytes calldata signature)
        external
        onlyActive
        nonReentrant
    {
        uint256 nonce = ownerNonce;
        address vaultOwner = _useOwnerSignature(
            keccak256(abi.encode(WITHDRAW_AVAILABLE_TYPEHASH, vaultId, recipient, amount, nonce, deadline)),
            deadline,
            signature
        );
        _withdrawAvailable(vaultOwner, recipient, amount);
    }

    /// @notice `emergencyExitVault`, authorized by the owner's signature instead of the caller.
    function emergencyExitVaultBySig(address recipient, uint256 deadline, bytes calldata signature)
        external
        onlyActive
        nonReentrant
        returns (uint256 amount)
    {
        uint256 nonce = ownerNonce;
        address vaultOwner = _useOwnerSignature(
            keccak256(abi.encode(EMERGENCY_EXIT_TYPEHASH, vaultId, recipient, nonce, deadline)), deadline, signature
        );
        return _emergencyExitVault(vaultOwner, recipient);
    }

    /// @notice Revokes every outstanding signed owner action by advancing the nonce.
    function cancelOwnerSignatures() external onlyOwner {
        uint256 nonce = ownerNonce;
        ownerNonce = nonce + 1;
        emit OwnerSignatureUsed(msg.sender, nonce);
    }

    /// @dev Every completed ownership transfer advances `ownerNonce`, so a signature an earlier
    ///      owner made cannot become valid again if ownership later returns to them. Setting the
    ///      first owner at initialization leaves the nonce at zero. Only `acceptOwnership` reaches
    ///      here after initialization; starting a two-step transfer does not.
    function _transferOwnership(address newOwner) internal override {
        address previousOwner = owner();
        super._transferOwnership(newOwner);
        if (previousOwner != address(0)) {
            uint256 nonce = ownerNonce;
            ownerNonce = nonce + 1;
            emit OwnerSignatureUsed(previousOwner, nonce);
        }
    }

    /// @notice Fund the vault straight from `funder` with their EIP-3009 authorization, so a
    ///         relayer can submit it. Only a token that implements `receiveWithAuthorization`
    ///         supports it. `totalFunded` and `VaultFunded` record `funder`, exactly as `fund`
    ///         would for a funder that sent the transaction itself.
    /// @dev The token refuses the authorization unless this vault is its `to`, so it cannot be
    ///      redirected; replay is the token's own nonce check.
    function fundWithAuthorization(
        address funder,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external onlyActive nonReentrant {
        if (funder == address(0)) revert ZeroAddress();
        (uint256 balanceBefore, uint256 funderBalanceBefore) = _fundingSnapshot(funder, amount);
        IERC3009Receive(address(projectToken))
            .receiveWithAuthorization(funder, address(this), amount, validAfter, validBefore, nonce, signature);
        _recordFunding(funder, amount, balanceBefore, funderBalanceBefore);
    }

    /// @notice The EIP-712 digest the owner signs for a struct hash, for clients and tests.
    function ownerActionDigest(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /// @dev Checks the current owner signed `structHash` before `deadline` and spends the nonce.
    function _useOwnerSignature(bytes32 structHash, uint256 deadline, bytes calldata signature)
        private
        returns (address vaultOwner)
    {
        if (block.timestamp > deadline) revert OwnerSignatureExpired(deadline);
        vaultOwner = owner();
        if (!SignatureChecker.isValidSignatureNow(vaultOwner, _hashTypedDataV4(structHash), signature)) {
            revert InvalidOwnerSignature();
        }
        uint256 nonce = ownerNonce;
        ownerNonce = nonce + 1;
        emit OwnerSignatureUsed(vaultOwner, nonce);
    }
}
