// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactory } from "../src/hooks/sponsored-task/SponsoredTaskFactory.sol";
import { SponsoredTaskSettler } from "../src/hooks/sponsored-task/SponsoredTaskSettler.sol";

/// @notice Deploys settler mode on a remote EVM chain that has no Taskmarket Diamond: a registry,
///         the fee policy, the `SponsoredTaskSettler` and a factory whose controller is the settler.
///         See `docs/specs/sponsored-tasks/evm-attested-settler.md`.
/// @dev Required env vars:
///
///   FORGE_DEV_PRIVATE_KEY                    -- deployer key; owns nothing once the admin accepts
///                                               the registry
///   FORGE_SPONSORED_TASK_SETTLER_ADMIN       -- a deployed contract (Safe or timelock) that owns the
///                                               settler and the fee policy, and the registry once it
///                                               calls `acceptOwnership()`
///   FORGE_SPONSORED_TASK_SETTLER_ADDRESSES   -- comma-separated settler addresses, in any order
///   FORGE_SPONSORED_TASK_SETTLER_THRESHOLD   -- signatures required (default 1)
///   FORGE_SPONSORED_TASK_TOKEN_FEE_BPS       -- project-token fee (default 750 = 7.5%)
///   FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT -- where the project-token fee is paid
contract DeploySponsoredTaskSettler is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envAddress("FORGE_SPONSORED_TASK_SETTLER_ADMIN");
        require(admin.code.length != 0, "Settler: admin must be a contract");
        require(admin != deployer, "Settler: admin must not be the deployer");
        address[] memory settlers = sortAddresses(vm.envAddress("FORGE_SPONSORED_TASK_SETTLER_ADDRESSES", ","));
        uint8 threshold = uint8(vm.envOr("FORGE_SPONSORED_TASK_SETTLER_THRESHOLD", uint256(1)));

        vm.startBroadcast(deployerKey);
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(deployer);
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(
            admin,
            uint16(vm.envOr("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", uint256(750))),
            vm.envAddress("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT")
        );
        SponsoredTaskSettler settler = new SponsoredTaskSettler(admin, settlers, threshold);
        SponsoredTaskFactory factory = new SponsoredTaskFactory(address(settler), address(feePolicy), registry);
        registry.setFactory(address(factory), true);
        registry.transferOwnership(admin);
        vm.stopBroadcast();

        require(settler.owner() == admin, "Settler: owner is not the admin");
        require(factory.controller() == address(settler), "Settler: factory controller is not the settler");
        require(feePolicy.owner() == admin, "Settler: fee policy owner is not the admin");
        require(registry.pendingOwner() == admin, "Settler: registry not pending to the admin");

        console.log("=== Sponsored Task settler mode deployment ===");
        console.log("Chain id:                 ", block.chainid);
        console.log("SponsoredTaskRegistry:    ", address(registry));
        console.log("SponsoredTaskFeePolicy:   ", address(feePolicy));
        console.log("SponsoredTaskSettler:     ", address(settler));
        console.log("SponsoredTaskFactory:     ", address(factory));
        console.log("Settler threshold:        ", threshold);
        console.log("Registry pending owner -- the admin must call acceptOwnership():", admin);
    }

    /// @dev The settler requires strictly ascending addresses; duplicates are left for it to reject.
    function sortAddresses(address[] memory list) public pure returns (address[] memory) {
        for (uint256 i = 1; i < list.length; ++i) {
            address key = list[i];
            uint256 j = i;
            while (j > 0 && list[j - 1] > key) {
                list[j] = list[j - 1];
                --j;
            }
            list[j] = key;
        }
        return list;
    }
}
