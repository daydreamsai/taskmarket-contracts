// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";

/// @notice Minimal stand-in for a vault, with every field the registry reads independently
///         settable, so each of `registerVault`'s validation branches can be triggered on its own.
contract MockRegistryVault {
    bytes32 public vaultId;
    address public token;
    address public owner;
    address public controller;
    uint256 public settlementChain;
    uint64 public epoch;
    SponsoredTaskTypes.VaultStatus public status;

    constructor() {
        vaultId = keccak256("mock-vault");
        token = address(new MockRegistryVault_Token());
        owner = address(0xA11CE);
        controller = address(new MockRegistryVault_Token());
        settlementChain = block.chainid;
        epoch = 1;
        status = SponsoredTaskTypes.VaultStatus.Active;
    }

    function setVaultId(bytes32 v) external {
        vaultId = v;
    }

    function setToken(address v) external {
        token = v;
    }

    function setOwner(address v) external {
        owner = v;
    }

    function setController(address v) external {
        controller = v;
    }

    function setSettlementChain(uint256 v) external {
        settlementChain = v;
    }

    function setEpoch(uint64 v) external {
        epoch = v;
    }

    function setStatus(SponsoredTaskTypes.VaultStatus v) external {
        status = v;
    }
}

/// @dev A trivial contract with real code, standing in for a token/controller address in tests
///      that need `.code.length != 0` without pulling in a real ERC20 or Safe.
contract MockRegistryVault_Token { }

contract SponsoredTaskRegistryTest is Test {
    address internal owner = makeAddr("owner");
    address internal factory = makeAddr("factory");
    SponsoredTaskRegistry internal registry;
    MockRegistryVault internal vault;

    function setUp() public {
        registry = new SponsoredTaskRegistry(owner);
        vault = new MockRegistryVault();
        vm.etch(factory, hex"00");
        vm.prank(owner);
        registry.setFactory(factory, true);
    }

    function test_ConstructorRejectsZeroOwner() external {
        // Ownable's own constructor validates its argument before SponsoredTaskRegistry's body
        // ever runs, so OwnableInvalidOwner fires first -- SponsoredTaskRegistry's own
        // `ZeroAddress` check on the same input is unreachable dead code for this path.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SponsoredTaskRegistry(address(0));
    }

    function test_SetFactoryRejectsZeroAddress() external {
        vm.prank(owner);
        vm.expectRevert(SponsoredTaskRegistry.ZeroAddress.selector);
        registry.setFactory(address(0), true);
    }

    function test_SetFactoryRejectsNonContractWhenAuthorizing() external {
        address eoa = makeAddr("eoa");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskRegistry.InvalidContract.selector, eoa));
        registry.setFactory(eoa, true);
    }

    function test_SetFactoryAllowsDeauthorizingANonContractAddress() external {
        // Deauthorizing never needs the `code.length` check -- only authorizing does.
        address eoa = makeAddr("eoa");
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskRegistry.InvalidContract.selector, eoa));
        registry.setFactory(eoa, true);
        registry.setFactory(eoa, false);
        vm.stopPrank();
        assertFalse(registry.authorizedFactories(eoa));
    }

    function test_SetFactoryEmitsAndUpdatesAuthorization() external {
        address newFactory = makeAddr("newFactory2");
        vm.etch(newFactory, hex"00");
        vm.expectEmit(true, false, false, true);
        emit SponsoredTaskRegistry.FactoryAuthorizationUpdated(newFactory, true);
        vm.prank(owner);
        registry.setFactory(newFactory, true);
        assertTrue(registry.authorizedFactories(newFactory));
    }

    function test_RegisterVaultRejectsUnauthorizedCaller() external {
        bytes32 vid = vault.vaultId();
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskRegistry.UnauthorizedFactory.selector, address(this)));
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsZeroVaultAddress() external {
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.ZeroAddress.selector);
        registry.registerVault(address(0), keccak256("x"), 1);
    }

    function test_RegisterVaultRejectsZeroVaultId() external {
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.ZeroAddress.selector);
        registry.registerVault(address(vault), bytes32(0), 1);
    }

    function test_RegisterVaultRejectsNonContractVault() external {
        address eoa = makeAddr("notAVault");
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskRegistry.InvalidContract.selector, eoa));
        registry.registerVault(eoa, keccak256("x"), 1);
    }

    function test_RegisterVaultRejectsAlreadyRegisteredVaultAddress() external {
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        registry.registerVault(address(vault), vid, 1);

        vm.prank(factory);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskRegistry.VaultAlreadyRegistered.selector, address(vault), vid)
        );
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsReusedVaultId() external {
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        registry.registerVault(address(vault), vid, 1);

        MockRegistryVault other = new MockRegistryVault();
        other.setVaultId(vid);
        vm.prank(factory);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskRegistry.VaultAlreadyRegistered.selector, address(other), vid)
        );
        registry.registerVault(address(other), vid, 1);
    }

    function test_RegisterVaultRejectsVaultIdMismatch() external {
        bytes32 claimed = keccak256("claimed");
        bytes32 actual = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskRegistry.VaultIdentityMismatch.selector, claimed, actual));
        registry.registerVault(address(vault), claimed, 1);
    }

    function test_RegisterVaultRejectsInactiveStatus() external {
        vault.setStatus(SponsoredTaskTypes.VaultStatus.Exited);
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.VaultNotActive.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsNonInitialEpoch() external {
        vault.setEpoch(2);
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.VaultNotActive.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsZeroToken() external {
        vault.setToken(address(0));
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.InvalidVaultConfiguration.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsNonContractToken() external {
        vault.setToken(makeAddr("eoaToken"));
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.InvalidVaultConfiguration.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsZeroInitialOwner() external {
        vault.setOwner(address(0));
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.InvalidVaultConfiguration.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsZeroController() external {
        vault.setController(address(0));
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.InvalidVaultConfiguration.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsNonContractController() external {
        vault.setController(makeAddr("eoaController"));
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.InvalidVaultConfiguration.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsWrongSettlementChain() external {
        vault.setSettlementChain(block.chainid + 1);
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.InvalidVaultConfiguration.selector);
        registry.registerVault(address(vault), vid, 1);
    }

    function test_RegisterVaultRejectsZeroImplementationVersion() external {
        bytes32 vid = vault.vaultId();
        vm.prank(factory);
        vm.expectRevert(SponsoredTaskRegistry.InvalidVaultConfiguration.selector);
        registry.registerVault(address(vault), vid, 0);
    }

    function test_RegisterVaultSucceedsAndRecordsCanonicalFields() external {
        bytes32 vid = vault.vaultId();
        address token = vault.token();
        address initialOwner = vault.owner();
        address controller = vault.controller();

        vm.expectEmit(true, true, true, true);
        emit SponsoredTaskRegistry.VaultRegistered(
            vid, address(vault), factory, token, initialOwner, controller, block.chainid, 3
        );
        vm.prank(factory);
        registry.registerVault(address(vault), vid, 3);

        assertTrue(registry.isVault(address(vault)));
        assertEq(registry.vaultIdOf(address(vault)), vid);
        assertEq(registry.vaultOf(vid), address(vault));

        SponsoredTaskRegistry.VaultRecord memory record = registry.vaultRecord(address(vault));
        assertEq(record.vaultId, vid);
        assertEq(record.factory, factory);
        assertEq(record.token, token);
        assertEq(record.initialVaultOwner, initialOwner);
        assertEq(record.controller, controller);
        assertEq(record.settlementChain, block.chainid);
        assertEq(record.implementationVersion, 3);
    }

    function test_IsVaultAndVaultIdOfReturnDefaultsForUnregisteredAddress() external view {
        assertFalse(registry.isVault(address(vault)));
        assertEq(registry.vaultIdOf(address(vault)), bytes32(0));
    }
}
