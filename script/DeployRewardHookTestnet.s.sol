// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { TaskTokenRewardHook } from "../src/hooks/TaskTokenRewardHook.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

interface IDiamondAdmin {
    function setDefaultHooks(address[] calldata hooks) external;
}

interface IAuthorizedRelayer {
    function authorizedRelayer() external view returns (address);
}

/// @notice Testnet deployment of the token reward hook stack using a mock token.
///         Use for smoke-testing only. Not suitable for mainnet.
///
/// Required env vars:
///   FORGE_DEV_PRIVATE_KEY        — deployer/owner key
///   FORGE_DIAMOND_ADDRESS        — TaskMarket Diamond proxy on testnet
///   FORGE_PGTR_FORWARDER         — TaskMarketForwarder address; its authorizedRelayer() is read
///                                  on-chain and used as the reward hook's backend address, same
///                                  as the mainnet script, so the two can never drift out of sync
///
/// Optional:
///   FORGE_DREAMS_PER_USDC        — whole DREAMS per $1 (default: 347); scaled by 1e18 in this script
///   FORGE_BONUS_BPS              — USD bonus % of task value in bps (default: 750 = 7.5%,
///                                  matching the platform fee)
///   FORGE_INITIAL_VAULT_BALANCE  — mock DREAMS tokens to mint to the deployer wallet (default:
///                                  1_000_000e18); minted to the deployer, not the vault, so the
///                                  smoke test exercises the same plain-transfer funding path a
///                                  human would use on mainnet
///   FORGE_EPOCH_DURATION         — seconds (default: 604800 = 7 days)
///   FORGE_GLOBAL_EPOCH_CAP_USD   — USDC base units (default: 100_000e6)
///   FORGE_WORKER_CAP_USD         — USDC base units (default: 10_000e6)
///   FORGE_REQUESTER_CAP_USD      — USDC base units (default: 50_000e6)
///   FORGE_MAX_USD_PER_TASK       — USDC base units (default: 5_000e6)
///   FORGE_WORKER_SPLIT_BPS       — worker share in bps (default: 8000 = 80%)
contract DeployRewardHookTestnet is Script {
    uint8 constant TOKEN_DECIMALS = 18;

    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);

        MockERC20 token = new MockERC20("Mock DREAMS", "mDREAMS", TOKEN_DECIMALS, deployer);
        RewardVault vault = new RewardVault(address(token), deployer);
        EpochBudget budget = new EpochBudget(
            vm.envOr("FORGE_EPOCH_DURATION", uint256(604_800)),
            vm.envOr("FORGE_GLOBAL_EPOCH_CAP_USD", uint256(100_000e6)),
            vm.envOr("FORGE_WORKER_CAP_USD", uint256(10_000e6)),
            vm.envOr("FORGE_REQUESTER_CAP_USD", uint256(50_000e6)),
            vm.envOr("FORGE_MAX_USD_PER_TASK", uint256(5_000e6)),
            deployer
        );
        uint256 dreamsPerUsdc = vm.envOr("FORGE_DREAMS_PER_USDC", uint256(347)) * 1e18;
        address backendAddress = IAuthorizedRelayer(vm.envAddress("FORGE_PGTR_FORWARDER")).authorizedRelayer();
        TaskTokenRewardHook hook = new TaskTokenRewardHook(
            address(vault),
            address(budget),
            vm.envAddress("FORGE_DIAMOND_ADDRESS"),
            TOKEN_DECIMALS,
            dreamsPerUsdc,
            uint16(vm.envOr("FORGE_BONUS_BPS", uint256(750))),
            address(token),
            uint16(vm.envOr("FORGE_WORKER_SPLIT_BPS", uint256(8000))),
            backendAddress,
            deployer
        );

        vault.setHook(address(hook));
        budget.setHook(address(hook));

        uint256 vaultSeed = vm.envOr("FORGE_INITIAL_VAULT_BALANCE", uint256(1_000_000e18));
        token.mint(deployer, vaultSeed);

        // Bypass wallet-age ramp for testnet so new wallets earn full rewards immediately.
        // Thresholds are 1/2/3 seconds; multipliers are all 10000 bps (100%).
        uint40[3] memory rampThresholds = [uint40(1), uint40(2), uint40(3)];
        uint16[4] memory rampMultipliers = [uint16(10000), uint16(10000), uint16(10000), uint16(10000)];
        hook.setRamp(rampThresholds, rampMultipliers);

        address[] memory defaultHooks = new address[](1);
        defaultHooks[0] = address(hook);
        IDiamondAdmin(vm.envAddress("FORGE_DIAMOND_ADDRESS")).setDefaultHooks(defaultHooks);

        vm.stopBroadcast();

        console.log("=== TokenRewardHook testnet deployment (mock) ===");
        console.log("MockERC20 (mDREAMS):  ", address(token));
        console.log("RewardVault:          ", address(vault));
        console.log("EpochBudget:          ", address(budget));
        console.log("TaskTokenRewardHook:  ", address(hook));
        console.log("Deployer minted (wei):", vaultSeed);
        console.log("Backend (from forwarder's authorizedRelayer):", hook.backend());
        console.log("Diamond default hooks: set to [TaskTokenRewardHook]");
        console.log("Vault is unfunded -- transfer DREAMS to RewardVault to enable payouts");
    }
}
