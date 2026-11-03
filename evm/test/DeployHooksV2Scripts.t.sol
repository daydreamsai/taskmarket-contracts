// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
    SetDefaultHooksV2
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
    }

    function test_DeployRemoteSponsoredTaskHookV2() public {
        vm.setEnv("FORGE_SPONSORED_TASK_REMOTE_HOOK_ADMIN", vm.toString(address(admin)));
        RemoteSponsoredTaskHookV2 hook = new DeployRemoteSponsoredTaskHookV2().run();
        assertEq(hook.owner(), address(admin));
        assertEq(hook.diamond(), address(market));
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
        TaskTokenRewardHookV2 hook = new DeployRewardHookV2().run();
        assertTrue(hook.supportsInterface(type(ITMPHookV2).interfaceId));

        vm.setEnv("FORGE_DEFAULT_HOOKS_V2", vm.toString(address(hook)));
        new SetDefaultHooksV2().run();
        ITMPHookV2.Attachment[] memory defaults = ITMPHooksV2(address(market)).getDefaultHooksV2();
        assertEq(defaults.length, 1);
        assertEq(defaults[0].hook, address(hook));
    }
}
