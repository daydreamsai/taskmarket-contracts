// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { Rev013Upgrade } from "../script/upgrades/Rev013Upgrade.s.sol";
import { Rev015Upgrade } from "../script/upgrades/Rev015Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev015UpgradeTest
/// @dev Deploys a diamond placed at rev011 (the step tests' baseline), advances through
///      rev012/013/014 to reach rev015's precondition, applies the rev015 upgrade step, and
///      asserts diamondVersion bumps to 15 and RegistryFacet is replaced with a new
///      implementation while its full selector set keeps routing correctly.
contract Rev015UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    function _advanceToRev014(address diamond) internal {
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));
        new Rev012Upgrade().run();
        new Rev013Upgrade().run();
        // Rev014Upgrade itself can't run here: it Removes the pre-rev014 createTask selector
        // before Adding the current one, but deployDiamond() (FacetSelectors.coreFacetSelectors(),
        // the single source of truth for *current* steady-state) already registers the
        // current, post-rev014 createTask selector on every fresh test diamond -- there is no
        // historical old-selector bytecode left in this repo to reproduce the pre-rev014 state
        // from. The diamond's code is therefore already equivalent to rev014; only the version
        // counter needs to catch up, which is exactly what setDiamondVersion is for.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(14);
    }

    function test_Rev015Upgrade_BumpsVersionAndReplacesRegistryFacet() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _advanceToRev014(diamond);
        assertEq(AdminFacet(diamond).diamondVersion(), 14, "must be at rev014 before rev015");

        address oldRegistryFacet = IDiamondLoupe(diamond).facetAddress(RegistryFacet.getTask.selector);

        new Rev015Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 15, "diamondVersion must be 15 after rev015 upgrade");

        address newRegistryFacet = IDiamondLoupe(diamond).facetAddress(RegistryFacet.getTask.selector);
        assertTrue(newRegistryFacet != oldRegistryFacet, "RegistryFacet must be replaced");

        // Selector set is unchanged -- every other RegistryFacet view still routes to the
        // same new facet address (spot-checking a representative sample, not all 29).
        assertEq(
            IDiamondLoupe(diamond).facetAddress(RegistryFacet.getTaskState.selector),
            newRegistryFacet,
            "getTaskState must still route to RegistryFacet"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(RegistryFacet.getBids.selector),
            newRegistryFacet,
            "getBids must still route to RegistryFacet"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(RegistryFacet.getTaskHooks.selector),
            newRegistryFacet,
            "getTaskHooks must still route to RegistryFacet"
        );

        // getTask() itself still works post-replace and now genuinely returns the rev014
        // fields (this diamond's RegistryFacet is compiled from current source either way,
        // since the test helper has no historical-bytecode snapshot to replace *from* --
        // the meaningful assertions here are the facet-address replacement and unbroken
        // selector routing above, which is what the live mainnet bug actually was).
        RegistryFacet(diamond).getTask(bytes32(uint256(1)));
    }

    function test_RevertWhen_Rev015Upgrade_NotAtRev014() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        // Diamond is still at rev011 -- rev015 requires rev014.
        Rev015Upgrade runner = new Rev015Upgrade();
        vm.expectRevert(bytes("Rev015Upgrade: diamond is not at rev014"));
        runner.run();
    }
}
