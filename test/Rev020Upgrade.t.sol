// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev020Upgrade } from "../script/upgrades/Rev020Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev020UpgradeTest
/// @dev Rev020 changes no selector. Its cut is a pure Replace of AdminFacet, so the properties
///      under test are that AdminFacet's bytecode is genuinely swapped, that every one of its
///      selectors still routes to the new facet, and that the counter reaches rev020 -- which is
///      the step's actual purpose, keeping an upgraded diamond and a fresh deploy of the same
///      build reporting the same revision.
contract Rev020UpgradeTest is Test, DiamondTestHelper {
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

    function test_Rev020Upgrade_BumpsVersionAndReplacesAdminFacet() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 19);
        _setUpgradeEnv(diamond);

        address oldAdminFacet = IDiamondLoupe(diamond).facetAddress(AdminFacet.pause.selector);

        new Rev020Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 20, "diamondVersion must reach rev020");

        address newAdminFacet = IDiamondLoupe(diamond).facetAddress(AdminFacet.pause.selector);
        assertTrue(newAdminFacet != oldAdminFacet, "AdminFacet must be replaced");

        // Checked exhaustively rather than by sample: the whole risk of a pure Replace is one
        // entry going missing from the list.
        bytes4[] memory selectors = FacetSelectors.adminFacetSelectors();
        for (uint256 i; i < selectors.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(selectors[i]),
                newAdminFacet,
                "every AdminFacet selector must route to the replaced facet"
            );
        }
    }

    function test_RevertWhen_Rev020Upgrade_NotAtRev019() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _setUpgradeEnv(diamond);

        // Diamond is still at rev011 -- rev020 requires rev019.
        Rev020Upgrade runner = new Rev020Upgrade();
        vm.expectRevert(bytes("Rev020Upgrade: diamond is not at rev019"));
        runner.run();
    }
}
