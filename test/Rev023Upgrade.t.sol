// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../src/facets/RatingFacet.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev023Upgrade } from "../script/upgrades/Rev023Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev023UpgradeTest
/// @dev Rev023 replaces four facets, because the gas guards are compiled into each one from an
///      internal library. The parity test only compares selector sets, so this test asserts the
///      bytecode behind every selector actually moved, facet by facet.
contract Rev023UpgradeTest is Test, DiamondTestHelper {
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

    function _assertReplaced(
        address diamond,
        bytes4 probe,
        bytes4[] memory selectors,
        address oldFacet,
        string memory name
    ) internal view {
        address newFacet = IDiamondLoupe(diamond).facetAddress(probe);
        assertTrue(newFacet != oldFacet, string.concat(name, " must be replaced"));
        for (uint256 i; i < selectors.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(selectors[i]),
                newFacet,
                string.concat("every ", name, " selector must route to the replaced facet")
            );
        }
    }

    function test_Rev023Upgrade_BumpsVersionAndReplacesEveryGuardedFacet() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 22);
        _setUpgradeEnv(diamond);

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address oldAcceptance = loupe.facetAddress(AcceptanceFacet.acceptSubmission.selector);
        address oldCore = loupe.facetAddress(CoreFacet.cancelTask.selector);
        address oldEvaluator = loupe.facetAddress(EvaluatorFacet.evaluate.selector);
        address oldRating = loupe.facetAddress(RatingFacet.rateTask.selector);

        new Rev023Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 23, "diamondVersion must reach rev023");
        _assertReplaced(
            diamond,
            AcceptanceFacet.acceptSubmission.selector,
            FacetSelectors.acceptFacetSelectors(),
            oldAcceptance,
            "AcceptanceFacet"
        );
        _assertReplaced(
            diamond, CoreFacet.cancelTask.selector, FacetSelectors.coreFacetSelectors(), oldCore, "CoreFacet"
        );
        _assertReplaced(
            diamond,
            EvaluatorFacet.evaluate.selector,
            FacetSelectors.evalFacetSelectors(),
            oldEvaluator,
            "EvaluatorFacet"
        );
        _assertReplaced(
            diamond, RatingFacet.rateTask.selector, FacetSelectors.ratingFacetSelectors(), oldRating, "RatingFacet"
        );
    }

    function test_RevertWhen_Rev023Upgrade_NotAtRev022() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 21);
        _setUpgradeEnv(diamond);

        Rev023Upgrade runner = new Rev023Upgrade();
        vm.expectRevert(bytes("Rev023Upgrade: diamond is not at rev022"));
        runner.run();
    }
}
