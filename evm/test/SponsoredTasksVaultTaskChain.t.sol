// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";
import { VaultV2Base } from "./SponsoredTasksVaultV2.t.sol";

/// @dev Rev031: a vault's manager allowance is keyed by (task chain, manager). The entry points that
///      name no chain act on `block.chainid`; the chain-scoped ones name the task chain.
contract SponsoredTasksVaultTaskChainTest is VaultV2Base {
    uint16 internal constant FEE_BPS = 50;
    bytes32 internal constant TERMS_HASH = keccak256("task-chain-terms");
    uint256 internal constant BASE = 8453;
    uint256 internal constant TEMPO = 4217;

    SponsoredTasksVaultV2 internal vault;

    event ManagerConfigured(address indexed manager, uint256 cap, uint256 reserved, uint256 spent, bool active);
    event ManagerConfiguredForChain(
        uint256 indexed taskChainId, address indexed manager, uint256 cap, uint256 reserved, uint256 spent, bool active
    );

    function setUp() public override {
        super.setUp();
        (address vaultAddress,) = factory.createVault(address(token), vaultOwner, keccak256("task-chain"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        token.mint(address(this), 1_000e6);
        token.approve(address(vault), type(uint256).max);
        vault.fund(1_000e6);
    }

    function _reserveFor(uint256 taskChainId, bytes32 allocationId, uint256 amount) internal {
        vm.prank(controller);
        vault.reserveTaskForChain(
            allocationId,
            taskChainId,
            keccak256(abi.encode(allocationId)),
            manager,
            amount,
            1,
            FEE_BPS,
            feeRecipient,
            TERMS_HASH
        );
    }

    function _forChainSig(uint256 taskChainId, uint256 cap, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                vault.CONFIGURE_MANAGER_FOR_CHAIN_TYPEHASH(),
                vault.vaultId(),
                taskChainId,
                manager,
                cap,
                true,
                nonce,
                deadline
            )
        );
        return _sign(ownerKey, vault.ownerActionDigest(structHash));
    }

    function test_AllowanceForOneTaskChainIsNotSpentByAnother() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit ManagerConfiguredForChain(BASE, manager, 300e6, 0, 0, true);
        vm.prank(vaultOwner);
        vault.configureManagerForChain(BASE, manager, 300e6, true);

        assertEq(vault.managerRemainingForChain(BASE, manager), 300e6);
        assertEq(vault.managerRemainingForChain(TEMPO, manager), 0);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.ManagerNotActive.selector, manager));
        vault.reserveTaskForChain(
            keccak256("tempo"), TEMPO, keccak256("t"), manager, 100e6, 1, FEE_BPS, feeRecipient, TERMS_HASH
        );

        _reserveFor(BASE, keccak256("base"), 100e6);
        assertEq(vault.managerRemainingForChain(BASE, manager), 200e6);
        assertEq(vault.managerAccountForChain(BASE, manager).reserved, 100e6);
    }

    function test_EachTaskChainHasItsOwnCap() public {
        vm.startPrank(vaultOwner);
        vault.configureManagerForChain(BASE, manager, 300e6, true);
        vault.configureManagerForChain(TEMPO, manager, 50e6, true);
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTasksVaultV2.ManagerAllowanceExceeded.selector, manager, 100e6, 50e6)
        );
        vault.reserveTaskForChain(
            keccak256("tempo"), TEMPO, keccak256("t"), manager, 100e6, 1, FEE_BPS, feeRecipient, TERMS_HASH
        );
        _reserveFor(TEMPO, keccak256("tempo"), 50e6);
        _reserveFor(BASE, keccak256("base"), 100e6);
        assertEq(vault.managerRemainingForChain(TEMPO, manager), 0);
        assertEq(vault.managerRemainingForChain(BASE, manager), 200e6);
    }

    function test_ReleaseAndSettlementChargeTheReservedChain() public {
        vm.startPrank(vaultOwner);
        vault.configureManagerForChain(BASE, manager, 300e6, true);
        vault.configureManagerForChain(TEMPO, manager, 300e6, true);
        vm.stopPrank();

        bytes32 released = keccak256("released");
        _reserveFor(TEMPO, released, 100e6);
        vm.prank(controller);
        vault.releaseTask(released);
        assertEq(vault.managerAccountForChain(TEMPO, manager).reserved, 0);
        assertEq(vault.managerRemainingForChain(TEMPO, manager), 300e6);

        bytes32 settled = keccak256("settled");
        _reserveFor(BASE, settled, 100e6);
        vm.prank(controller);
        vault.installSettlement(settled, keccak256(abi.encode(settled)), bytes32(0), 0, 0, 0, 0);
        SponsoredTaskTypes.ManagerAccount memory base = vault.managerAccountForChain(BASE, manager);
        assertEq(base.reserved, 0);
        assertEq(base.spent, 0);
        assertEq(vault.managerAccountForChain(TEMPO, manager).spent, 0);
    }

    function test_UnscopedEntryPointsActOnThisChain() public {
        vm.chainId(BASE);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ManagerConfigured(manager, 200e6, 0, 0, true);
        vm.prank(vaultOwner);
        vault.configureManager(manager, 200e6, true);
        assertEq(vault.managerAccountForChain(BASE, manager).cap, 200e6);
        assertEq(vault.managerAccount(manager).cap, 200e6);

        vm.prank(controller);
        vault.reserveTask(keccak256("hook"), keccak256("task"), manager, 50e6, 1, FEE_BPS, feeRecipient, TERMS_HASH);
        assertEq(vault.managerRemaining(manager), 150e6);
        assertEq(vault.managerRemainingForChain(BASE, manager), 150e6);
        assertEq(vault.managerRemainingForChain(TEMPO, manager), 0);
    }

    function test_ConfigureManagerForChainBySigSharesTheOwnerNonce() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _forChainSig(TEMPO, 75e6, 0, deadline);
        vm.prank(relayer);
        vault.configureManagerForChainBySig(TEMPO, manager, 75e6, true, deadline, sig);
        assertEq(vault.managerAccountForChain(TEMPO, manager).cap, 75e6);
        assertEq(vault.ownerNonce(), 1);

        // The chain is signed: the same signature cannot configure another chain.
        bytes memory again = _forChainSig(TEMPO, 75e6, 1, deadline);
        vm.expectRevert(SponsoredTasksVaultV2.InvalidOwnerSignature.selector);
        vault.configureManagerForChainBySig(BASE, manager, 75e6, true, deadline, again);
    }

    /// @dev Clients tell a rev031 vault from an earlier one by version and gate the v2 signed
    ///      actions on a version of 2 or more: a version-3 vault takes them unchanged.
    function test_Rev031VaultReportsVersion3AndTakesTheV2SignedActions() public {
        assertEq(vault.VAULT_VERSION(), 3);
        assertEq(factory.IMPLEMENTATION_VERSION(), 3);
        vm.chainId(BASE);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(vault.CONFIGURE_MANAGER_TYPEHASH(), vault.vaultId(), manager, 40e6, true, uint256(0), deadline)
        );
        bytes memory sig = _sign(ownerKey, vault.ownerActionDigest(structHash));
        vm.prank(relayer);
        vault.configureManagerBySig(manager, 40e6, true, deadline, sig);
        assertEq(vault.managerAccount(manager).cap, 40e6);
        assertEq(vault.managerAccountForChain(BASE, manager).cap, 40e6);
    }

    function test_RevertWhen_TaskChainIsZero() public {
        vm.prank(vaultOwner);
        vm.expectRevert(SponsoredTasksVaultV2.TaskChainRequired.selector);
        vault.configureManagerForChain(0, manager, 1, true);
        vm.prank(controller);
        vm.expectRevert(SponsoredTasksVaultV2.TaskChainRequired.selector);
        vault.reserveTaskForChain(keccak256("a"), 0, keccak256("t"), manager, 1, 1, FEE_BPS, feeRecipient, TERMS_HASH);
    }

    function test_RevertWhen_ReserveTaskForChainIsNotTheController() public {
        vm.expectRevert(abi.encodeWithSelector(SponsoredTasksVaultV2.OnlyController.selector, address(this)));
        vault.reserveTaskForChain(
            keccak256("a"), BASE, keccak256("t"), manager, 1, 1, FEE_BPS, feeRecipient, TERMS_HASH
        );
    }
}
