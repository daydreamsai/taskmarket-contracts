// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ProofGateHook } from "../src/hooks/proof-gate/ProofGateHook.sol";
import { DeployProofGateHook } from "../script/DeployProofGateHook.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @dev Runs the proof gate deploy script against a local diamond; it touches no shared network.
contract DeployProofGateHookTest is DiamondTestHelper {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;
    ITMPDiamond private market;

    function setUp() public {
        MockUSDC usdc = new MockUSDC();
        market = deployDiamond(vm.addr(DEPLOYER_KEY), address(usdc), address(0xFEE), 500);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS", vm.toString(address(market)));
    }

    function test_DeployProofGateHook() public {
        ProofGateHook gate = new DeployProofGateHook().run();
        assertEq(gate.diamond(), address(market));
        assertEq(gate.hookCapabilities(), gate.CAPABILITIES());
    }

    function test_RefusesDiamondWithoutHookV2() public {
        placeAtVersion(address(market), 27);
        DeployProofGateHook script = new DeployProofGateHook();
        vm.expectRevert("Proof gate: diamond does not support Task Hook V2");
        script.run();
    }
}
