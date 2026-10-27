// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { RemoteSponsoredTaskHook } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHook.sol";

/// @notice Deploys a task chain's half of settler mode, `RemoteSponsoredTaskHook`, behind an ERC-1967
///         proxy. Any chain with a Taskmarket diamond (Base, Tempo) takes one, so a vault on any
///         other chain can fund its tasks. See `docs/specs/sponsored-tasks/evm-attested-settler.md`.
/// @dev Required env vars:
///
///   FORGE_DEV_PRIVATE_KEY                   -- deployer key; owns nothing once this script ends
///   FORGE_DIAMOND_ADDRESS                   -- TaskMarket Diamond proxy on the task chain
///   FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN  -- a deployed contract (Safe or timelock) that owns the
///                                              proxy and may upgrade it
///
/// Creating a remote task charges no fee: the one-time fee is paid when the remote vault is
/// created, by the factory on the remote chain.
///
/// The hook is opt-in, never a Diamond default hook; a vault manager attaches it per task.
contract DeployRemoteSponsoredTaskHook is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        address admin = vm.envAddress("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN");
        require(admin.code.length != 0, "Remote hook: admin must be a contract");
        require(admin != deployer, "Remote hook: admin must not be the deployer");

        vm.startBroadcast(deployerKey);
        address implementation = address(new RemoteSponsoredTaskHook(diamond));
        RemoteSponsoredTaskHook hook = RemoteSponsoredTaskHook(
            address(new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHook.initialize, (admin))))
        );
        vm.stopBroadcast();

        require(hook.owner() == admin, "Remote hook: owner is not the admin");
        require(hook.diamond() == diamond, "Remote hook: diamond mismatch");

        console.log("=== Remote Sponsored Task hook deployment ===");
        console.log("RemoteSponsoredTaskHook (proxy):", address(hook));
        console.log("Implementation:                 ", implementation);
        console.log("Owner (admin):                  ", admin);
        console.log("Hook is opt-in only -- not registered as a Diamond default hook");
    }
}
