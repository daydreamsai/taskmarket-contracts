// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { SponsoredTaskTypes } from "../src/hooks/sponsored-task/SponsoredTaskTypes.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeeConfig } from "./helpers/SponsoredTaskFeeConfig.sol";
import { SponsoredTasksVaultV2 } from "../src/hooks/sponsored-task/SponsoredTasksVaultV2.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { MockTaskmarketForSponsoredTask } from "./SponsoredTaskHook.t.sol";

/// @notice Covers SponsoredTaskHook's own validation branches -- constructor guards,
///         `_requireMatchingVault`'s per-field mismatch checks, `_validateFundingRequest`'s
///         rejection conditions, and the terminal-state guards on `finalizeRelease`/`reconcile`/
///         `refreshOwnerDefault` -- that the main behavioral suite in SponsoredTaskHook.t.sol
///         doesn't need to exercise on its own happy/dispute paths.
contract SponsoredTaskHookValidationTest is Test {
    bytes32 private constant TASK_ID = keccak256("validation-task");
    uint256 private constant NATIVE_REWARD = 1_000_000;
    uint256 private constant GROSS = 10_000;
    uint16 private constant TOKEN_FEE_BPS = 50;
    address private constant MANAGER = address(0xCAFE);
    address private constant TOKEN_FEE_RECIPIENT = address(0xFEE1);
    address private constant CREATION_FEE_RECIPIENT = address(0xFEE2);

    MockTaskmarketForSponsoredTask private market;
    MockERC20 private usdc;
    MockERC20 private projectToken;
    SponsoredTaskFeePolicy private feePolicy;
    SponsoredTaskRegistry private registry;
    SponsoredTaskFactoryV2 private factory;
    SponsoredTaskHook private hook;
    SponsoredTasksVaultV2 private vault;

    function setUp() external {
        market = new MockTaskmarketForSponsoredTask();
        usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        projectToken = new MockERC20("Project", "PROJECT", 18, address(this));
        feePolicy = new SponsoredTaskFeePolicy(address(this), TOKEN_FEE_BPS, TOKEN_FEE_RECIPIENT);
        registry = new SponsoredTaskRegistry(address(this));
        hook = new SponsoredTaskHook(address(market), IERC20(address(usdc)), registry);

        factory = new SponsoredTaskFactoryV2(
            address(hook), address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(factory), true);
        (address vaultAddress,) = factory.createVault(address(projectToken), address(this), keccak256("hook-vault"));
        vault = SponsoredTasksVaultV2(vaultAddress);
        vault.configureManager(MANAGER, GROSS * 100, true);
        projectToken.mint(address(this), GROSS * 100);
        projectToken.approve(address(vault), type(uint256).max);
        vault.fund(GROSS * 100);

        usdc.mint(MANAGER, 10_000_000);

        market.primeTask(TASK_ID, MANAGER, address(usdc), NATIVE_REWARD, TMP_BOUNTY, address(hook));
    }

    // ---------------------------------------------------------------------
    // constructor
    // ---------------------------------------------------------------------

    function test_ConstructorRejectsZeroDependencies() external {
        vm.expectRevert(SponsoredTaskHook.ZeroAddress.selector);
        new SponsoredTaskHook(address(market), IERC20(address(0)), registry);

        vm.expectRevert(SponsoredTaskHook.ZeroAddress.selector);
        new SponsoredTaskHook(address(market), IERC20(address(usdc)), SponsoredTaskRegistry(address(0)));
    }

    function test_ConstructorRejectsNonContractDependencies() external {
        address eoaToken = makeAddr("eoaToken");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHook.InvalidContract.selector, eoaToken));
        new SponsoredTaskHook(address(market), IERC20(eoaToken), registry);

        address eoaRegistry = makeAddr("eoaRegistry");
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHook.InvalidContract.selector, eoaRegistry));
        new SponsoredTaskHook(address(market), IERC20(address(usdc)), SponsoredTaskRegistry(eoaRegistry));
    }

    // ---------------------------------------------------------------------
    // _requireMatchingVault (via _checkFund -> _reserveLocal)
    // ---------------------------------------------------------------------

    function test_FundRejectsVaultIdMismatchAgainstRegistry() external {
        bytes memory hookData = _hookDataWithVaultId(bytes32(uint256(0xBAD)));
        vm.expectRevert(SponsoredTaskHook.VaultMismatch.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    function test_FundRejectsEpochMismatch() external {
        bytes memory hookData = _hookDataWithEpoch(2);
        vm.expectRevert(SponsoredTaskHook.VaultMismatch.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    function test_FundRejectsStaleSettlementChain() external {
        vm.chainId(block.chainid + 1);
        bytes memory hookData = _localHookData();
        vm.expectRevert(SponsoredTaskHook.VaultMismatch.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    function test_FundRejectsExitedVault() external {
        vault.emergencyExitVault(address(this));
        bytes memory hookData = _localHookData();
        vm.expectRevert(SponsoredTaskHook.VaultMismatch.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    function test_FundRejectsVaultWithWrongController() external {
        address foreignController = address(new DummyController());
        SponsoredTaskFactoryV2 otherFactory = new SponsoredTaskFactoryV2(
            foreignController, address(feePolicy), registry, SponsoredTaskFeeConfig.none(IERC20(address(usdc)))
        );
        registry.setFactory(address(otherFactory), true);
        (address foreignVaultAddress,) =
            otherFactory.createVault(address(projectToken), address(this), keccak256("foreign-vault"));
        SponsoredTasksVaultV2 foreignVault = SponsoredTasksVaultV2(foreignVaultAddress);
        foreignVault.configureManager(MANAGER, GROSS * 100, true);

        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: foreignVaultAddress,
            vaultId: foreignVault.vaultId(),
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        bytes memory hookData = hook.encodeHookData(request);
        vm.expectRevert(SponsoredTaskHook.VaultMismatch.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    // ---------------------------------------------------------------------
    // _validateFundingRequest
    // ---------------------------------------------------------------------

    function test_FundRejectsNonBaseLocalRoute() external {
        uint8 badRoute = hook.ROUTE_BASE_LOCAL() + 1;
        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: badRoute,
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        bytes memory hookData = hook.encodeHookData(request);
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHook.InvalidRoute.selector, badRoute));
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    function test_FundRejectsZeroGrossAmount() external {
        bytes memory hookData = _hookDataWithGrossAmount(0);
        vm.expectRevert(SponsoredTaskHook.InvalidFundingRequest.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    function test_FundRejectsFeeBpsAboveTenThousand() external {
        bytes memory hookData = _hookDataWithFeeBps(10_001, TOKEN_FEE_RECIPIENT);
        vm.expectRevert(SponsoredTaskHook.InvalidFundingRequest.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    function test_FundRejectsNonZeroFeeBpsWithZeroRecipient() external {
        bytes memory hookData = _hookDataWithFeeBps(TOKEN_FEE_BPS, address(0));
        vm.expectRevert(SponsoredTaskHook.InvalidFundingRequest.selector);
        market.callCheckFund(hook, TASK_ID, hookData);
    }

    // ---------------------------------------------------------------------
    // terminal-state guards
    // ---------------------------------------------------------------------

    function test_FinalizeReleaseRejectsNonTerminalTask() external {
        market.callCheckFund(hook, TASK_ID, _localHookData());
        vm.expectRevert(
            abi.encodeWithSelector(SponsoredTaskHook.TaskNotTerminal.selector, TASK_ID, ITMPCore.TaskStatus.Open)
        );
        hook.finalizeRelease(TASK_ID);
    }

    function test_ReconcileRejectsUnknownAllocation() external {
        vm.expectRevert(abi.encodeWithSelector(SponsoredTaskHook.AllocationNotFound.selector, TASK_ID));
        hook.reconcile(TASK_ID);
    }

    function test_RefreshOwnerDefaultReturnsFalseWhenVaultStillActive() external {
        market.callCheckFund(hook, TASK_ID, _localHookData());
        assertFalse(hook.refreshOwnerDefault(TASK_ID));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _localHookData() private view returns (bytes memory) {
        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        return hook.encodeHookData(request);
    }

    function _hookDataWithVaultId(bytes32 vaultId) private view returns (bytes memory) {
        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vaultId,
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        return hook.encodeHookData(request);
    }

    function _hookDataWithEpoch(uint64 epoch) private view returns (bytes memory) {
        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: epoch,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        return hook.encodeHookData(request);
    }

    function _hookDataWithGrossAmount(uint256 grossAmount) private view returns (bytes memory) {
        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: TOKEN_FEE_BPS,
            feeRecipient: TOKEN_FEE_RECIPIENT,
            grossAmount: grossAmount,
            taskTermsHash: termsHash
        });
        return hook.encodeHookData(request);
    }

    function _hookDataWithFeeBps(uint16 feeBps, address feeRecipient) private view returns (bytes memory) {
        bytes32 termsHash = hook.currentTaskTermsHash(TASK_ID);
        SponsoredTaskHook.FundingRequest memory request = SponsoredTaskHook.FundingRequest({
            route: hook.ROUTE_BASE_LOCAL(),
            vault: address(vault),
            vaultId: vault.vaultId(),
            allocationId: bytes32(0),
            epoch: 1,
            feeBps: feeBps,
            feeRecipient: feeRecipient,
            grossAmount: GROSS,
            taskTermsHash: termsHash
        });
        return hook.encodeHookData(request);
    }
}

/// @dev A trivial contract with real code, standing in for a Safe-compatible controller whose
///      only requirement (per `SponsoredTaskFactoryV2`'s own constructor check) is having code.
contract DummyController { }
