// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskHook } from "../src/hooks/sponsored-task/SponsoredTaskHook.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ISponsoredTaskRegistry } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskRegistry.sol";

/// @title UpgradeSponsoredTask — deploy a new SponsoredTaskHook implementation and upgrade the
///        existing proxy in place via UUPS
/// @notice Use this for a logic-only fix that does not change SponsoredTaskHook's storage layout
///         or its external interface. The proxy address and every
///         in-flight TaskAllocation stay exactly as they are -- only the code behind the proxy
///         changes. Mirrors UpgradeRewardHook.s.sol's role for TaskTokenRewardHook.
/// @dev    Unlike TaskTokenRewardHook, this hook's `taskmarket`/`usdc`/`registry` are
///         `immutable` and baked into the implementation's own bytecode at construction, so this
///         script must re-supply the exact same values the current proxy was deployed with --
///         re-read them from the live proxy rather than from env vars, so a stale or wrong env
///         value cannot silently swap in a different dependency underneath an in-place upgrade.
/// @dev Required env vars:
///   FORGE_DEV_PRIVATE_KEY           — owner key (must match the hook proxy's own owner())
///   FORGE_SPONSORED_TASK_HOOK_ADDRESS — the EXISTING SponsoredTaskHook proxy to upgrade in place
///
/// Upgrading a hook deployed with a per-task creation fee to this implementation stops that
/// charge: the current implementation takes no fee at task creation.
///
/// Once the hook is owned by the admin Safe or timelock (every deployment from
/// DeploySponsoredTask.s.sol is), the deployer key cannot upgrade it. In that case this script
/// deploys the new implementation only and prints the `upgradeToAndCall` target and calldata for
/// the hook owner to propose and execute; it never calls the proxy itself.
/// Usage:
///   make upgrade-sponsored-task 84532
///   make upgrade-sponsored-task 8453
contract UpgradeSponsoredTask is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        SponsoredTaskHook hook = SponsoredTaskHook(vm.envAddress("FORGE_SPONSORED_TASK_HOOK_ADDRESS"));

        address diamond = hook.diamond();
        IERC20 usdc = hook.usdc();
        ISponsoredTaskRegistry registry = hook.registry();

        bool senderOwnsHook = hook.owner() == vm.addr(ownerKey);

        vm.startBroadcast(ownerKey);

        address newImplementation = address(new SponsoredTaskHook(diamond, usdc, registry));
        if (senderOwnsHook) hook.upgradeToAndCall(newImplementation, "");

        vm.stopBroadcast();

        if (senderOwnsHook) {
            console.log("=== SponsoredTaskHook in-place upgrade complete ===");
            console.log("Proxy (unchanged):", address(hook));
            console.log("New implementation:", newImplementation);
            return;
        }
        console.log("=== SponsoredTaskHook implementation deployed; upgrade NOT applied ===");
        console.log("The hook is owned by", hook.owner(), "(not this key). Propose from that owner:");
        console.log("  to:   ", address(hook));
        console.log("  value: 0");
        console.log("  data:");
        console.logBytes(upgradeCalldata(newImplementation));
    }

    function upgradeCalldata(address newImplementation) public pure returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImplementation, ""));
    }
}
