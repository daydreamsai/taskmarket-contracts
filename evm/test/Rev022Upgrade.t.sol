// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { RatingFacet } from "../src/facets/RatingFacet.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev022Upgrade } from "../script/upgrades/Rev022Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev022UpgradeTest
/// @dev Rev022 replaces RatingFacet without changing its selectors or storage layout. The
///      checks prove that every rating selector reaches the new bytecode and only rev021
///      diamonds can take this step.
contract Rev022UpgradeTest is Test, DiamondTestHelper {
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
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_8453", vm.toString(diamond));
    }

    function test_Rev022Upgrade_BumpsVersionAndReplacesRatingFacet() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 21);
        _setUpgradeEnv(diamond);

        address oldRatingFacet = IDiamondLoupe(diamond).facetAddress(RatingFacet.rateTask.selector);

        new Rev022Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 22, "diamondVersion must reach rev022");

        address newRatingFacet = IDiamondLoupe(diamond).facetAddress(RatingFacet.rateTask.selector);
        assertTrue(newRatingFacet != oldRatingFacet, "RatingFacet must be replaced");

        bytes4[] memory selectors = FacetSelectors.ratingFacetSelectors();
        for (uint256 i; i < selectors.length; i++) {
            assertEq(
                IDiamondLoupe(diamond).facetAddress(selectors[i]),
                newRatingFacet,
                "every RatingFacet selector must route to the replaced facet"
            );
        }
    }

    function test_RevertWhen_Rev022Upgrade_NotAtRev021() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 20);
        _setUpgradeEnv(diamond);

        Rev022Upgrade runner = new Rev022Upgrade();
        vm.expectRevert(bytes("Rev022Upgrade: diamond is not at rev021"));
        runner.run();
    }
}
