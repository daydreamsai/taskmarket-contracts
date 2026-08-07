// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { Rev013Upgrade } from "../script/upgrades/Rev013Upgrade.s.sol";
import { Rev015Upgrade } from "../script/upgrades/Rev015Upgrade.s.sol";
import { Rev016Upgrade } from "../script/upgrades/Rev016Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev016UpgradeTest
/// @dev Deploys a diamond at rev011 (the test helper's baseline), advances through
///      rev012/013/014/015 to reach rev016's precondition, applies the rev016 upgrade step, and
///      asserts diamondVersion bumps to 16 and CoreFacet is replaced with a new implementation
///      while every one of its selectors still routes. Rev016 changes no parameter list, so the
///      selector set must come through the cut identical -- that is the property under test, and
///      a Replace that silently dropped or misrouted a selector is exactly the failure mode a
///      pure-Replace step can have.
contract Rev016UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    function _advanceToRev015(address diamond) internal {
        // Rev016Upgrade resolves the diamond only for chain ids it names, so the test has to be
        // on one of them. Base Sepolia rather than mainnet: the testnet env var is what the
        // earlier upgrade steps below read too.
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));
        new Rev012Upgrade().run();
        new Rev013Upgrade().run();
        // Rev014Upgrade cannot run here for the reason Rev015UpgradeTest documents: it Removes
        // the pre-rev014 createTask selector, but a fresh test diamond is already built from
        // FacetSelectors and therefore already carries the current one. Only the counter needs
        // to catch up.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(14);
        new Rev015Upgrade().run();
    }

    function test_Rev016Upgrade_BumpsVersionAndReplacesCoreFacet() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));
        _advanceToRev015(diamond);
        assertEq(AdminFacet(diamond).diamondVersion(), 15, "must be at rev015 before rev016");

        address oldCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.refundExpired.selector);

        // Ask the diamond what the old facet was actually serving, rather than assuming it was
        // serving coreFacetSelectors(). A Replace only touches selectors the cut names: one the
        // old facet served but the cut omits keeps routing to the OLD facet, silently leaving
        // part of a security fix uncut, and a check driven off coreFacetSelectors() alone cannot
        // see that -- it would only ever look at selectors the cut named in the first place.
        bytes4[] memory servedBefore = IDiamondLoupe(diamond).facetFunctionSelectors(oldCoreFacet);
        assertGt(servedBefore.length, 0, "old CoreFacet must serve selectors before the upgrade");

        new Rev016Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 16, "diamondVersion must be 16 after rev016 upgrade");

        address newCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.refundExpired.selector);
        assertTrue(newCoreFacet != oldCoreFacet, "CoreFacet must be replaced");

        bytes4[] memory selectors = FacetSelectors.coreFacetSelectors();

        // Nothing the old facet served may be left behind on it.
        for (uint256 i; i < servedBefore.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(servedBefore[i]),
                newCoreFacet,
                "every selector the old CoreFacet served must route to the replaced facet"
            );
            assertTrue(
                _contains(selectors, servedBefore[i]),
                "the upgrade's selector list omits a selector the old CoreFacet was serving"
            );
        }

        // And the cut may not claim more than the old facet held: an extra entry in the list is
        // a selector taken from some other facet, which a pure Replace has no business doing.
        assertEq(
            selectors.length,
            servedBefore.length,
            "coreFacetSelectors() must match the old CoreFacet's served set exactly"
        );

        // No signature changed, so every selector in the single source of truth must still route,
        // and all of them to the one new facet.
        for (uint256 i; i < selectors.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(selectors[i]),
                newCoreFacet,
                "every CoreFacet selector must route to the replaced facet"
            );
        }
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) private pure returns (bool) {
        for (uint256 i; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    function test_RevertWhen_Rev016Upgrade_NotAtRev015() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));

        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        // Diamond is still at rev011 -- rev016 requires rev015.
        Rev016Upgrade runner = new Rev016Upgrade();
        vm.expectRevert(bytes("Rev016Upgrade: diamond is not at rev015"));
        runner.run();
    }

    function test_RevertWhen_Rev016Upgrade_UnsupportedChain() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        // An unnamed chain id must stop the script, not quietly resolve to the testnet diamond.
        vm.chainId(1);
        Rev016Upgrade runner = new Rev016Upgrade();
        vm.expectRevert(bytes("Rev016Upgrade: unsupported chain id"));
        runner.run();
    }
}
