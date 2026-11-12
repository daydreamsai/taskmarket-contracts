// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ScriptBounds } from "./lib/ScriptBounds.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";

/// @notice Deploys the shared, protocol-owned Sponsored Task pieces every V2 vault factory builds
///         on: the registry and the default fee policy. Rev030 retired the V1 SponsoredTaskHook,
///         so this script no longer deploys a hook or a factory; run
///         DeployHooksV2.s.sol:DeploySponsoredTaskHookV2 next (`make deploy-sponsored-task-hook-v2`),
///         which deploys the V2 hook and a factory bound to it and registers that factory.
/// @dev Required env vars (set in packages/contracts/.env):
///
///   FORGE_DEV_PRIVATE_KEY                       -- deployer key
///   FORGE_DIAMOND_ADDRESS                       -- TaskMarket Diamond proxy (must have code)
///   FORGE_SPONSORED_TASK_TOKEN_FEE_BPS         -- default project-token fee (default 0, no fee,
///                                                  matching the platform's own USDC fee)
///   FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT   -- where the project-token fee is paid; required
///                                                  only when the fee is not zero
///   FORGE_SPONSORED_TASK_ADMIN                 -- a deployed contract (Safe/timelock) that owns
///                                                  the fee policy and (once it accepts) the
///                                                  registry; required, not optional
///
/// No protocol-owned piece stays owned by the deployer key. The fee policy is created owned by the
/// admin. The registry must stay deployer-owned long enough to register the V2 factory, so it is
/// handed over with a two-step transfer the admin completes by calling `acceptOwnership()`; until
/// then the deployer remains its owner.
contract DeploySponsoredTask is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        require(diamond.code.length != 0, "Sponsored Task: diamond must be a contract");

        address admin = vm.envAddress("FORGE_SPONSORED_TASK_ADMIN");
        require(admin.code.length != 0, "Sponsored Task: admin must be a contract");
        require(admin != deployer, "Sponsored Task: admin must not be the deployer");

        vm.startBroadcast(deployerKey);

        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(deployer);
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(
            admin,
            ScriptBounds.bps(
                vm.envOr("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", uint256(0)), "FORGE_SPONSORED_TASK_TOKEN_FEE_BPS"
            ),
            vm.envOr("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT", address(0))
        );
        registry.transferOwnership(admin);
        vm.stopBroadcast();

        require(feePolicy.owner() == admin, "Sponsored Task: fee policy owner is not the admin");
        require(registry.pendingOwner() == admin, "Sponsored Task: registry not pending to the admin");

        console.log("=== Sponsored Task shared deployment ===");
        console.log("SponsoredTaskRegistry:     ", address(registry));
        console.log("SponsoredTaskFeePolicy:    ", address(feePolicy));
        console.log("Fee policy owner (admin):", admin);
        console.log("Registry pending owner -- the admin must call acceptOwnership():", admin);
        console.log("Next: make deploy-sponsored-task-hook-v2 deploys the V2 hook and factory");
    }
}
