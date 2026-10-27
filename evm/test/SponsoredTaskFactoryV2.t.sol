// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";
import { VaultV2Base, VaultV2ContractWallet } from "./SponsoredTasksVaultV2.t.sol";

contract SponsoredTaskFactoryV2Test is VaultV2Base {
    bytes32 internal constant SALT = keccak256("launch");

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

    function _createSig(uint256 key, address owner_, bytes32 salt, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(key, factory.createVaultDigest(address(token), owner_, salt, nonce, deadline));
    }

    function test_CreateVaultBySig_OwnerIsTheCreator() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        address predicted = factory.predictVault(vaultOwner, vaultOwner, address(token), SALT);
        bytes memory sig = _createSig(ownerKey, vaultOwner, SALT, 0, deadline);

        vm.expectEmit(false, true, true, false, address(factory));
        emit VaultCreated(bytes32(0), predicted, vaultOwner, vaultOwner, address(token), block.chainid, 2, SALT);
        vm.prank(relayer);
        (address vault, bytes32 vaultId) = factory.createVaultBySig(address(token), vaultOwner, SALT, deadline, sig);

        assertEq(vault, predicted);
        assertTrue(factory.isVault(vault));
        assertEq(factory.vaultOf(vaultId), vault);
        assertTrue(registry.isVault(vault));
        assertEq(SponsoredTasksVaultV2(vault).owner(), vaultOwner);
        assertEq(SponsoredTasksVaultV2(vault).VAULT_VERSION(), 2);
        assertEq(factory.createNonces(vaultOwner), 1);
        assertEq(factory.IMPLEMENTATION_VERSION(), 2);
    }

    function test_RevertWhen_CreateSignatureIsReplayed() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(ownerKey, vaultOwner, SALT, 0, deadline);
        factory.createVaultBySig(address(token), vaultOwner, SALT, deadline, sig);
        vm.expectRevert(SponsoredTaskFactoryV2.InvalidCreateSignature.selector);
        factory.createVaultBySig(address(token), vaultOwner, SALT, deadline, sig);
    }

    function test_RevertWhen_CreateSignatureExpired() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(ownerKey, vaultOwner, SALT, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactoryV2.CreateSignatureExpired.selector, deadline));
        factory.createVaultBySig(address(token), vaultOwner, SALT, deadline, sig);
    }

    function test_RevertWhen_CreateSignedByAnotherKey() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(strangerKey, vaultOwner, SALT, 0, deadline);
        vm.expectRevert(SponsoredTaskFactoryV2.InvalidCreateSignature.selector);
        factory.createVaultBySig(address(token), vaultOwner, SALT, deadline, sig);
    }

    function test_RevertWhen_CreateSignatureIsUsedForAnotherToken() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(ownerKey, vaultOwner, SALT, 0, deadline);
        vm.expectRevert(SponsoredTaskFactoryV2.InvalidCreateSignature.selector);
        factory.createVaultBySig(address(policy), vaultOwner, SALT, deadline, sig);
    }

    function test_RevertWhen_CreateBySigOwnerIsZero() public {
        vm.expectRevert(SponsoredTaskFactoryV2.ZeroAddress.selector);
        factory.createVaultBySig(address(token), address(0), SALT, vm.getBlockTimestamp(), "");
    }

    function test_ContractWalletOwnerCreatesThroughErc1271() public {
        VaultV2ContractWallet safe = new VaultV2ContractWallet(vm.addr(ownerKey));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(ownerKey, address(safe), SALT, 0, deadline);
        vm.prank(relayer);
        (address vault,) = factory.createVaultBySig(address(token), address(safe), SALT, deadline, sig);
        assertEq(SponsoredTasksVaultV2(vault).owner(), address(safe));
    }

    function test_PlainCreateVaultStillWorks() public {
        vm.prank(relayer);
        (address vault,) = factory.createVault(address(token), vaultOwner, SALT);
        assertEq(vault, factory.predictVault(relayer, vaultOwner, address(token), SALT));
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultAt(0), vault);
        assertEq(factory.vaultIdOf(vault), keccak256(abi.encode(block.chainid, address(factory), vault)));
    }

    function test_RevertWhen_VaultAlreadyExists() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        vm.prank(vaultOwner);
        factory.createVault(address(token), vaultOwner, SALT);
        address existing = factory.predictVault(vaultOwner, vaultOwner, address(token), SALT);
        bytes memory sig = _createSig(ownerKey, vaultOwner, SALT, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactoryV2.VaultAlreadyExists.selector, existing));
        factory.createVaultBySig(address(token), vaultOwner, SALT, deadline, sig);
    }

    function test_RevertWhen_TokenIsNotAContract() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactoryV2.InvalidContract.selector, eoa));
        factory.createVault(eoa, vaultOwner, SALT);
        vm.expectRevert(SponsoredTaskFactoryV2.ZeroAddress.selector);
        factory.createVault(address(0), vaultOwner, SALT);
    }

    function test_RevertWhen_ConstructorArgumentsAreInvalid() public {
        vm.expectRevert(SponsoredTaskFactoryV2.ZeroAddress.selector);
        new SponsoredTaskFactoryV2(address(0), address(policy), registry);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactoryV2.InvalidContract.selector, eoa));
        new SponsoredTaskFactoryV2(eoa, address(policy), registry);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactoryV2.InvalidContract.selector, eoa));
        new SponsoredTaskFactoryV2(controller, eoa, registry);
    }
}
