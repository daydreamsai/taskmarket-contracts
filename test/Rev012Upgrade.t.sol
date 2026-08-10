// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev012UpgradeTest
/// @dev Deploys a diamond at rev011 (a fresh deploy already starts there), applies the rev012
///      upgrade step, and asserts diamondVersion bumps to 12 and CoreFacet/AcceptanceFacet are
///      replaced with new implementations while their selector sets are unchanged.
contract Rev012UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    function test_Rev012Upgrade_BumpsVersionAndReplacesFacets() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));
        assertEq(AdminFacet(diamond).diamondVersion(), 11, "fresh deploy must start at rev011");

        address oldCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);
        address oldAcceptFacet = IDiamondLoupe(diamond).facetAddress(AcceptanceFacet.acceptSubmission.selector);

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        new Rev012Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 12, "diamondVersion must be 12 after rev012 upgrade");

        address newCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);
        address newAcceptFacet = IDiamondLoupe(diamond).facetAddress(AcceptanceFacet.acceptSubmission.selector);
        assertTrue(newCoreFacet != oldCoreFacet, "CoreFacet must be replaced");
        assertTrue(newAcceptFacet != oldAcceptFacet, "AcceptanceFacet must be replaced");

        // Selector set is unchanged -- rejectSubmission and acceptSubmissions still route.
        assertEq(
            IDiamondLoupe(diamond).facetAddress(CoreFacet.rejectSubmission.selector),
            newCoreFacet,
            "CoreFacet selector set must be unchanged"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(AcceptanceFacet.acceptSubmissions.selector),
            newAcceptFacet,
            "AcceptanceFacet selector set must be unchanged"
        );
    }

    function test_RevertWhen_Rev012Upgrade_NotAtRev011() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        Rev012Upgrade runner = new Rev012Upgrade();
        runner.run();

        // Diamond is now at rev012; running it again must revert instead of silently re-applying.
        vm.expectRevert(bytes("Rev012Upgrade: diamond is not at rev011"));
        runner.run();
    }
}
