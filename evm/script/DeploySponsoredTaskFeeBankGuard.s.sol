// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { SponsoredTaskFeeBank } from "../src/hooks/sponsored-task/SponsoredTaskFeeBank.sol";
import {
    SponsoredTaskFeeBankGuard,
    ISponsoredTaskFeeBankLinkedHook
} from "../src/hooks/sponsored-task/SponsoredTaskFeeBankGuard.sol";

interface IOwnedSponsoredTaskPiece {
    function owner() external view returns (address);
}

interface IOwnable2StepSponsoredTaskPiece is IOwnedSponsoredTaskPiece {
    function pendingOwner() external view returns (address);
}

/// @notice Mandatory Mainnet FeeBank hardening gate for a newly deployed Sponsored Task stack.
/// @dev The bootstrap owner remains responsible for proving from deployment transactions that no
///      charger other than the exact Hook was ever authorized. FeeBank's charger mapping cannot be
///      enumerated onchain.
contract DeployAndActivateSponsoredTaskFeeBankGuard is Script {
    uint256 internal constant BASE_MAINNET = 8453;

    function run() external returns (SponsoredTaskFeeBankGuard guard) {
        require(block.chainid == BASE_MAINNET, "Sponsored Task guard: Base Mainnet only");

        SponsoredTaskFeeBank bank = SponsoredTaskFeeBank(vm.envAddress("SPONSORED_TASK_BASE_FEE_BANK"));
        address hook = vm.envAddress("SPONSORED_TASK_BASE_HOOK");
        address bootstrapOwner = vm.envAddress("SPONSORED_TASK_ADMIN_SENDER");
        address guardAdmin = vm.envAddress("SPONSORED_TASK_FEE_BANK_GUARD_ADMIN");
        uint256 feeCeiling = vm.envUint("SPONSORED_TASK_CREATION_FEE_CEILING_USDC_BASE_UNITS");
        bytes32 expectedBankRuntimeHash = vm.envBytes32("SPONSORED_TASK_EXPECTED_FEE_BANK_RUNTIME_HASH");
        bytes32 expectedHookRuntimeHash = vm.envBytes32("SPONSORED_TASK_EXPECTED_HOOK_RUNTIME_HASH");
        bytes32 expectedGuardRuntimeHash = vm.envBytes32("SPONSORED_TASK_EXPECTED_FEE_BANK_GUARD_RUNTIME_HASH");

        require(address(bank).code.length != 0, "Sponsored Task guard: missing FeeBank code");
        require(hook.code.length != 0, "Sponsored Task guard: missing Hook code");
        _requireRuntimeHash(address(bank), expectedBankRuntimeHash, "Sponsored Task guard: FeeBank runtime mismatch");
        _requireRuntimeHash(hook, expectedHookRuntimeHash, "Sponsored Task guard: Hook runtime mismatch");
        require(guardAdmin.code.length != 0, "Sponsored Task guard: admin must be contract");
        require(bank.owner() == bootstrapOwner, "Sponsored Task guard: wrong bootstrap owner");

        address pendingOwner = bank.pendingOwner();
        require(
            pendingOwner == address(0) || pendingOwner == guardAdmin, "Sponsored Task guard: unexpected pending owner"
        );
        require(
            address(ISponsoredTaskFeeBankLinkedHook(hook).feeBank()) == address(bank),
            "Sponsored Task guard: Hook FeeBank mismatch"
        );
        require(bank.authorizedChargers(hook), "Sponsored Task guard: exact Hook not authorized");
        require(bank.feeAmount() <= feeCeiling, "Sponsored Task guard: current fee exceeds ceiling");

        vm.startBroadcast(bootstrapOwner);
        guard = new SponsoredTaskFeeBankGuard(guardAdmin, bank, hook, feeCeiling);
        _requireRuntimeHash(address(guard), expectedGuardRuntimeHash, "Sponsored Task guard: Guard runtime mismatch");
        bank.transferOwnership(address(guard));
        guard.acceptFeeBankOwnership();
        vm.stopBroadcast();

        require(address(guard.feeBank()) == address(bank), "Sponsored Task guard: FeeBank mismatch");
        require(guard.hook() == hook, "Sponsored Task guard: Hook mismatch");
        require(guard.feeCeiling() == feeCeiling, "Sponsored Task guard: ceiling mismatch");
        require(guard.owner() == guardAdmin, "Sponsored Task guard: admin mismatch");
        require(bank.owner() == address(guard), "Sponsored Task guard: FeeBank owner mismatch");
        require(bank.pendingOwner() == address(0), "Sponsored Task guard: pending FeeBank owner");
        require(guard.feeBankOwnershipAccepted(), "Sponsored Task guard: activation failed");

        console2.log("SponsoredTaskFeeBankGuard", address(guard));
        console2.log("FeeBank owner", address(guard));
        console2.log("Mandatory Mainnet FeeBank guard active");
    }

    function _requireRuntimeHash(address account, bytes32 expected, string memory errorMessage) internal view {
        require(account.codehash == expected, errorMessage);
    }
}

/// @notice Read-only mandatory Mainnet release assertion after the guard is active.
contract VerifySponsoredTaskFeeBankGuard is Script {
    uint256 internal constant BASE_MAINNET = 8453;

    function run() external view {
        require(block.chainid == BASE_MAINNET, "Sponsored Task guard: Base Mainnet only");

        SponsoredTaskFeeBankGuard guard = SponsoredTaskFeeBankGuard(vm.envAddress("SPONSORED_TASK_FEE_BANK_GUARD"));
        SponsoredTaskFeeBank bank = SponsoredTaskFeeBank(vm.envAddress("SPONSORED_TASK_BASE_FEE_BANK"));
        address hook = vm.envAddress("SPONSORED_TASK_BASE_HOOK");
        address guardAdmin = vm.envAddress("SPONSORED_TASK_FEE_BANK_GUARD_ADMIN");
        uint256 feeCeiling = vm.envUint("SPONSORED_TASK_CREATION_FEE_CEILING_USDC_BASE_UNITS");
        bytes32 expectedBankRuntimeHash = vm.envBytes32("SPONSORED_TASK_EXPECTED_FEE_BANK_RUNTIME_HASH");
        bytes32 expectedHookRuntimeHash = vm.envBytes32("SPONSORED_TASK_EXPECTED_HOOK_RUNTIME_HASH");
        bytes32 expectedGuardRuntimeHash = vm.envBytes32("SPONSORED_TASK_EXPECTED_FEE_BANK_GUARD_RUNTIME_HASH");

        require(address(guard).code.length != 0, "Sponsored Task guard: missing Guard code");
        require(address(guard).codehash == expectedGuardRuntimeHash, "Sponsored Task guard: Guard runtime mismatch");
        require(address(bank).codehash == expectedBankRuntimeHash, "Sponsored Task guard: FeeBank runtime mismatch");
        require(hook.codehash == expectedHookRuntimeHash, "Sponsored Task guard: Hook runtime mismatch");
        require(address(guard.feeBank()) == address(bank), "Sponsored Task guard: FeeBank mismatch");
        require(guard.hook() == hook, "Sponsored Task guard: Hook mismatch");
        require(
            address(ISponsoredTaskFeeBankLinkedHook(hook).feeBank()) == address(bank),
            "Sponsored Task guard: Hook FeeBank mismatch"
        );
        require(guard.feeCeiling() == feeCeiling, "Sponsored Task guard: ceiling mismatch");
        require(guard.owner() == guardAdmin, "Sponsored Task guard: admin mismatch");
        require(guard.pendingOwner() == address(0), "Sponsored Task guard: pending guard admin");
        require(guardAdmin.code.length != 0, "Sponsored Task guard: admin must be contract");
        require(guard.feeBankOwnershipAccepted(), "Sponsored Task guard: not activated");
        require(bank.owner() == address(guard), "Sponsored Task guard: FeeBank owner mismatch");
        require(bank.pendingOwner() == address(0), "Sponsored Task guard: pending bank owner");
        require(bank.authorizedChargers(hook), "Sponsored Task guard: Hook revoked");
        // The hook is the FeeBank's charger and UUPS-upgradeable by its owner; the registry and
        // fee policy steer every vault. None of them may stay with a single deployer key.
        require(IOwnedSponsoredTaskPiece(hook).owner() == guardAdmin, "Sponsored Task guard: Hook owner mismatch");
        IOwnable2StepSponsoredTaskPiece registry =
            IOwnable2StepSponsoredTaskPiece(vm.envAddress("SPONSORED_TASK_BASE_REGISTRY"));
        IOwnable2StepSponsoredTaskPiece feePolicy =
            IOwnable2StepSponsoredTaskPiece(vm.envAddress("SPONSORED_TASK_BASE_FEE_POLICY"));
        require(registry.owner() == guardAdmin, "Sponsored Task guard: Registry owner mismatch");
        require(registry.pendingOwner() == address(0), "Sponsored Task guard: pending Registry owner");
        require(feePolicy.owner() == guardAdmin, "Sponsored Task guard: FeePolicy owner mismatch");
        require(feePolicy.pendingOwner() == address(0), "Sponsored Task guard: pending FeePolicy owner");
        uint256 currentFee = bank.feeAmount();
        address currentRecipient = bank.feeRecipient();
        require(currentFee <= feeCeiling, "Sponsored Task guard: fee exceeds ceiling");
        require(
            currentFee == 0 || (currentRecipient != address(0) && currentRecipient != address(bank)),
            "Sponsored Task guard: invalid fee recipient"
        );
    }
}
