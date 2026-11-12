// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { RemoteSponsoredTaskHookV2 } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol";
import { SponsoredTaskFactoryV2 } from "../src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol";
import { SponsoredTaskFeePolicy } from "../src/hooks/sponsored-task/SponsoredTaskFeePolicy.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";
import { TaskTokenRewardHookV2 } from "../src/hooks/TaskTokenRewardHookV2.sol";
import {
    DeployPayoutGateHook,
    DeploySponsoredTaskHookV2,
    DeployRemoteSponsoredTaskHookV2,
    DeployRewardHookV2,
    SetDefaultHooksV2,
    UpgradeRewardHookV2,
    UpgradeSponsoredTaskHookV2,
    UpgradeRemoteSponsoredTaskHookV2
} from "../script/DeployHooksV2.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @dev Code-bearing stand-in for the admin Safe or timelock.
contract HooksV2AdminStandIn { }

/// @dev The forwarder's relayer address is all the reward hook deploy reads from it.
contract RelayerStandIn {
    function authorizedRelayer() external pure returns (address) {
        return address(0xBEEF);
    }
}

/// @dev Runs each rev028 hook deploy script against a local diamond; none touches a shared network.
contract DeployHooksV2ScriptsTest is DiamondTestHelper {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;
    address private deployer;
    ITMPDiamond private market;
    MockUSDC private usdc;
    HooksV2AdminStandIn private admin;

    function setUp() public {
        deployer = vm.addr(DEPLOYER_KEY);
        usdc = new MockUSDC();
        market = deployDiamond(deployer, address(usdc), address(0xFEE), 500);
        admin = new HooksV2AdminStandIn();
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(market)));
    }

    function test_DeployPayoutGateHook() public {
        PayoutGateHook gate = new DeployPayoutGateHook().run();
        assertEq(gate.diamond(), address(market));
        assertEq(gate.hookCapabilities(), gate.CAPABILITIES());
    }

    function test_RefusesDiamondBelowRev028() public {
        placeAtVersion(address(market), 27);
        DeployPayoutGateHook script = new DeployPayoutGateHook();
        vm.expectRevert("Hooks V2: diamond is not at rev028");
        script.run();
    }

    function test_DeploySponsoredHooksV2RefuseDiamondBelowRev030() public {
        placeAtVersion(address(market), 29);
        vm.setEnv("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN", vm.toString(address(admin)));
        DeployRemoteSponsoredTaskHookV2 remote = new DeployRemoteSponsoredTaskHookV2();
        vm.expectRevert("Remote hook V2: diamond is not at rev030");
        remote.run();
        DeploySponsoredTaskHookV2 local = new DeploySponsoredTaskHookV2();
        vm.expectRevert("Sponsored Task V2: diamond is not at rev030");
        local.run();

        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(0xDEAD)));
        vm.expectRevert("Hooks V2: diamond must be a contract");
        remote.run();
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(market)));
    }

    function test_DeploySponsoredTaskHookV2AndFactory() public {
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(deployer);
        SponsoredTaskFeePolicy feePolicy = new SponsoredTaskFeePolicy(address(admin), 0, address(0xFEE));
        vm.setEnv("FORGE_USDC_TOKEN_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("FORGE_SPONSORED_TASK_REGISTRY", vm.toString(address(registry)));
        vm.setEnv("FORGE_SPONSORED_TASK_FEE_POLICY", vm.toString(address(feePolicy)));
        vm.setEnv("FORGE_SPONSORED_TASK_ADMIN", vm.toString(address(admin)));
        vm.setEnv("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT", vm.toString(address(0xFEE)));
        (SponsoredTaskHookV2 hook, SponsoredTaskFactoryV2 factory) = new DeploySponsoredTaskHookV2().run();
        assertEq(hook.owner(), address(admin));
        assertEq(hook.diamond(), address(market));
        assertEq(factory.controller(), address(hook), "vaults from this factory are bound to the V2 hook");
        assertTrue(registry.authorizedFactories(address(factory)), "registered when the deployer owns the registry");

        // Rev030: the admin owns the proxy, so the upgrade deploys the implementation only, with the
        // live proxy's immutables, and leaves the proxy (and the codehash attachments pin) as it is.
        vm.setEnv("FORGE_SPONSORED_TASK_HOOK_V2_ADDRESS", vm.toString(address(hook)));
        placeAtVersion(address(market), 29);
        UpgradeSponsoredTaskHookV2 upgrade = new UpgradeSponsoredTaskHookV2();
        vm.expectRevert("Sponsored Task V2: diamond is not at rev030");
        upgrade.run();
        placeAtVersion(address(market), 30);
        bytes32 codehash = address(hook).codehash;
        address before = _implementation(address(hook));
        SponsoredTaskHookV2 implementation = SponsoredTaskHookV2(upgrade.run());
        assertEq(_implementation(address(hook)), before, "not applied without the owner");
        assertEq(implementation.diamond(), address(market), "diamond");
        assertEq(address(implementation.usdc()), address(hook.usdc()), "usdc");
        assertEq(address(implementation.registry()), address(registry), "registry");
        vm.prank(address(admin));
        hook.upgradeToAndCall(address(implementation), "");
        assertEq(_implementation(address(hook)), address(implementation), "the owner applies it");
        assertEq(address(hook).codehash, codehash, "the proxy codehash every attachment pinned is unchanged");
        assertEq(hook.owner(), address(admin), "state kept");
    }

    function _implementation(address proxy) private view returns (address) {
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(proxy, implSlot))));
    }

    function test_DeployRemoteSponsoredTaskHookV2() public {
        vm.setEnv("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN", vm.toString(address(admin)));
        RemoteSponsoredTaskHookV2 hook = new DeployRemoteSponsoredTaskHookV2().run();
        assertEq(hook.owner(), address(admin));
        assertEq(hook.diamond(), address(market));

        vm.setEnv("FORGE_SPONSORED_TASK_REMOTE_HOOK_V2_ADDRESS", vm.toString(address(hook)));
        placeAtVersion(address(market), 29);
        UpgradeRemoteSponsoredTaskHookV2 upgrade = new UpgradeRemoteSponsoredTaskHookV2();
        vm.expectRevert("Remote hook V2: diamond is not at rev030");
        upgrade.run();
        placeAtVersion(address(market), 30);
        bytes32 codehash = address(hook).codehash;
        address implementation = upgrade.run();
        assertEq(RemoteSponsoredTaskHookV2(implementation).diamond(), address(market), "diamond");
        vm.prank(address(admin));
        hook.upgradeToAndCall(implementation, "");
        assertEq(_implementation(address(hook)), implementation, "the owner applies it");
        assertEq(address(hook).codehash, codehash, "proxy codehash unchanged");
    }

    function test_DeployRewardHookV2ThenSetDefaults() public {
        MockERC20 dreams = new MockERC20("Dreams", "DREAMS", 18, address(this));
        vm.setEnv("FORGE_PROTOCOL_TOKEN", vm.toString(address(dreams)));
        vm.setEnv("FORGE_PGTR_FORWARDER", vm.toString(address(new RelayerStandIn())));
        vm.setEnv("FORGE_DREAMS_PER_USDC", "347");
        vm.setEnv("FORGE_BONUS_BPS", "750");
        vm.setEnv("FORGE_EPOCH_DURATION", "604800");
        vm.setEnv("FORGE_GLOBAL_EPOCH_CAP_USD", "1000000000");
        vm.setEnv("FORGE_WORKER_CAP_USD", "100000000");
        vm.setEnv("FORGE_REQUESTER_CAP_USD", "100000000");
        vm.setEnv("FORGE_MAX_USD_PER_TASK", "10000000");

        // Rev030: without an admin contract the script refuses, so no deployer key keeps ownership.
        DeployRewardHookV2 deployScript = new DeployRewardHookV2();
        vm.setEnv("FORGE_REWARD_HOOK_V2_ADMIN", vm.toString(deployer));
        vm.expectRevert("Reward hook V2: admin must be a contract");
        deployScript.run();
        vm.setEnv("FORGE_REWARD_HOOK_V2_ADMIN", vm.toString(address(admin)));

        TaskTokenRewardHookV2 hook = deployScript.run();
        assertTrue(hook.supportsInterface(type(ITMPHookV2).interfaceId));
        assertEq(hook.owner(), address(admin), "hook owner");
        assertEq(Ownable(address(hook.vault())).owner(), address(admin), "vault owner");
        assertEq(Ownable(address(hook.epochBudget())).owner(), address(admin), "budget owner");

        vm.setEnv("FORGE_DEFAULT_HOOKS_V2", vm.toString(address(hook)));
        new SetDefaultHooksV2().run();
        ITMPHookV2.Attachment[] memory defaults = ITMPHooksV2(address(market)).getDefaultHooksV2();
        assertEq(defaults.length, 1);
        assertEq(defaults[0].hook, address(hook));

        // Rev030: an in-place upgrade keeps the proxy, its state and its attachment.
        vm.setEnv("FORGE_REWARD_HOOK_V2_ADDRESS", vm.toString(address(hook)));
        placeAtVersion(address(market), 29);
        UpgradeRewardHookV2 upgrade = new UpgradeRewardHookV2();
        vm.expectRevert("Reward hook V2: diamond is not at rev030");
        upgrade.run();
        placeAtVersion(address(market), 30);
        bytes32 codehash = address(hook).codehash;
        address implementation = upgrade.run();
        // The admin owns the hook, so the script deploys the implementation only; the admin applies it.
        vm.prank(address(admin));
        hook.upgradeToAndCall(implementation, "");
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        assertEq(address(uint160(uint256(vm.load(address(hook), implSlot)))), implementation, "implementation");
        assertEq(address(hook).codehash, codehash, "the proxy codehash every attachment pinned is unchanged");
        assertEq(hook.bonusBps(), 750, "state kept");
    }
}
