// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ScriptBounds } from "./lib/ScriptBounds.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { RemoteSponsoredTaskHookV2 } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskCreationFee } from "../src/hooks/sponsored-task/SponsoredTaskCreationFee.sol";
import { ISponsoredTaskRegistry } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskRegistry.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { TaskTokenRewardHookV2 } from "../src/hooks/TaskTokenRewardHookV2.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";

/// @dev Every script here refuses a diamond that is not yet at rev028: a V2 hook must not be
///      deployed on a chain until the rev028 cut is live there.
library Rev028Precondition {
    function requireRev028(address diamond) internal view {
        (bool ok, bytes memory ret) = diamond.staticcall(abi.encodeWithSignature("diamondVersion()"));
        require(ok && ret.length == 32 && abi.decode(ret, (uint256)) >= 28, "Hooks V2: diamond is not at rev028");
    }
}

interface IAuthorizedRelayerV2 {
    function authorizedRelayer() external view returns (address);
}

/// @notice Deploys the shared payout gate hook (rev028). Opt-in per task; never a default hook.
/// @dev Required env vars: FORGE_DEV_PRIVATE_KEY, FORGE_DIAMOND_ADDRESS.
contract DeployPayoutGateHook is Script {
    function run() external returns (PayoutGateHook gate) {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        Rev028Precondition.requireRev028(diamond);
        vm.startBroadcast(deployerKey);
        gate = new PayoutGateHook(diamond);
        vm.stopBroadcast();
        require(gate.diamond() == diamond, "Payout gate: diamond mismatch");
        console.log("=== Payout gate hook deployment ===");
        console.log("PayoutGateHook:", address(gate));
    }
}

/// @notice Deploys SponsoredTaskHookV2 behind an ERC-1967 proxy and a SponsoredTaskFactoryV2 whose
///         vaults are bound to it. The existing registry is reused: when the registry is owned by
///         the admin (a Safe or timelock), the script prints the setFactory call for it to execute.
/// @dev Required env vars:
///   FORGE_DEV_PRIVATE_KEY, FORGE_DIAMOND_ADDRESS, FORGE_USDC_TOKEN_ADDRESS,
///   FORGE_SPONSORED_TASK_REGISTRY      -- the deployed SponsoredTaskRegistry
///   FORGE_SPONSORED_TASK_FEE_POLICY    -- the deployed SponsoredTaskFeePolicy
///   FORGE_SPONSORED_TASK_ADMIN         -- a contract (Safe or timelock) that owns the proxy
///   FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT
/// Optional: FORGE_SPONSORED_TASK_CREATION_FEE_USDC (default 1,000,000).
contract DeploySponsoredTaskHookV2 is Script {
    function run() external returns (SponsoredTaskHookV2 hook, SponsoredTaskFactoryV2 factory) {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        Rev028Precondition.requireRev028(diamond);
        IERC20 usdc = IERC20(vm.envAddress("FORGE_USDC_TOKEN_ADDRESS"));
        SponsoredTaskRegistry registry = SponsoredTaskRegistry(vm.envAddress("FORGE_SPONSORED_TASK_REGISTRY"));
        address admin = vm.envAddress("FORGE_SPONSORED_TASK_ADMIN");
        require(admin.code.length != 0, "Sponsored Task V2: admin must be a contract");
        require(admin != deployer, "Sponsored Task V2: admin must not be the deployer");
        uint256 creationFee = vm.envOr("FORGE_SPONSORED_TASK_CREATION_FEE_USDC", uint256(1_000_000));

        vm.startBroadcast(deployerKey);
        address implementation =
            address(new SponsoredTaskHookV2(diamond, usdc, ISponsoredTaskRegistry(address(registry))));
        hook = SponsoredTaskHookV2(
            address(new ERC1967Proxy(implementation, abi.encodeCall(SponsoredTaskHookV2.initialize, (admin))))
        );
        factory = new SponsoredTaskFactoryV2(
            address(hook),
            vm.envAddress("FORGE_SPONSORED_TASK_FEE_POLICY"),
            registry,
            SponsoredTaskCreationFee.CreationFeeConfig({
                token: usdc,
                amount: creationFee,
                recipient: vm.envAddress("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT")
            })
        );
        bool registered = registry.owner() == deployer;
        if (registered) registry.setFactory(address(factory), true);
        vm.stopBroadcast();

        require(hook.owner() == admin, "Sponsored Task V2: hook owner is not the admin");
        require(hook.diamond() == diamond, "Sponsored Task V2: diamond mismatch");
        console.log("=== Sponsored Task V2 deployment ===");
        console.log("SponsoredTaskHookV2 (proxy):", address(hook));
        console.log("Implementation:             ", implementation);
        console.log("SponsoredTaskFactoryV2:     ", address(factory));
        if (!registered) {
            console.log("Registry owner must execute on the registry:", address(registry));
            console.logBytes(abi.encodeCall(SponsoredTaskRegistry.setFactory, (address(factory), true)));
        }
    }
}

/// @notice Deploys RemoteSponsoredTaskHookV2 behind an ERC-1967 proxy. Remote vaults are bound to
///         the settler, not to the hook, so existing remote vaults serve it unchanged.
/// @dev Required env vars: FORGE_DEV_PRIVATE_KEY, FORGE_DIAMOND_ADDRESS,
///      FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN (a contract that owns the proxy).
contract DeployRemoteSponsoredTaskHookV2 is Script {
    function run() external returns (RemoteSponsoredTaskHookV2 hook) {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        Rev028Precondition.requireRev028(diamond);
        address admin = vm.envAddress("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN");
        require(admin.code.length != 0, "Remote hook V2: admin must be a contract");
        require(admin != deployer, "Remote hook V2: admin must not be the deployer");

        vm.startBroadcast(deployerKey);
        address implementation = address(new RemoteSponsoredTaskHookV2(diamond));
        hook = RemoteSponsoredTaskHookV2(
            address(new ERC1967Proxy(implementation, abi.encodeCall(RemoteSponsoredTaskHookV2.initialize, (admin))))
        );
        vm.stopBroadcast();

        require(hook.owner() == admin, "Remote hook V2: owner is not the admin");
        require(hook.diamond() == diamond, "Remote hook V2: diamond mismatch");
        console.log("=== Remote Sponsored Task V2 hook deployment ===");
        console.log("RemoteSponsoredTaskHookV2 (proxy):", address(hook));
        console.log("Implementation:                   ", implementation);
    }
}

/// @notice Deploys TaskTokenRewardHookV2 (the DREAMS reward hook for V2 tasks) behind its own proxy,
///         with its own RewardVault and EpochBudget, each pointed at it. It does not touch the
///         diamond's default hooks: SetDefaultHooksV2 does that as a separate step.
/// @dev Same env vars as DeployRewardHook: FORGE_DEV_PRIVATE_KEY, FORGE_PROTOCOL_TOKEN,
///      FORGE_DIAMOND_ADDRESS, FORGE_PGTR_FORWARDER, FORGE_DREAMS_PER_USDC, FORGE_BONUS_BPS,
///      FORGE_EPOCH_DURATION, FORGE_GLOBAL_EPOCH_CAP_USD, FORGE_WORKER_CAP_USD,
///      FORGE_REQUESTER_CAP_USD, FORGE_MAX_USD_PER_TASK; optional FORGE_WORKER_SPLIT_BPS.
contract DeployRewardHookV2 is Script {
    function run() external returns (TaskTokenRewardHookV2 hook) {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        Rev028Precondition.requireRev028(diamond);
        address token = vm.envAddress("FORGE_PROTOCOL_TOKEN");

        vm.startBroadcast(deployerKey);
        RewardVault vault = new RewardVault(token, deployer);
        EpochBudget budget = new EpochBudget(
            vm.envUint("FORGE_EPOCH_DURATION"),
            vm.envUint("FORGE_GLOBAL_EPOCH_CAP_USD"),
            vm.envUint("FORGE_WORKER_CAP_USD"),
            vm.envUint("FORGE_REQUESTER_CAP_USD"),
            vm.envUint("FORGE_MAX_USD_PER_TASK"),
            deployer
        );
        hook = _proxy(address(vault), address(budget), diamond, token, deployer);
        vault.setHook(address(hook));
        budget.setHook(address(hook));
        vm.stopBroadcast();

        console.log("=== TaskTokenRewardHookV2 deployment ===");
        console.log("RewardVault:           ", address(vault));
        console.log("EpochBudget:           ", address(budget));
        console.log("TaskTokenRewardHookV2: ", address(hook));
        console.log("Not yet a default hook -- run set-default-hooks-v2 to add it");
    }

    function _proxy(address vault, address budget, address diamond, address token, address owner)
        internal
        returns (TaskTokenRewardHookV2)
    {
        bytes memory init = abi.encodeCall(
            TaskTokenRewardHookV2.initialize,
            (
                vault,
                budget,
                diamond,
                IERC20Metadata(token).decimals(),
                vm.envUint("FORGE_DREAMS_PER_USDC") * 1e18,
                ScriptBounds.bps(vm.envUint("FORGE_BONUS_BPS"), "FORGE_BONUS_BPS"),
                token,
                ScriptBounds.bps(vm.envOr("FORGE_WORKER_SPLIT_BPS", uint256(8000)), "FORGE_WORKER_SPLIT_BPS"),
                IAuthorizedRelayerV2(vm.envAddress("FORGE_PGTR_FORWARDER")).authorizedRelayer(),
                owner
            )
        );
        return TaskTokenRewardHookV2(address(new ERC1967Proxy(address(new TaskTokenRewardHookV2()), init)));
    }
}

/// @notice Replaces the diamond's protocol default V2 hooks (at most two), attached first to every new
///         task. FORGE_DEFAULT_HOOKS_V2 is a comma-separated address list; empty clears the defaults.
/// @dev Required env vars: FORGE_DEV_PRIVATE_KEY (the diamond owner), FORGE_DIAMOND_ADDRESS,
///      FORGE_DEFAULT_HOOKS_V2.
contract SetDefaultHooksV2 is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS");
        Rev028Precondition.requireRev028(diamond);
        address[] memory hooks = vm.envOr("FORGE_DEFAULT_HOOKS_V2", ",", new address[](0));
        vm.startBroadcast(ownerKey);
        ITMPHooksV2(diamond).setDefaultHooksV2(hooks);
        vm.stopBroadcast();
        console.log("=== Default V2 hooks set ===");
        for (uint256 i; i < hooks.length; ++i) {
            console.log("default hook:", hooks[i]);
        }
    }
}
