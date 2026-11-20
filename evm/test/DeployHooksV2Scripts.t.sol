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
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import {
    DeployPayoutGateHook,
    DeploySponsoredTaskHookV2,
    DeployRemoteSponsoredTaskHookV2,
    DeployRewardHookV2,
    SetDefaultHooksV2,
    UpgradeRewardHookV2,
    UpgradeSponsoredTaskHookV2,
    UpgradeRemoteSponsoredTaskHookV2,
    RedeploySponsoredTaskFactoryV2,
    RedeployEpochBudget
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
        SetDefaultHooksV2 script = new SetDefaultHooksV2();
        vm.expectRevert("Hooks V2: diamond is not at rev028");
        script.run();
    }

    /// @dev Cyclops 7628: the payout gate and the reward hook rely on rev030 diamond behaviour, so their
    ///      deploys refuse a rev028 or rev029 diamond, not only one below rev028.
    function test_PayoutGateAndRewardHookDeploysRefuseDiamondBelowRev030() public {
        placeAtVersion(address(market), 29);
        DeployPayoutGateHook gate = new DeployPayoutGateHook();
        vm.expectRevert("Payout gate: diamond is not at rev030");
        gate.run();
        DeployRewardHookV2 reward = new DeployRewardHookV2();
        vm.expectRevert("Reward hook V2: diamond is not at rev030");
        reward.run();
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

    /// @dev The registry and fee policy as DeploySponsoredTask leaves them: the fee policy owned by the
    ///      admin, the registry still owned by the deployer and pending to the admin.
    function _sharedSponsoredPieces()
        private
        returns (SponsoredTaskRegistry registry, SponsoredTaskFeePolicy feePolicy)
    {
        registry = new SponsoredTaskRegistry(deployer);
        vm.prank(deployer);
        registry.transferOwnership(address(admin));
        feePolicy = new SponsoredTaskFeePolicy(address(admin), 0, address(0xFEE));
        vm.setEnv("FORGE_USDC_TOKEN_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("FORGE_SPONSORED_TASK_REGISTRY", vm.toString(address(registry)));
        vm.setEnv("FORGE_SPONSORED_TASK_FEE_POLICY", vm.toString(address(feePolicy)));
        vm.setEnv("FORGE_SPONSORED_TASK_ADMIN", vm.toString(address(admin)));
        vm.setEnv("FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT", vm.toString(address(0xFEE)));
    }

    /// @dev Cyclops 7662: the sponsored hook deploy checks the shared pieces it builds on, as
    ///      DeploySponsoredTask does when it creates them.
    function test_DeploySponsoredTaskHookV2RefusesUncheckedSharedPieces() public {
        (SponsoredTaskRegistry registry, SponsoredTaskFeePolicy feePolicy) = _sharedSponsoredPieces();
        DeploySponsoredTaskHookV2 script = new DeploySponsoredTaskHookV2();

        vm.setEnv("FORGE_SPONSORED_TASK_REGISTRY", vm.toString(address(0xDEAD)));
        vm.expectRevert("Sponsored Task V2: registry must be a contract");
        script.run();
        vm.setEnv("FORGE_SPONSORED_TASK_REGISTRY", vm.toString(address(registry)));

        vm.setEnv("FORGE_SPONSORED_TASK_FEE_POLICY", vm.toString(address(0xDEAD)));
        vm.expectRevert("Sponsored Task V2: fee policy must be a contract");
        script.run();

        SponsoredTaskFeePolicy otherPolicy = new SponsoredTaskFeePolicy(deployer, 0, address(0xFEE));
        vm.setEnv("FORGE_SPONSORED_TASK_FEE_POLICY", vm.toString(address(otherPolicy)));
        vm.expectRevert("Sponsored Task V2: fee policy owner is not the admin");
        script.run();
        vm.setEnv("FORGE_SPONSORED_TASK_FEE_POLICY", vm.toString(address(feePolicy)));

        SponsoredTaskRegistry deployerRegistry = new SponsoredTaskRegistry(deployer);
        vm.setEnv("FORGE_SPONSORED_TASK_REGISTRY", vm.toString(address(deployerRegistry)));
        vm.expectRevert("Sponsored Task V2: registry is neither owned by nor pending to the admin");
        script.run();

        // Once the admin has accepted the registry, the script leaves the setFactory call to it.
        vm.setEnv("FORGE_SPONSORED_TASK_REGISTRY", vm.toString(address(registry)));
        vm.prank(address(admin));
        registry.acceptOwnership();
        (, SponsoredTaskFactoryV2 factory) = script.run();
        assertFalse(registry.authorizedFactories(address(factory)), "left to the registry owner");
    }

    function test_DeploySponsoredTaskHookV2AndFactory() public {
        (SponsoredTaskRegistry registry,) = _sharedSponsoredPieces();
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

    /// @dev Rev031: a new factory copies the live one's controller, fee policy, registry and creation
    ///      fee, clones vaults from a new implementation, and leaves the old factory authorized.
    function test_RedeploySponsoredTaskFactoryCopiesTheLiveOne() public {
        (SponsoredTaskRegistry registry,) = _sharedSponsoredPieces();
        (SponsoredTaskHookV2 hook, SponsoredTaskFactoryV2 previous) = new DeploySponsoredTaskHookV2().run();

        vm.setEnv("FORGE_SPONSORED_TASK_PREVIOUS_FACTORY", vm.toString(address(previous)));
        SponsoredTaskFactoryV2 factory = new RedeploySponsoredTaskFactoryV2().run();
        assertEq(factory.controller(), address(hook), "same controller");
        assertEq(factory.feePolicy(), previous.feePolicy(), "same fee policy");
        assertEq(address(factory.registry()), address(registry), "same registry");
        assertEq(address(factory.feeToken()), address(previous.feeToken()), "same fee token");
        assertEq(factory.creationFee(), previous.creationFee(), "same creation fee");
        assertEq(factory.creationFeeRecipient(), previous.creationFeeRecipient(), "same fee recipient");
        assertTrue(factory.implementation() != previous.implementation(), "a new vault implementation");
        assertTrue(registry.authorizedFactories(address(factory)), "new factory registered");
        assertTrue(registry.authorizedFactories(address(previous)), "old factory still authorized");
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

        // Rev031: a new epoch budget copies the live one and is left for the hook's owner to switch to.
        EpochBudget previous = hook.epochBudget();
        EpochBudget budget = new RedeployEpochBudget().run();
        assertTrue(address(budget) != address(previous), "a new budget");
        assertEq(budget.epochDuration(), previous.epochDuration(), "duration");
        assertEq(budget.globalCapUsd(), previous.globalCapUsd(), "global cap");
        assertEq(budget.workerCapUsd(), previous.workerCapUsd(), "worker cap");
        assertEq(budget.requesterCapUsd(), previous.requesterCapUsd(), "requester cap");
        assertEq(budget.maxUsdPerTask(), previous.maxUsdPerTask(), "per-task cap");
        assertEq(budget.owner(), address(admin), "owned by the live budget's owner");
        assertEq(budget.hook(), address(hook), "serves the hook");
        assertEq(previous.hook(), address(hook), "the old budget still releases its reservations");
        assertEq(address(hook.epochBudget()), address(previous), "not switched without the hook owner");
        vm.prank(address(admin));
        hook.setEpochBudget(address(budget));
        assertEq(address(hook.epochBudget()), address(budget), "the owner switches the hook");
    }
}
