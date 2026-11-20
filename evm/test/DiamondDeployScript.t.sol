// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { DiamondDeploy } from "../script/DiamondDeploy.s.sol";

/// @dev Runs the fresh-deploy script against the local EVM under each chain id it treats differently.
///      It inherits the script: the script carries every facet's creation code, so `new DiamondDeploy()`
///      is over the contract size limit, while a test contract is deployed without one.
contract DiamondDeployScriptTest is Test, DiamondDeploy {
    uint256 private constant DEPLOYER_KEY = 0xA11CE;

    function setUp() public {
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("FORGE_USDC_TOKEN_ADDRESS", vm.toString(address(new MockUSDC())));
        vm.setEnv("FORGE_FEE_RECIPIENT_ADDRESS", vm.toString(address(0xFEE)));
        vm.setEnv("FORGE_DEFAULT_PLATFORM_FEE_BPS", "500");
        vm.setEnv("FORGE_PGTR_FORWARDER", vm.toString(address(0)));
        vm.setEnv("FORGE_ERC8004_REPUTATION_REGISTRY", vm.toString(address(0)));
        vm.setEnv("FORGE_MIN_FEEDBACK_GAS", "0");
        vm.setEnv("FORGE_HOOK_GAS_STIPEND", "0");
    }

    /// @dev Cyclops 7630, Cantina TASK-110: a fresh Tempo diamond takes the Tempo winner cap at deploy,
    ///      not the 50-entry fallback only the rev030 upgrade used to replace.
    function test_FreshTempoDiamondTakesTheTempoWinnerCap() public {
        uint256[2] memory tempo = [uint256(4217), 42431];
        for (uint256 i; i < tempo.length; ++i) {
            vm.chainId(tempo[i]);
            this.run();
            address diamond = deployed;
            assertEq(AdminFacet(diamond).maxSubmissionWinners(), 30, "Tempo cap");
        }
    }

    function test_FreshBaseDiamondKeepsTheDefaultWinnerCap() public {
        uint256[2] memory base = [uint256(8453), 84532];
        for (uint256 i; i < base.length; ++i) {
            vm.chainId(base[i]);
            this.run();
            address diamond = deployed;
            assertEq(AdminFacet(diamond).maxSubmissionWinners(), 50, "default cap");
        }
    }
}
