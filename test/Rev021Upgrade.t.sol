// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev021Upgrade } from "../script/upgrades/Rev021Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev021UpgradeTest
/// @dev Rev021 replaces EvaluatorFacet without changing its selectors or storage layout. The
///      checks prove that every evaluator selector reaches the new bytecode and only rev020
///      diamonds can take this step.
contract Rev021UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    function _setUpgradeEnv(address diamond) internal {
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));
    }

    function test_Rev021Upgrade_BumpsVersionAndReplacesEvaluatorFacet() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 20);
        _setUpgradeEnv(diamond);

        address oldEvaluatorFacet = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.evaluate.selector);

        new Rev021Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 21, "diamondVersion must reach rev021");

        address newEvaluatorFacet = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.evaluate.selector);
        assertTrue(newEvaluatorFacet != oldEvaluatorFacet, "EvaluatorFacet must be replaced");

        bytes4[] memory selectors = FacetSelectors.evalFacetSelectors();
        for (uint256 i; i < selectors.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(selectors[i]),
                newEvaluatorFacet,
                "every EvaluatorFacet selector must route to the replaced facet"
            );
        }
    }

    function test_RevertWhen_Rev021Upgrade_NotAtRev020() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 19);
        _setUpgradeEnv(diamond);

        Rev021Upgrade runner = new Rev021Upgrade();
        vm.expectRevert(bytes("Rev021Upgrade: diamond is not at rev020"));
        runner.run();
    }
}
