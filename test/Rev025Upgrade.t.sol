// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../src/facets/RatingFacet.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev025Upgrade } from "../script/upgrades/Rev025Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev025UpgradeTest
/// @dev Rev025 Adds SettlementFacet and the terms-taking selectors, and Replaces RatingFacet,
///      AcceptanceFacet and EvaluatorFacet. The parity test only compares selector sets, so this
///      test asserts the bytecode behind those facets' selectors actually moved.
contract Rev025UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    function _setUpgradeEnv(address diamond) internal {
        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TEMPO_MAINNET", vm.toString(diamond));
    }

    /// @dev Selectors rev025 Adds. A test diamond is built from the current FacetSelectors, which
    ///      already routes them; removing them reconstructs a rev024 diamond so the Add path runs.
    function _rev025Selectors() internal pure returns (bytes4[] memory s) {
        bytes4[] memory settlement = FacetSelectors.settlementFacetSelectorsAdded();
        bytes4[] memory feedback = FacetSelectors.feedbackFacetSelectors();
        s = new bytes4[](settlement.length + feedback.length + 8);
        s[0] = ITMPTerms.createTask.selector;
        s[1] = AdminFacet.setTermsBounds.selector;
        s[2] = AdminFacet.setTaskLimits.selector;
        s[3] = AdminFacet.taskLimits.selector;
        s[4] = AdminFacet.minEvaluationWindowSecs.selector;
        s[5] = AdminFacet.setMinEvaluationWindowSecs.selector;
        s[6] = AdminFacet.setIdentityRegistry.selector;
        s[7] = AdminFacet.identityRegistry.selector;
        for (uint256 i; i < settlement.length; ++i) {
            s[i + 8] = settlement[i];
        }
        for (uint256 i; i < feedback.length; ++i) {
            s[i + 8 + settlement.length] = feedback[i];
        }
    }

    function _deployRev024(address diamondOwner) internal returns (address diamond) {
        diamond = deployDiamondAtVersion(diamondOwner, usdc, feeRecipient, feeBps, 24);
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, _rev025Selectors());
        vm.prank(diamondOwner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        _setUpgradeEnv(diamond);
    }

    function _assertReplaced(
        address diamond,
        bytes4 probe,
        bytes4[] memory selectors,
        address oldFacet,
        string memory name
    ) internal view {
        address newFacet = IDiamondLoupe(diamond).facetAddress(probe);
        assertTrue(newFacet != address(0), string.concat(name, " must stay routed"));
        assertTrue(newFacet != oldFacet, string.concat(name, " must be replaced"));
        for (uint256 i; i < selectors.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(selectors[i]),
                newFacet,
                string.concat("every ", name, " selector must route to the replaced facet")
            );
        }
    }

    function test_Rev025Upgrade_BumpsVersionAndReplacesAwardFacets() public {
        address diamond = _deployRev024(owner);

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address oldAcceptance = loupe.facetAddress(AcceptanceFacet.acceptSubmission.selector);
        address oldEvaluator = loupe.facetAddress(EvaluatorFacet.evaluate.selector);
        address oldRating = loupe.facetAddress(RatingFacet.rateTask.selector);
        assertEq(loupe.facetAddress(AdminFacet.setTermsBounds.selector), address(0), "rev024 has no terms bounds");

        new Rev025Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 25, "diamondVersion must reach rev025");
        _assertReplaced(
            diamond, RatingFacet.rateTask.selector, FacetSelectors.ratingFacetSelectors(), oldRating, "RatingFacet"
        );
        _assertReplaced(
            diamond,
            AcceptanceFacet.acceptSubmission.selector,
            FacetSelectors.acceptFacetSelectors(),
            oldAcceptance,
            "AcceptanceFacet"
        );
        _assertReplaced(
            diamond,
            EvaluatorFacet.evaluate.selector,
            FacetSelectors.evalFacetSelectors(),
            oldEvaluator,
            "EvaluatorFacet"
        );
        bytes4[] memory added = _rev025Selectors();
        for (uint256 i; i < added.length; i++) {
            assertTrue(loupe.facetAddress(added[i]) != address(0), "every rev025 selector must be routed");
        }
    }

    function test_RevertWhen_Rev025Upgrade_NotAtRev024() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 23);
        _setUpgradeEnv(diamond);

        Rev025Upgrade runner = new Rev025Upgrade();
        vm.expectRevert(bytes("Rev025Upgrade: diamond is not at rev024"));
        runner.run();
    }
}
