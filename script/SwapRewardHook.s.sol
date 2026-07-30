// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { TaskTokenRewardHook } from "../src/hooks/TaskTokenRewardHook.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IDiamondAdmin {
    function setDefaultHooks(address[] calldata hooks) external;
}

interface IAuthorizedRelayer {
    function authorizedRelayer() external view returns (address);
}

/// @title SwapRewardHook — ship issue #202's EpochBudget.release() epoch-mismatch fix by
///        deploying a fresh EpochBudget + TaskTokenRewardHook and re-pointing the EXISTING
///        RewardVault at the new hook
/// @notice Unlike DeployRewardHook.s.sol (first-time deployment), this reuses the
///         already-deployed RewardVault instead of deploying a fresh one -- no balance
///         migration, no dual-vault overlap window. This is only safe once the
///         vault has zero outstanding reservations: the script asserts
///         `RewardVault.totalReserved() == 0` and reverts otherwise, rather than silently
///         deauthorizing the old hook out from under a live reservation.
/// @dev Required env vars (mirrors DeployRewardHook.s.sol, plus the existing vault address):
///
///   FORGE_DEV_PRIVATE_KEY            — owner key (must match RewardVault's and the Diamond's
///                                       owner)
///   FORGE_REWARD_VAULT_ADDRESS       — the EXISTING RewardVault to reuse (not redeployed).
///                                       Its DREAMS token address is read directly from
///                                       `vault.token()` -- not a separate env var -- so the
///                                       new hook can never be pointed at a mismatched token.
///   FORGE_DIAMOND_ADDRESS            — TaskMarket Diamond proxy
///   FORGE_PGTR_FORWARDER             — TaskMarketForwarder address; its authorizedRelayer()
///                                       is read on-chain and used as the reward hook's
///                                       backend address, matching the original deployment
///   FORGE_DREAMS_PER_USDC            — whole DREAMS per $1 (e.g. 347); scaled by 1e18 here
///   FORGE_BONUS_BPS                  — USD bonus % of task value in bps (e.g. 750 = 7.5%)
///   FORGE_EPOCH_DURATION             — epoch length in seconds (e.g. 604800 = 7 days)
///   FORGE_GLOBAL_EPOCH_CAP_USD       — max USD-value emitted per epoch (USDC base units)
///   FORGE_WORKER_CAP_USD             — per-worker per-epoch cap (USDC base units)
///   FORGE_REQUESTER_CAP_USD          — per-requester per-epoch cap (USDC base units)
///   FORGE_MAX_USD_PER_TASK           — per-task emission cap (USDC base units)
///
///   FORGE_WORKER_SPLIT_BPS           — worker share in bps (default 8000 = 80%)
///
///   SKIP_RESERVATION_CHECK           — DANGEROUS, default false. Bypasses the
///                                       totalReserved()==0 guard below. Setting this true
///                                       means any reservation still outstanding on the old
///                                       hook is silently orphaned -- no revert, no event, no
///                                       error anywhere. Only ever set this after
///                                       independently confirming (e.g. via the Reserved/
///                                       Released/Paid event reconciliation this repo already
///                                       does by hand) that every outstanding reservation is
///                                       either dust you are deliberately writing off or
///                                       otherwise unrecoverable, never as a default habit.
///
/// Usage:
///   make swap-reward-hook testnet
///   make swap-reward-hook mainnet
///   make swap-reward-hook testnet force   # skips the reservation guard -- see above
///   make swap-reward-hook mainnet force   # skips the reservation guard -- see above
contract SwapRewardHook is Script {
    error VaultHasOutstandingReservations(uint256 totalReserved);

    function run() external {
        _run(vm.envOr("SKIP_RESERVATION_CHECK", false));
    }

    /// @dev Split out from run() so tests can exercise both the guarded and skip-guard paths
    ///      by passing the flag directly, instead of racing vm.setEnv against Foundry's
    ///      parallel test execution (env vars are process-global, not per-test-isolated).
    function _run(bool skipCheck) public {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(ownerKey);
        RewardVault vault = RewardVault(vm.envAddress("FORGE_REWARD_VAULT_ADDRESS"));

        uint256 totalReserved = vault.totalReserved();
        if (totalReserved != 0) {
            if (!skipCheck) revert VaultHasOutstandingReservations(totalReserved);
            console.log("!!! SKIP_RESERVATION_CHECK=true: proceeding with outstanding reservations !!!");
            console.log("!!! Outstanding totalReserved (wei):", totalReserved);
            console.log("!!! Any in-flight reward on the old hook is now UNRECOVERABLE via this script !!!");
        }

        vm.startBroadcast(ownerKey);

        EpochBudget budget = _deployBudget(deployer);
        TaskTokenRewardHook hook = _deployHook(vault, budget, deployer);

        budget.setHook(address(hook));
        vault.setHook(address(hook));

        // Preserves existing behavior from DeployRewardHook.s.sol: replaces the full
        // default-hook list. Read getDefaultHooks() first if other hooks must be retained
        // alongside this one -- as of this script there is only ever the one reward hook.
        address[] memory defaultHooks = new address[](1);
        defaultHooks[0] = address(hook);
        IDiamondAdmin(vm.envAddress("FORGE_DIAMOND_ADDRESS")).setDefaultHooks(defaultHooks);

        vm.stopBroadcast();

        console.log("=== TaskTokenRewardHook swap complete ===");
        console.log("RewardVault (reused):", address(vault));
        console.log("EpochBudget (new):   ", address(budget));
        console.log("TaskTokenRewardHook (new):", address(hook));
        console.log("Backend (from forwarder's authorizedRelayer):", hook.backend());
        console.log("Diamond default hooks: set to [TaskTokenRewardHook]");
    }

    function _deployBudget(address deployer) internal returns (EpochBudget budget) {
        budget = new EpochBudget(
            vm.envUint("FORGE_EPOCH_DURATION"),
            vm.envUint("FORGE_GLOBAL_EPOCH_CAP_USD"),
            vm.envUint("FORGE_WORKER_CAP_USD"),
            vm.envUint("FORGE_REQUESTER_CAP_USD"),
            vm.envUint("FORGE_MAX_USD_PER_TASK"),
            deployer
        );
    }

    function _deployHook(RewardVault vault, EpochBudget budget, address deployer)
        internal
        returns (TaskTokenRewardHook hook)
    {
        address protocolToken = address(vault.token());
        uint256 dreamsPerUsdc = vm.envUint("FORGE_DREAMS_PER_USDC") * 1e18;
        address backendAddress = IAuthorizedRelayer(vm.envAddress("FORGE_PGTR_FORWARDER")).authorizedRelayer();
        hook = new TaskTokenRewardHook(
            address(vault),
            address(budget),
            vm.envAddress("FORGE_DIAMOND_ADDRESS"),
            IERC20Metadata(protocolToken).decimals(),
            dreamsPerUsdc,
            uint16(vm.envUint("FORGE_BONUS_BPS")),
            protocolToken,
            uint16(vm.envOr("FORGE_WORKER_SPLIT_BPS", uint256(8000))),
            backendAddress,
            deployer
        );
    }
}
