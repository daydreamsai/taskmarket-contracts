// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { Rev013Upgrade } from "../script/upgrades/Rev013Upgrade.s.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev013UpgradeTest
/// @dev Deploys a diamond at rev011, applies rev012 to reach rev012 (rev013's precondition),
///      applies the rev013 upgrade step, and asserts diamondVersion bumps to 13 and
///      CoreFacet/EvaluatorFacet are replaced with new implementations while their selector
///      sets are unchanged.
contract Rev013UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    function _advanceToRev012(address diamond) internal {
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));
        new Rev012Upgrade().run();
    }

    function test_Rev013Upgrade_BumpsVersionAndReplacesFacets() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));
        _advanceToRev012(diamond);
        assertEq(AdminFacet(diamond).diamondVersion(), 12, "must be at rev012 before rev013");

        address oldCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);
        address oldEvalFacet = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.appeal.selector);

        new Rev013Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 13, "diamondVersion must be 13 after rev013 upgrade");

        address newCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);
        address newEvalFacet = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.appeal.selector);
        assertTrue(newCoreFacet != oldCoreFacet, "CoreFacet must be replaced");
        assertTrue(newEvalFacet != oldEvalFacet, "EvaluatorFacet must be replaced");

        // Selector set is unchanged -- rejectSubmission and evaluate still route.
        assertEq(
            IDiamondLoupe(diamond).facetAddress(CoreFacet.rejectSubmission.selector),
            newCoreFacet,
            "CoreFacet selector set must be unchanged"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.evaluate.selector),
            newEvalFacet,
            "EvaluatorFacet selector set must be unchanged"
        );
    }

    function test_RevertWhen_Rev013Upgrade_NotAtRev012() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        // Diamond is still at rev011 -- rev013 requires rev012.
        Rev013Upgrade runner = new Rev013Upgrade();
        vm.expectRevert(bytes("Rev013Upgrade: diamond is not at rev012"));
        runner.run();
    }
}
