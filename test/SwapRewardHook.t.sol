// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { TaskTokenRewardHook } from "../src/hooks/TaskTokenRewardHook.sol";
import { TaskMarketForwarder } from "../src/TaskMarketForwarder.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { SwapRewardHook } from "../script/SwapRewardHook.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title SwapRewardHookTest
/// @dev Deploys the "existing, already-live" RewardVault/EpochBudget/TaskTokenRewardHook trio
///      (mirroring what DeployRewardHook.s.sol would have produced), then runs the swap
///      script per ADR-0028 and asserts: the vault is reused (not redeployed), a fresh
///      EpochBudget/hook pair is deployed and authorized, and the Diamond's default hooks
///      point at the new hook. Also asserts the script reverts instead of proceeding when the
///      vault has an outstanding reservation.
contract SwapRewardHookTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    uint256 constant EPOCH_DURATION = 7 days;
    uint256 constant GLOBAL_CAP_USD = 1_000_000 * 1e6;
    uint256 constant WORKER_CAP_USD = 100_000 * 1e6;
    uint256 constant REQUESTER_CAP_USD = 500_000 * 1e6;
    uint256 constant MAX_PER_TASK_USD = 10_000 * 1e6;

    ITMPDiamond diamond;
    TaskMarketForwarder forwarder;
    MockUSDC dreamsToken;
    RewardVault vault;
    EpochBudget oldBudget;
    TaskTokenRewardHook oldHook;
    address relayer = makeAddr("relayer");

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);

        diamond = deployDiamond(owner, usdc, feeRecipient, feeBps);
        forwarder = new TaskMarketForwarder(usdc, address(diamond), relayer);
        dreamsToken = new MockUSDC();

        vault = new RewardVault(address(dreamsToken), owner);
        oldBudget =
            new EpochBudget(EPOCH_DURATION, GLOBAL_CAP_USD, WORKER_CAP_USD, REQUESTER_CAP_USD, MAX_PER_TASK_USD, owner);
        oldHook = new TaskTokenRewardHook(
            address(vault),
            address(oldBudget),
            address(diamond),
            18,
            10e18,
            750,
            address(dreamsToken),
            8000,
            relayer,
            owner
        );
        vault.setHook(address(oldHook));
        oldBudget.setHook(address(oldHook));

        address[] memory hooks = new address[](1);
        hooks[0] = address(oldHook);
        diamond.setDefaultHooks(hooks);

        vm.stopPrank();

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_REWARD_VAULT_ADDRESS", vm.toString(address(vault)));
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(diamond)));
        vm.setEnv("FORGE_PGTR_FORWARDER", vm.toString(address(forwarder)));
        vm.setEnv("FORGE_DREAMS_PER_USDC", vm.toString(uint256(347)));
        vm.setEnv("FORGE_BONUS_BPS", vm.toString(uint256(750)));
        vm.setEnv("FORGE_EPOCH_DURATION", vm.toString(EPOCH_DURATION));
        vm.setEnv("FORGE_GLOBAL_EPOCH_CAP_USD", vm.toString(GLOBAL_CAP_USD));
        vm.setEnv("FORGE_WORKER_CAP_USD", vm.toString(WORKER_CAP_USD));
        vm.setEnv("FORGE_REQUESTER_CAP_USD", vm.toString(REQUESTER_CAP_USD));
        vm.setEnv("FORGE_MAX_USD_PER_TASK", vm.toString(MAX_PER_TASK_USD));
    }

    function test_SwapRewardHook_ReusesVaultAndAuthorizesNewHook() public {
        assertEq(vault.totalReserved(), 0, "precondition: vault must start with zero reservations");

        new SwapRewardHook().run();

        address newHook = diamond.getDefaultHooks()[0];
        assertTrue(newHook != address(oldHook), "a new hook must be deployed");
        assertEq(vault.hook(), newHook, "vault's hook must be re-pointed to the new hook, not redeployed");

        TaskTokenRewardHook hook = TaskTokenRewardHook(newHook);
        assertEq(address(hook.vault()), address(vault), "new hook must point at the SAME, reused vault");
        assertTrue(address(hook.epochBudget()) != address(oldBudget), "a new EpochBudget must be deployed");
        assertEq(hook.epochBudget().globalCapUsd(), GLOBAL_CAP_USD);
    }

    function test_RevertWhen_SwapRewardHook_VaultHasOutstandingReservations() public {
        dreamsToken.mint(address(vault), 100e18);
        vm.prank(address(oldHook));
        vault.reserve(bytes32(uint256(1)), 100e18);
        assertEq(vault.totalReserved(), 100e18);

        SwapRewardHook runner = new SwapRewardHook();
        vm.expectRevert(abi.encodeWithSelector(SwapRewardHook.VaultHasOutstandingReservations.selector, 100e18));
        runner._run(false);
    }

    function test_SwapRewardHook_SkipReservationCheck_ProceedsDespiteOutstandingReservations() public {
        dreamsToken.mint(address(vault), 100e18);
        vm.prank(address(oldHook));
        vault.reserve(bytes32(uint256(1)), 100e18);
        assertEq(vault.totalReserved(), 100e18);

        new SwapRewardHook()._run(true);

        address newHook = diamond.getDefaultHooks()[0];
        assertTrue(newHook != address(oldHook), "a new hook must still be deployed");
        assertEq(vault.hook(), newHook, "vault's hook must still be re-pointed to the new hook");
        assertEq(vault.totalReserved(), 100e18, "the outstanding reservation is left orphaned, not cleared");
    }
}
