// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTasksVault } from "../src/hooks/sponsored-task/SponsoredTasksVault.sol";
import { ISponsoredTaskRegistry } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskRegistry.sol";

contract SafeCompatibleOwnerMock { }

contract SponsoredTaskFactoryTest is Test {
    address internal controller;
    address internal policyOwner = makeAddr("policyOwner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal creator = makeAddr("creator");
    address internal vaultOwner = makeAddr("vaultOwner");
    bytes32 internal constant USER_SALT = keccak256("launch-one");

    MockERC20 internal token;
    SponsoredTaskFeePolicy internal policy;
    SponsoredTaskRegistry internal registry;
    SponsoredTaskFactory internal factory;

    function setUp() public {
        controller = address(new SafeCompatibleOwnerMock());
        token = new MockERC20("Project", "PROJECT", 18, address(this));
        policy = new SponsoredTaskFeePolicy(policyOwner, 50, feeRecipient);
        registry = new SponsoredTaskRegistry(address(this));
        factory = new SponsoredTaskFactory(
            controller, address(policy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
        registry.setFactory(address(factory), true);
    }

    function test_CreateVaultMatchesPredictionAndRegistersCanonicalFields() public {
        address predicted = factory.predictVault(creator, vaultOwner, address(token), USER_SALT);
        vm.prank(creator);
        (address vaultAddress, bytes32 vaultId) = factory.createVault(address(token), vaultOwner, USER_SALT);
        SponsoredTasksVault vault = SponsoredTasksVault(vaultAddress);

        assertEq(vaultAddress, predicted);
        assertTrue(factory.isVault(vaultAddress));
        assertEq(factory.vaultIdOf(vaultAddress), vaultId);
        assertEq(factory.vaultOf(vaultId), vaultAddress);
        assertTrue(registry.isVault(vaultAddress));
        assertEq(registry.vaultIdOf(vaultAddress), vaultId);
        assertEq(registry.vaultOf(vaultId), vaultAddress);
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultAt(0), vaultAddress);
        assertEq(vaultId, keccak256(abi.encode(block.chainid, address(factory), vaultAddress)));
        assertEq(vault.vaultId(), vaultId);
        assertEq(vault.token(), address(token));
        assertEq(vault.owner(), vaultOwner);
        assertEq(vault.controller(), controller);
        assertEq(address(vault.feePolicy()), address(policy));
        assertEq(vault.settlementChain(), block.chainid);
        assertEq(vault.epoch(), 1);
        assertEq(uint256(vault.status()), uint256(SponsoredTaskTypes.VaultStatus.Active));
        assertEq(factory.IMPLEMENTATION_VERSION(), 1);
        assertGt(factory.implementation().code.length, 0);
    }

    function test_CreateVaultAllowsContractWalletOwner() public {
        SafeCompatibleOwnerMock safe = new SafeCompatibleOwnerMock();
        vm.prank(creator);
        (address vaultAddress,) = factory.createVault(address(token), address(safe), USER_SALT);
        assertEq(SponsoredTasksVault(vaultAddress).owner(), address(safe));
    }

    function test_SettlementChainIsCapturedAtInitialization() public {
        vm.prank(creator);
        (address vaultAddress,) = factory.createVault(address(token), vaultOwner, USER_SALT);
        uint256 capturedChain = SponsoredTasksVault(vaultAddress).settlementChain();
        vm.chainId(capturedChain + 1);
        assertEq(SponsoredTasksVault(vaultAddress).settlementChain(), capturedChain);
    }

    function test_DuplicateCreatorConfigurationAndSaltReverts() public {
        address predicted = factory.predictVault(creator, vaultOwner, address(token), USER_SALT);
        vm.prank(creator);
        factory.createVault(address(token), vaultOwner, USER_SALT);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactory.VaultAlreadyExists.selector, predicted));
        factory.createVault(address(token), vaultOwner, USER_SALT);
    }

    function test_SameSaltIsNamespacedByCreator() public {
        address secondCreator = makeAddr("secondCreator");
        vm.prank(creator);
        (address first,) = factory.createVault(address(token), vaultOwner, USER_SALT);
        vm.prank(secondCreator);
        (address second,) = factory.createVault(address(token), vaultOwner, USER_SALT);

        assertTrue(first != second);
        assertEq(factory.vaultCount(), 2);
        assertEq(first, factory.predictVault(creator, vaultOwner, address(token), USER_SALT));
        assertEq(second, factory.predictVault(secondCreator, vaultOwner, address(token), USER_SALT));
    }

    function test_SameTokenVaultsAreAccountingIsolated() public {
        vm.prank(creator);
        (address first,) = factory.createVault(address(token), vaultOwner, bytes32(uint256(1)));
        vm.prank(creator);
        (address second,) = factory.createVault(address(token), vaultOwner, bytes32(uint256(2)));

        token.mint(creator, 100 ether);
        vm.startPrank(creator);
        token.approve(first, 100 ether);
        SponsoredTasksVault(first).fund(100 ether);
        vm.stopPrank();

        assertEq(SponsoredTasksVault(first).available(), 100 ether);
        assertEq(SponsoredTasksVault(first).totalFunded(), 100 ether);
        assertEq(SponsoredTasksVault(second).available(), 0);
        assertEq(SponsoredTasksVault(second).totalFunded(), 0);
    }

    function test_UniqueSaltOwnerOrTokenCreatesDistinctVault() public {
        MockERC20 secondToken = new MockERC20("Second", "SECOND", 18, address(this));
        address secondOwner = makeAddr("secondOwner");

        vm.startPrank(creator);
        (address first,) = factory.createVault(address(token), vaultOwner, USER_SALT);
        (address bySalt,) = factory.createVault(address(token), vaultOwner, keccak256("other-salt"));
        (address byOwner,) = factory.createVault(address(token), secondOwner, USER_SALT);
        (address byToken,) = factory.createVault(address(secondToken), vaultOwner, USER_SALT);
        vm.stopPrank();

        assertTrue(first != bySalt);
        assertTrue(first != byOwner);
        assertTrue(first != byToken);
        assertEq(factory.vaultCount(), 4);
    }

    function test_CreateVaultValidatesOwnerAndToken() public {
        vm.prank(creator);
        vm.expectRevert(SponsoredTaskFactory.ZeroAddress.selector);
        factory.createVault(address(token), address(0), USER_SALT);

        vm.prank(creator);
        vm.expectRevert(SponsoredTaskFactory.ZeroAddress.selector);
        factory.createVault(address(0), vaultOwner, USER_SALT);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactory.InvalidContract.selector, makeAddr("notToken")));
        factory.createVault(makeAddr("notToken"), vaultOwner, USER_SALT);
    }

    function test_ConstructorValidatesControllerAndFeePolicy() public {
        vm.expectRevert(SponsoredTaskFactory.ZeroAddress.selector);
        new SponsoredTaskFactory(
            address(0), address(policy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );

        vm.expectRevert(SponsoredTaskFactory.ZeroAddress.selector);
        new SponsoredTaskFactory(controller, address(0), registry, SponsoredTaskFeeConfig.none(IERC20(address(token))));

        vm.expectRevert(SponsoredTaskFactory.ZeroAddress.selector);
        new SponsoredTaskFactory(
            controller,
            address(policy),
            ISponsoredTaskRegistry(address(0)),
            SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );

        address notPolicy = makeAddr("notPolicy");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactory.InvalidContract.selector, notPolicy));
        new SponsoredTaskFactory(controller, notPolicy, registry, SponsoredTaskFeeConfig.none(IERC20(address(token))));

        address notController = makeAddr("notController");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactory.InvalidContract.selector, notController));
        new SponsoredTaskFactory(
            notController, address(policy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );

        address notRegistry = makeAddr("notRegistry");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskFactory.InvalidContract.selector, notRegistry));
        new SponsoredTaskFactory(
            controller,
            address(policy),
            ISponsoredTaskRegistry(notRegistry),
            SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
    }

    function test_CreateVaultRequiresAuthorizedFactoryAndRollsBackClone() public {
        SponsoredTaskFactory unauthorized = new SponsoredTaskFactory(
            controller, address(policy), registry, SponsoredTaskFeeConfig.none(IERC20(address(token)))
        );
        address predicted = unauthorized.predictVault(creator, vaultOwner, address(token), USER_SALT);

        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskRegistry.UnauthorizedFactory.selector, address(unauthorized))
        );
        unauthorized.createVault(address(token), vaultOwner, USER_SALT);

        assertEq(predicted.code.length, 0);
        assertFalse(unauthorized.isVault(predicted));
        assertFalse(registry.isVault(predicted));
    }

    function test_FactoryImplementationCannotBeInitialized() public {
        SponsoredTasksVault implementation = SponsoredTasksVault(factory.implementation());
        vm.expectRevert();
        implementation.initialize(keccak256("implementation"), address(token), vaultOwner, controller, address(policy));
    }

    function test_CreateVaultPaysTheOneTimeCreationFee() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        address creationFeeRecipient = makeAddr("creationFeeRecipient");
        SponsoredTaskFactory charging = new SponsoredTaskFactory(
            controller,
            address(policy),
            registry,
            SponsoredTaskFeeConfig.charging(IERC20(address(usdc)), 1_000_000, creationFeeRecipient)
        );
        registry.setFactory(address(charging), true);
        usdc.mint(creator, 1_000_000);

        vm.prank(creator);
        vm.expectRevert();
        charging.createVault(address(token), vaultOwner, USER_SALT);

        vm.startPrank(creator);
        usdc.approve(address(charging), 1_000_000);
        (address vault,) = charging.createVault(address(token), vaultOwner, USER_SALT);
        vm.stopPrank();

        assertTrue(charging.isVault(vault));
        assertEq(usdc.balanceOf(creationFeeRecipient), 1_000_000);
        assertEq(usdc.balanceOf(creator), 0);
        assertEq(usdc.balanceOf(address(charging)), 0);
    }
}
