// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskFeeBank } from "../src/hooks/sponsored-task/SponsoredTaskFeeBank.sol";
import { SponsoredTaskFeeBankGuard } from "../src/hooks/sponsored-task/SponsoredTaskFeeBankGuard.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { DeploySponsoredTaskProxy } from "./lib/DeploySponsoredTaskProxy.sol";

/// @dev Required env vars (set in packages/contracts/.env):
///
///   FORGE_DEV_PRIVATE_KEY                       — deployer/owner key
///   FORGE_USDC_TOKEN_ADDRESS                    — USDC address on the target chain
///   FORGE_DIAMOND_ADDRESS                       — TaskMarket Diamond proxy
///   FORGE_SPONSORED_TASK_CREATION_FEE_USDC     — flat per-task creation fee, USDC base units
///                                                  (default 1_000_000 = $1)
///   FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT — where creation fees are paid
///   FORGE_SPONSORED_TASK_TOKEN_FEE_BPS         — default project-token fee (default 750 = 7.5%,
///                                                  matching the platform's own USDC fee)
///   FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT   — where the project-token fee is paid
///   FORGE_SPONSORED_TASK_FEE_BANK_GUARD_ADMIN  — a deployed contract (Safe/timelock) that
///                                                  becomes the FeeBank's sole administrator after
///                                                  this script runs, and the owner of the hook
///                                                  proxy, the fee policy and (once it accepts) the
///                                                  registry; required, not optional
///   FORGE_SPONSORED_TASK_FEE_CEILING_USDC      — the guard's immutable ceiling on any future
///                                                  creation-fee change
///
/// Vault creation is permissionless once this stack is live (SponsoredTaskFactory.createVault
/// has no access control): any project can spin up its own vault against the deployed
/// registry. This script deploys only the shared, protocol-owned pieces -- the hook, the fee bank,
/// the default fee policy, and the registry/factory pair that vaults register through.
///
/// No protocol-owned piece stays owned by the deployer key. The hook proxy is the FeeBank's only
/// charger and is UUPS-upgradeable by its owner, so a deployer-owned hook could be upgraded into
/// code that charges any manager's credit and the guard would protect nothing. The hook and the
/// fee policy are created owned by the guard admin. The registry must stay deployer-owned long
/// enough to register the factory, so it is handed over with a two-step transfer the guard admin
/// completes by calling `acceptOwnership()`; until then the deployer remains its owner.
///
/// This hook is opt-in, never a Diamond default: unlike DeployRewardHook, this script does not
/// call setDefaultHooks. A vault manager attaches it per task at createTask, the same way any
/// other custom hook is attached.
contract DeploySponsoredTask is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        IERC20 usdc = IERC20(vm.envAddress("FORGE_USDC_TOKEN_ADDRESS"));
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");

        address guardAdmin = vm.envAddress("FORGE_SPONSORED_TASK_FEE_BANK_GUARD_ADMIN");
        require(guardAdmin.code.length != 0, "Sponsored Task: guard admin must be a contract");
        require(guardAdmin != deployer, "Sponsored Task: guard admin must not be the deployer");

        vm.startBroadcast(deployerKey);

        SponsoredTaskFeeBank feeBank = new SponsoredTaskFeeBank(
            deployer,
            usdc,
            vm.envOr("FORGE_SPONSORED_TASK_CREATION_FEE_USDC", uint256(1_000_000)),
            vm.envAddress("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT")
        );
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(deployer);
        SponsoredTaskHook hook = DeploySponsoredTaskProxy.deploy(diamond, usdc, feeBank, registry, guardAdmin);
        feeBank.setCharger(address(hook), true);

        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(
            guardAdmin,
            uint16(vm.envOr("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", uint256(750))),
            vm.envAddress("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT")
        );
        SponsoredTaskFactory factory = new SponsoredTaskFactory(address(hook), address(feePolicy), registry);
        registry.setFactory(address(factory), true);
        registry.transferOwnership(guardAdmin);

        // Force the FeeBankGuard unconditionally -- the raw FeeBank owner can authorize an
        // arbitrary charger and drain manager credit, so this deployment never leaves the FeeBank
        // owned directly by an EOA/deployer key once this script completes.
        SponsoredTaskFeeBankGuard guard = new SponsoredTaskFeeBankGuard(
            guardAdmin, feeBank, address(hook), vm.envUint("FORGE_SPONSORED_TASK_FEE_CEILING_USDC")
        );
        feeBank.transferOwnership(address(guard));
        guard.acceptFeeBankOwnership();
        vm.stopBroadcast();

        require(feeBank.owner() == address(guard), "Sponsored Task: FeeBankGuard did not take ownership");
        require(hook.owner() == guardAdmin, "Sponsored Task: hook owner is not the guard admin");
        require(feePolicy.owner() == guardAdmin, "Sponsored Task: fee policy owner is not the guard admin");
        require(registry.pendingOwner() == guardAdmin, "Sponsored Task: registry not pending to the guard admin");

        console.log("=== Sponsored Task deployment ===");
        console.log("SponsoredTaskFeeBank:      ", address(feeBank));
        console.log("SponsoredTaskFeeBankGuard: ", address(guard));
        console.log("SponsoredTaskRegistry:     ", address(registry));
        console.log("SponsoredTaskFeePolicy:    ", address(feePolicy));
        console.log("SponsoredTaskFactory:      ", address(factory));
        console.log("SponsoredTaskHook (proxy): ", address(hook));
        console.log("Hook is opt-in only -- not registered as a Diamond default hook");
        console.log("FeeBank owner is now the guard at:", address(guard));
        console.log("Hook and fee policy owner (guard admin):", guardAdmin);
        console.log("Registry pending owner -- the guard admin must call acceptOwnership():", guardAdmin);
    }
}
