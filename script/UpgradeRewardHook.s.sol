// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { TaskTokenRewardHook } from "../src/hooks/TaskTokenRewardHook.sol";

/// @title UpgradeRewardHook — deploy a new TaskTokenRewardHook implementation and upgrade the
///        existing proxy in place via UUPS
/// @notice Use this for a logic-only fix that does not change TaskTokenRewardHook's storage
///         layout or its external interface with RewardVault/EpochBudget. The proxy address,
///         RewardVault authorization, EpochBudget wiring, and every in-flight RewardState stay
///         exactly as they are -- only the code behind the proxy changes.
/// @dev    Reserve SwapRewardHook.s.sol for a fix that needs a new EpochBudget/RewardVault
///         relationship or otherwise cannot preserve in-flight state at the same address (see
///         that script's own doc comment). This script does not attempt the
///         RewardVault.totalReserved() == 0 guard SwapRewardHook.s.sol has, because nothing
///         about in-flight reservations changes here -- they settle against the new
///         implementation exactly as they would have against the old one.
/// @dev Required env vars:
///   FORGE_DEV_PRIVATE_KEY      — owner key (must match the hook proxy's own owner())
///   FORGE_REWARD_HOOK_ADDRESS  — the EXISTING TaskTokenRewardHook proxy to upgrade in place
/// Usage:
///   make upgrade-reward-hook testnet
///   make upgrade-reward-hook mainnet
contract UpgradeRewardHook is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        TaskTokenRewardHook hook = TaskTokenRewardHook(vm.envAddress("FORGE_REWARD_HOOK_ADDRESS"));

        vm.startBroadcast(ownerKey);

        address newImplementation = address(new TaskTokenRewardHook());
        hook.upgradeToAndCall(newImplementation, "");

        vm.stopBroadcast();

        console.log("=== TaskTokenRewardHook in-place upgrade complete ===");
        console.log("Proxy (unchanged):", address(hook));
        console.log("New implementation:", newImplementation);
    }
}
