// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev024Upgrade } from "../script/upgrades/Rev024Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev024UpgradeTest
/// @dev Rev024 replaces AcceptanceFacet, CoreFacet, EvaluatorFacet, RatingFacet and AdminFacet, and
///      adds AdminFacet's two feedback-gas-floor selectors. The parity test only compares selector
///      sets, so this test asserts the bytecode behind every selector actually moved, facet by facet.
contract Rev024UpgradeTest is Test, DiamondTestHelper {
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

    /// @dev A test diamond is built from the current FacetSelectors, which already routes the two
    ///      selectors rev024 Adds. Remove them to reconstruct a real rev023 diamond, so the Add path
    ///      is genuinely exercised (LibDiamond rejects an Add of a routed selector).
    function _deployRev023(address diamondOwner) internal returns (address diamond) {
        diamond = deployDiamondAtVersion(diamondOwner, usdc, feeRecipient, feeBps, 23);
        bytes4[] memory sel = new bytes4[](2);
        sel[0] = AdminFacet.minFeedbackGas.selector;
        sel[1] = AdminFacet.setMinFeedbackGas.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, sel);
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
        assertTrue(newFacet != oldFacet, string.concat(name, " must be replaced"));
        for (uint256 i; i < selectors.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(selectors[i]),
                newFacet,
                string.concat("every ", name, " selector must route to the replaced facet")
            );
        }
    }

    function test_Rev024Upgrade_BumpsVersionAndReplacesEveryStakeFacet() public {
        address diamond = _deployRev023(owner);

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address oldAcceptance = loupe.facetAddress(AcceptanceFacet.acceptSubmission.selector);
        address oldCore = loupe.facetAddress(CoreFacet.cancelTask.selector);
        address oldEvaluator = loupe.facetAddress(EvaluatorFacet.evaluate.selector);
        address oldRating = loupe.facetAddress(RatingFacet.rateTask.selector);
        address oldAdmin = loupe.facetAddress(AdminFacet.pause.selector);
        assertEq(loupe.facetAddress(AdminFacet.minFeedbackGas.selector), address(0), "rev023 has no floor getter");

        new Rev024Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 24, "diamondVersion must reach rev024");
        _assertReplaced(
            diamond,
            AcceptanceFacet.acceptSubmission.selector,
            FacetSelectors.acceptFacetSelectors(),
            oldAcceptance,
            "AcceptanceFacet"
        );
        _assertReplaced(
            diamond,
            CoreFacet.cancelTask.selector,
            FacetSelectors.coreFacetSelectorsThroughRev024(),
            oldCore,
            "CoreFacet"
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
        _assertReplaced(
            diamond,
            AdminFacet.pause.selector,
            FacetSelectors.adminFacetSelectorsThroughRev024(),
            oldAdmin,
            "AdminFacet"
        );
        assertEq(AdminFacet(diamond).minFeedbackGas(), 450_000, "Base keeps the rev023 floor");
    }

    function test_Rev024Upgrade_PreservesExistingState() public {
        address diamond = _deployRev023(owner);
        address newRecipient = address(0xBEEF);
        vm.startPrank(owner);
        AdminFacet(diamond).setMinAppealWindowSecs(3600);
        AdminFacet(diamond).setFeeRecipient(newRecipient);
        AdminFacet(diamond).setDefaultFeeBps(250);
        vm.stopPrank();

        new Rev024Upgrade().run();

        assertEq(AdminFacet(diamond).minAppealWindowSecs(), 3600, "appeal-window floor survives");
        assertEq(RegistryFacet(diamond).feeRecipient(), newRecipient, "fee recipient survives");
        assertEq(RegistryFacet(diamond).defaultFeeBps(), 250, "default fee survives");
        assertEq(AdminFacet(diamond).owner(), owner, "owner survives");
        assertEq(AdminFacet(diamond).minFeedbackGas(), 450_000, "unset floor reads the default");
    }

    function test_Rev024Upgrade_SetsTempoFloor() public {
        uint256[2] memory tempoChains = [uint256(4217), uint256(42431)];
        vm.setEnv("FORGE_MIN_FEEDBACK_GAS", "1900000");
        for (uint256 i; i < tempoChains.length; i++) {
            address diamond = _deployRev023(owner);
            vm.chainId(tempoChains[i]);
            new Rev024Upgrade().run();
            assertEq(AdminFacet(diamond).minFeedbackGas(), 1_900_000, "Tempo floor set in the upgrade");
            assertEq(AdminFacet(diamond).diamondVersion(), 24);
        }
        // vm.setEnv is process-wide; zero reads as unset for the other upgrade tests.
        vm.setEnv("FORGE_MIN_FEEDBACK_GAS", "0");
    }

    function test_RevertWhen_Rev024Upgrade_NotAtRev023() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 22);
        _setUpgradeEnv(diamond);

        Rev024Upgrade runner = new Rev024Upgrade();
        vm.expectRevert(bytes("Rev024Upgrade: diamond is not at rev023"));
        runner.run();
    }
}
