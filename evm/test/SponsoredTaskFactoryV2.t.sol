// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { SponsoredTaskCreationFee } from "../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
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
        new SponsoredTaskFactoryV2(
            address(0), address(policy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactoryV2.InvalidContract.selector, eoa));
        new SponsoredTaskFactoryV2(eoa, address(policy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token))));
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactoryV2.InvalidContract.selector, eoa));
        new SponsoredTaskFactoryV2(controller, eoa, registry, SponsoredTaskFeeConfig.none(IERC20(address(token))));
    }
}

/// @notice The one-time vault creation fee on the v2 factory: paid by the creator in the
///         creation call, straight to the fee recipient, by allowance or by an EIP-3009
///         authorization bound to the signed create.
contract SponsoredTaskFactoryV2CreationFeeTest is VaultV2Base {
    bytes32 internal constant SALT = keccak256("fee");
    uint256 internal constant FEE = 1_000_000;
    address internal creationFeeRecipient = makeAddr("creationFeeRecipient");

    MockUSDC internal usdc;
    SponsoredTaskFactoryV2 internal feeFactory;

    function setUp() public override {
        super.setUp();
        usdc = new MockUSDC();
        feeFactory = new SponsoredTaskFactoryV2(
            controller,
            address(policy),
            registry,
            SponsoredTaskFeeConfig.charging(IERC20(address(usdc)), FEE, creationFeeRecipient)
        );
        registry.setFactory(address(feeFactory), true);
        usdc.mint(vaultOwner, 10 * FEE);
    }

    function _createSig(bytes32 salt, uint256 nonce, uint256 deadline) internal view returns (bytes memory) {
        return _sign(ownerKey, feeFactory.createVaultDigest(address(token), vaultOwner, salt, nonce, deadline));
    }

    function _feeAuthorization(uint256 key, address from, uint256 value, bytes32 nonce, uint256 validBefore)
        internal
        view
        returns (SponsoredTaskFactoryV2.FeeAuthorization memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, address(feeFactory), value, 0, validBefore, nonce)
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USD Coin")),
                keccak256(bytes("2")),
                block.chainid,
                address(usdc)
            )
        );
        return SponsoredTaskFactoryV2.FeeAuthorization({
            validAfter: 0,
            validBefore: validBefore,
            signature: _sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)))
        });
    }

    function test_CreateVaultPaysTheFeeOnceToTheRecipient() public {
        vm.startPrank(vaultOwner);
        usdc.approve(address(feeFactory), FEE);
        (address vault,) = feeFactory.createVault(address(token), vaultOwner, SALT);
        vm.stopPrank();

        assertTrue(feeFactory.isVault(vault));
        assertEq(usdc.balanceOf(creationFeeRecipient), FEE);
        assertEq(usdc.balanceOf(vaultOwner), 9 * FEE);
        assertEq(usdc.balanceOf(address(feeFactory)), 0);
    }

    function test_RevertWhen_CreatorHasNotApprovedTheFee() public {
        vm.prank(vaultOwner);
        vm.expectRevert();
        feeFactory.createVault(address(token), vaultOwner, SALT);
        assertEq(feeFactory.vaultCount(), 0);
    }

    function test_RevertWhen_CreatorCannotPayTheFee() public {
        address broke = makeAddr("broke");
        vm.startPrank(broke);
        usdc.approve(address(feeFactory), FEE);
        vm.expectRevert();
        feeFactory.createVault(address(token), broke, SALT);
        vm.stopPrank();
        assertEq(feeFactory.vaultCount(), 0);
        assertEq(usdc.balanceOf(creationFeeRecipient), 0);
    }

    function test_CreateVaultBySigWithFeeAuthorizationIsGaslessForTheOwner() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(SALT, 0, deadline);
        SponsoredTaskFactoryV2.FeeAuthorization memory fee =
            _feeAuthorization(ownerKey, vaultOwner, FEE, feeFactory.feeAuthorizationNonce(vaultOwner, 0), deadline);

        vm.prank(relayer);
        (address vault,) =
            feeFactory.createVaultBySigWithFeeAuthorization(address(token), vaultOwner, SALT, deadline, sig, fee);

        assertEq(SponsoredTasksVaultV2(vault).owner(), vaultOwner);
        assertEq(usdc.balanceOf(creationFeeRecipient), FEE);
        assertEq(usdc.balanceOf(vaultOwner), 9 * FEE);
        assertEq(usdc.balanceOf(address(feeFactory)), 0);
        assertEq(usdc.balanceOf(relayer), 0);
    }

    function test_RevertWhen_FeeAuthorizationIsForAnotherCreate() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(SALT, 0, deadline);
        // Signed for create nonce 1, not the create nonce 0 being used.
        SponsoredTaskFactoryV2.FeeAuthorization memory fee =
            _feeAuthorization(ownerKey, vaultOwner, FEE, feeFactory.feeAuthorizationNonce(vaultOwner, 1), deadline);
        vm.expectRevert();
        feeFactory.createVaultBySigWithFeeAuthorization(address(token), vaultOwner, SALT, deadline, sig, fee);
        assertEq(feeFactory.createNonces(vaultOwner), 0);
    }

    function test_RevertWhen_FeeAuthorizationIsSignedByAnotherKey() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _createSig(SALT, 0, deadline);
        SponsoredTaskFactoryV2.FeeAuthorization memory fee =
            _feeAuthorization(strangerKey, vaultOwner, FEE, feeFactory.feeAuthorizationNonce(vaultOwner, 0), deadline);
        vm.expectRevert();
        feeFactory.createVaultBySigWithFeeAuthorization(address(token), vaultOwner, SALT, deadline, sig, fee);
    }

    function test_CreateVaultBySigPullsTheFeeFromTheOwnersAllowance() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        vm.prank(vaultOwner);
        usdc.approve(address(feeFactory), FEE);
        bytes memory sig = _createSig(SALT, 0, deadline);
        vm.prank(relayer);
        feeFactory.createVaultBySig(address(token), vaultOwner, SALT, deadline, sig);
        assertEq(usdc.balanceOf(creationFeeRecipient), FEE);
    }

    function test_FeeIsNotRefundedWhenTheVaultExits() public {
        vm.startPrank(vaultOwner);
        usdc.approve(address(feeFactory), FEE);
        (address vault,) = feeFactory.createVault(address(token), vaultOwner, SALT);
        SponsoredTasksVaultV2(vault).emergencyExitVault(vaultOwner);
        vm.stopPrank();
        assertEq(usdc.balanceOf(creationFeeRecipient), FEE);
        assertEq(usdc.balanceOf(vaultOwner), 9 * FEE);
    }

    function test_ZeroFeeChargesNothing() public {
        feeFactory.setCreationFee(0, address(0));
        vm.prank(vaultOwner);
        feeFactory.createVault(address(token), vaultOwner, SALT);
        assertEq(usdc.balanceOf(vaultOwner), 10 * FEE);
    }

    function test_AdminChangesTheFeeWithinTheCeiling() public {
        address next = makeAddr("next");
        feeFactory.setCreationFee(2 * FEE, next);
        assertEq(feeFactory.creationFee(), 2 * FEE);
        assertEq(feeFactory.creationFeeRecipient(), next);

        uint256 ceiling = feeFactory.feeCeiling();
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskCreationFee.FeeCeilingExceeded.selector, ceiling + 1, ceiling)
        );
        feeFactory.setCreationFee(ceiling + 1, next);

        vm.expectRevert(SponsoredTaskCreationFee.FeeRecipientRequired.selector);
        feeFactory.setCreationFee(FEE, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskCreationFee.FeeRecipientInvalid.selector, address(feeFactory))
        );
        feeFactory.setCreationFee(FEE, address(feeFactory));
    }

    function test_RevertWhen_StrangerChangesTheFee() public {
        vm.prank(relayer);
        vm.expectRevert();
        feeFactory.setCreationFee(0, address(0));
    }

    function test_AdminMustStayAContract() public {
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskCreationFee.FeeAdminMustBeContract.selector, relayer));
        feeFactory.transferOwnership(relayer);
        vm.expectRevert(SponsoredTaskCreationFee.OwnershipRenunciationDisabled.selector);
        feeFactory.renounceOwnership();
    }

    function test_RevertWhen_ConstructedWithAnEoaAdminOrAFeeAboveTheCeiling() public {
        SponsoredTaskCreationFee.CreationFeeConfig memory config =
            SponsoredTaskFeeConfig.charging(IERC20(address(usdc)), FEE, creationFeeRecipient);
        config.admin = relayer;
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskCreationFee.FeeAdminMustBeContract.selector, relayer));
        new SponsoredTaskFactoryV2(controller, address(policy), registry, config);

        config.admin = address(this);
        config.ceiling = FEE - 1;
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskCreationFee.FeeCeilingExceeded.selector, FEE, FEE - 1));
        new SponsoredTaskFactoryV2(controller, address(policy), registry, config);

        config.ceiling = FEE;
        config.token = IERC20(address(0));
        vm.expectRevert(SponsoredTaskCreationFee.FeeTokenRequired.selector);
        new SponsoredTaskFactoryV2(controller, address(policy), registry, config);
    }
}
