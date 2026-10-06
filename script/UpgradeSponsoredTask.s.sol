// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { ISponsoredTaskFeeBank } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskFeeBank.sol";
import { ISponsoredTaskRegistry } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskRegistry.sol";

/// @title UpgradeSponsoredTask — deploy a new SponsoredTaskHook implementation and upgrade the
///        existing proxy in place via UUPS
/// @notice Use this for a logic-only fix that does not change SponsoredTaskHook's storage layout
///         or its external interface. The proxy address and every
///         in-flight TaskAllocation stay exactly as they are -- only the code behind the proxy
///         changes. Mirrors UpgradeRewardHook.s.sol's role for TaskTokenRewardHook.
/// @dev    Unlike TaskTokenRewardHook, this hook's `taskmarket`/`usdc`/`feeBank`/`registry` are
///         `immutable` and baked into the implementation's own bytecode at construction, so this
///         script must re-supply the exact same values the current proxy was deployed with --
///         re-read them from the live proxy rather than from env vars, so a stale or wrong env
///         value cannot silently swap in a different dependency underneath an in-place upgrade.
/// @dev Required env vars:
///   FORGE_DEV_PRIVATE_KEY           — owner key (must match the hook proxy's own owner())
///   FORGE_SPONSORED_TASK_HOOK_ADDRESS — the EXISTING SponsoredTaskHook proxy to upgrade in place
/// Usage:
///   make upgrade-sponsored-task testnet
///   make upgrade-sponsored-task mainnet
contract UpgradeSponsoredTask is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        SponsoredTaskHook hook = SponsoredTaskHook(vm.envAddress("FORGE_SPONSORED_TASK_HOOK_ADDRESS"));

        address diamond = hook.diamond();
        IERC20 usdc = hook.usdc();
        ISponsoredTaskFeeBank feeBank = hook.feeBank();
        ISponsoredTaskRegistry registry = hook.registry();

        vm.startBroadcast(ownerKey);

        address newImplementation = address(new SponsoredTaskHook(diamond, usdc, feeBank, registry));
        hook.upgradeToAndCall(newImplementation, "");

        vm.stopBroadcast();

        console.log("=== SponsoredTaskHook in-place upgrade complete ===");
        console.log("Proxy (unchanged):", address(hook));
        console.log("New implementation:", newImplementation);
    }
}
