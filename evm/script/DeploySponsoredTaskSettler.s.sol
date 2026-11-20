// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ScriptBounds } from "./lib/ScriptBounds.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SponsoredTaskCreationFee } from "../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
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
///   FORGE_SPONSORED_TASK_TOKEN_FEE_BPS       -- project-token fee (default 0, no fee)
///   FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT -- where the project-token fee is paid; required only
///                                               when the fee is not zero
///   FORGE_USDC_TOKEN_ADDRESS                 -- the token the vault creation fee is paid in
///   FORGE_SPONSORED_TASK_CREATION_FEE_USDC   -- one-time vault creation fee (default 1_000_000 = $1)
///   FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT -- where vault creation fees are paid
///
/// The factory's creation fee is fixed at deployment and has no owner.
contract DeploySponsoredTaskSettler is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envAddress("FORGE_SPONSORED_TASK_SETTLER_ADMIN");
        require(admin.code.length != 0, "Settler: admin must be a contract");
        require(admin != deployer, "Settler: admin must not be the deployer");
        address[] memory settlers = sortAddresses(vm.envAddress("FORGE_SPONSORED_TASK_SETTLER_ADDRESSES", ","));
        uint8 threshold = ScriptBounds.toUint8(
            vm.envOr("FORGE_SPONSORED_TASK_SETTLER_THRESHOLD", uint256(1)), "FORGE_SPONSORED_TASK_SETTLER_THRESHOLD"
        );

        IERC20 feeToken = IERC20(vm.envAddress("FORGE_USDC_TOKEN_ADDRESS"));
        uint256 creationFee = vm.envOr("FORGE_SPONSORED_TASK_CREATION_FEE_USDC", uint256(1_000_000));
        address creationFeeRecipient = vm.envAddress("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT");

        vm.startBroadcast(deployerKey);
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(deployer);
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(
            admin,
            ScriptBounds.bps(
                vm.envOr("FORGE_SPONSORED_TASK_TOKEN_FEE_BPS", uint256(0)), "FORGE_SPONSORED_TASK_TOKEN_FEE_BPS"
            ),
            vm.envOr("FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT", address(0))
        );
        SponsoredTaskSettler settler = new SponsoredTaskSettler(admin, settlers, threshold, registry);
        SponsoredTaskFactoryV2 factory = new SponsoredTaskFactoryV2(
            address(settler),
            address(feePolicy),
            registry,
            SponsoredTaskCreationFee.CreationFeeConfig({
                token: feeToken, amount: creationFee, recipient: creationFeeRecipient
            })
        );
        registry.setFactory(address(factory), true);
        registry.transferOwnership(admin);
        vm.stopBroadcast();

        require(settler.owner() == admin, "Settler: owner is not the admin");
        require(factory.controller() == address(settler), "Settler: factory controller is not the settler");
        require(feePolicy.owner() == admin, "Settler: fee policy owner is not the admin");
        require(registry.pendingOwner() == admin, "Settler: registry not pending to the admin");
        require(factory.creationFee() == creationFee, "Settler: creation fee mismatch");
        require(factory.creationFeeRecipient() == creationFeeRecipient, "Settler: creation fee recipient mismatch");
        require(address(factory.feeToken()) == address(feeToken), "Settler: creation fee token mismatch");

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

/// @notice Rev031: replaces a remote chain's settler-mode pair. Deploys a new `SponsoredTaskSettler`
///         (its signed `Reserve` carries a `deadline`) with the live settler's owner, settler set,
///         threshold and registry, and a new settler-mode `SponsoredTaskFactoryV2` whose controller
///         is the new settler, with the live factory's fee policy, registry and creation fee. The
///         settler is not upgradeable and a vault's controller is fixed at creation, so vaults
///         created on the live factory keep the old settler for life; it keeps running for them.
///         The registry then authorizes the new factory and deauthorizes the live one, so no new
///         vault gets the old settler. Deauthorizing a factory does not unregister its vaults.
///         When the key does not own the registry (a Safe does), it prints both `setFactory` calls
///         for the owner, in order.
/// @dev Required env vars: FORGE_DEV_PRIVATE_KEY, FORGE_SPONSORED_TASK_PREVIOUS_FACTORY (the live
///      settler-mode factory). The old settler's claim delay and authority are not copied: both are
///      the owner's to set on the new settler (a lower claim delay and any authority are timelocked),
///      and the script prints what differs.
contract RedeploySponsoredTaskSettler is Script {
    function run() external returns (SponsoredTaskSettler settler, SponsoredTaskFactoryV2 factory) {
        return redeploy(SponsoredTaskFactoryV2(vm.envAddress("FORGE_SPONSORED_TASK_PREVIOUS_FACTORY")));
    }

    function redeploy(SponsoredTaskFactoryV2 previous)
        public
        returns (SponsoredTaskSettler settler, SponsoredTaskFactoryV2 factory)
    {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        require(address(previous).code.length != 0, "Settler redeploy: previous factory must be a contract");
        SponsoredTaskSettler previousSettler = SponsoredTaskSettler(previous.controller());
        SponsoredTaskRegistry registry = SponsoredTaskRegistry(address(previous.registry()));
        require(
            address(previousSettler.registry()) == address(registry),
            "Settler redeploy: previous factory's controller is not a settler on its registry"
        );
        bool registryOwner = registry.owner() == vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        settler = new SponsoredTaskSettler(
            previousSettler.owner(), previousSettler.settlers(), previousSettler.threshold(), registry
        );
        factory = new SponsoredTaskFactoryV2(
            address(settler),
            previous.feePolicy(),
            registry,
            SponsoredTaskCreationFee.CreationFeeConfig({
                token: previous.feeToken(), amount: previous.creationFee(), recipient: previous.creationFeeRecipient()
            })
        );
        if (registryOwner) {
            registry.setFactory(address(factory), true);
            registry.setFactory(address(previous), false);
        }
        vm.stopBroadcast();

        require(factory.controller() == address(settler), "Settler redeploy: factory controller is not the settler");
        require(settler.owner() == previousSettler.owner(), "Settler redeploy: owner mismatch");

        console.log("=== Sponsored Task settler-mode pair redeployed (rev031) ===");
        console.log("Chain id:                 ", block.chainid);
        console.log("Previous settler:         ", address(previousSettler));
        console.log("Previous factory:         ", address(previous));
        console.log("SponsoredTaskSettler:     ", address(settler));
        console.log("SponsoredTaskFactoryV2:   ", address(factory));
        console.log("Vault implementation:     ", factory.implementation());
        if (!registryOwner) {
            console.log("Registry owner must execute on the registry, in order:", address(registry));
            console.logBytes(abi.encodeCall(SponsoredTaskRegistry.setFactory, (address(factory), true)));
            console.logBytes(abi.encodeCall(SponsoredTaskRegistry.setFactory, (address(previous), false)));
        }
        if (previousSettler.claimDelaySeconds() != settler.claimDelaySeconds()) {
            console.log(
                "Claim delay differs; the owner may call setClaimDelay with:", previousSettler.claimDelaySeconds()
            );
        }
        if (address(previousSettler.authority()) != address(0)) {
            console.log(
                "Previous settler has an authority; the owner may schedule setAuthority:",
                address(previousSettler.authority())
            );
        }
    }
}
