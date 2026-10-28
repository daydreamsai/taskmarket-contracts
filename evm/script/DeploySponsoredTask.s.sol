// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskCreationFee } from "../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";
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
///   FORGE_SPONSORED_TASK_CREATION_FEE_USDC     — one-time vault creation fee, USDC base units
///                                                  (default 1_000_000 = $1)
///   FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT — where vault creation fees are paid
///   FORGE_SPONSORED_TASK_TOKEN_FEE_BPS         — default project-token fee (default 750 = 7.5%,
///                                                  matching the platform's own USDC fee)
///   FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT   — where the project-token fee is paid
///   FORGE_SPONSORED_TASK_ADMIN                 — a deployed contract (Safe/timelock) that owns
///                                                  the hook proxy, the fee policy and (once it
///                                                  accepts) the registry; required, not optional
///
/// The factory's creation fee (token, amount and recipient) is fixed here, at deployment, and has
/// no owner: a different fee or recipient takes a new factory.
///
/// Vault creation is permissionless once this stack is live (SponsoredTaskFactory.createVault
/// has no access control): any project can spin up its own vault against the deployed
/// registry, paying the factory's one-time creation fee. This script deploys only the shared,
/// protocol-owned pieces -- the hook, the default fee policy, and the registry/factory pair that
/// vaults register through.
///
/// No protocol-owned piece stays owned by the deployer key. The hook and the fee policy are created
/// owned by the admin. The registry must stay deployer-owned long
/// enough to register the factory, so it is handed over with a two-step transfer the admin
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

        address admin = vm.envAddress("FORGE_SPONSORED_TASK_ADMIN");
        require(admin.code.length != 0, "Sponsored Task: admin must be a contract");
        require(admin != deployer, "Sponsored Task: admin must not be the deployer");
        uint256 creationFee = vm.envOr("FORGE_SPONSORED_TASK_CREATION_FEE_USDC", uint256(1_000_000));

        vm.startBroadcast(deployerKey);

        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(deployer);
        SponsoredTaskHook hook = DeploySponsoredTaskProxy.deploy(diamond, usdc, registry, admin);

        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(
            admin,
            uint16(vm.envOr("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", uint256(750))),
            vm.envAddress("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT")
        );
        SponsoredTaskFactory factory = new SponsoredTaskFactory(
            address(hook),
            address(feePolicy),
            registry,
            SponsoredTaskCreationFee.CreationFeeConfig({
                token: usdc,
                amount: creationFee,
                recipient: vm.envAddress("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT")
            })
        );
        registry.setFactory(address(factory), true);
        registry.transferOwnership(admin);
        vm.stopBroadcast();

        require(hook.owner() == admin, "Sponsored Task: hook owner is not the admin");
        require(feePolicy.owner() == admin, "Sponsored Task: fee policy owner is not the admin");
        require(factory.creationFee() == creationFee, "Sponsored Task: creation fee mismatch");
        require(factory.creationFee() == creationFee, "Sponsored Task: creation fee mismatch");
        require(registry.pendingOwner() == admin, "Sponsored Task: registry not pending to the admin");

        console.log("=== Sponsored Task deployment ===");
        console.log("SponsoredTaskRegistry:     ", address(registry));
        console.log("SponsoredTaskFeePolicy:    ", address(feePolicy));
        console.log("SponsoredTaskFactory:      ", address(factory));
        console.log("SponsoredTaskHook (proxy): ", address(hook));
        console.log("Hook is opt-in only -- not registered as a Diamond default hook");
        console.log("Vault creation fee (USDC base units):", creationFee);
        console.log("Hook, fee policy and creation fee owner (admin):", admin);
        console.log("Registry pending owner -- the admin must call acceptOwnership():", admin);
    }
}
