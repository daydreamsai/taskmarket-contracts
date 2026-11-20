// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { Rev031Upgrade } from "../script/upgrades/Rev031Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev031UpgradeTest
/// @dev Rev031 replaces the eleven facets whose code changed, Adds the grantOperator that takes
///      limits and Removes the terms-only one, and Removes the zero selector where a chain routes it.
///      The checks prove each replaced facet's selectors reach new bytecode, the unchanged facets keep
///      their routes, the grantOperator swap and the zero selector, the Tempo split cut, only a rev030
///      diamond takes the step, and a rerun at rev031 sends no cut.
contract Rev031UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;

    address internal owner;
    ITMPDiamond internal market;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
        vm.startPrank(owner);
        MockUSDC usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE0), 500);
        vm.stopPrank();
        // A rev030 diamond routes the terms-only grantOperator.
        routeGrantOperator(address(market), owner, true);
        placeAtVersion(address(market), 30);

        vm.chainId(84532);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_84532", vm.toString(address(market)));
    }

    function _replaced() internal pure returns (bytes4[][] memory sets) {
        sets = new bytes4[][](11);
        sets[0] = FacetSelectors.adminFacetSelectors();
        sets[1] = FacetSelectors.acceptFacetSelectorsRev028();
        sets[2] = FacetSelectors.auctionFacetSelectors();
        sets[3] = FacetSelectors.coreFacetSelectors();
        sets[4] = FacetSelectors.evalFacetSelectors();
        sets[5] = FacetSelectors.hookDispatchFacetSelectors();
        sets[6] = FacetSelectors.hooksV2FacetSelectors();
        sets[7] = FacetSelectors.projectFacetSelectors();
        sets[8] = FacetSelectors.ratingFacetSelectors();
        sets[9] = FacetSelectors.settlementFacetSelectors();
        sets[10] = FacetSelectors.workerFacetSelectors();
    }

    function _unchanged() internal pure returns (bytes4[][] memory sets) {
        sets = new bytes4[][](4);
        sets[0] = FacetSelectors.registryFacetSelectors();
        sets[1] = FacetSelectors.feedbackFacetSelectors();
        sets[2] = FacetSelectors.cutFacetSelectors();
        sets[3] = FacetSelectors.loupeFacetSelectors();
    }

    function _assertRev031(address[] memory replacedBefore, address[] memory unchangedBefore) internal view {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        bytes4[][] memory sets = _replaced();
        for (uint256 i; i < sets.length; ++i) {
            address after_ = loupe.facetAddress(sets[i][0]);
            assertNotEq(after_, replacedBefore[i], "facet replaced");
            for (uint256 j; j < sets[i].length; ++j) {
                assertEq(loupe.facetAddress(sets[i][j]), after_, "every selector on the new facet");
            }
        }
        sets = _unchanged();
        for (uint256 i; i < sets.length; ++i) {
            for (uint256 j; j < sets[i].length; ++j) {
                assertEq(loupe.facetAddress(sets[i][j]), unchangedBefore[i], "unchanged facet keeps its route");
            }
        }
        assertEq(
            loupe.facetAddress(FacetSelectors.grantOperatorSelectorRev030()), address(0), "terms-only grant removed"
        );
        assertEq(loupe.facetAddress(bytes4(0)), address(0), "no zero selector");
        assertEq(AdminFacet(address(market)).diamondVersion(), 31, "diamondVersion 31");
        assertFalse(AdminFacet(address(market)).paused(), "not left paused");
    }

    function _before() internal view returns (address[] memory replaced, address[] memory unchanged) {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        bytes4[][] memory sets = _replaced();
        replaced = new address[](sets.length);
        for (uint256 i; i < sets.length; ++i) {
            replaced[i] = loupe.facetAddress(sets[i][0]);
        }
        sets = _unchanged();
        unchanged = new address[](sets.length);
        for (uint256 i; i < sets.length; ++i) {
            unchanged[i] = loupe.facetAddress(sets[i][0]);
        }
    }

    function test_Upgrade_ReplacesEveryChangedFacetAndSwapsGrantOperator() public {
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(FacetSelectors.projectSelectorsAddedRev031()[0]),
            address(0),
            "a rev030 diamond does not route the grantOperator that takes limits"
        );
        (address[] memory replaced, address[] memory unchanged) = _before();
        new Rev031Upgrade().run();
        _assertRev031(replaced, unchanged);
    }

    function test_Upgrade_RemovesTheZeroSelectorWhereRouted() public {
        IDiamondCut.FacetCut[] memory route = new IDiamondCut.FacetCut[](1);
        route[0] = IDiamondCut.FacetCut(
            IDiamondLoupe(address(market)).facetAddress(AdminFacet.diamondVersion.selector),
            IDiamondCut.FacetCutAction.Add,
            new bytes4[](1)
        );
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(route, address(0), "");
        Rev031Upgrade up = new Rev031Upgrade();
        assertTrue(up.zeroSelectorRouted(address(market)));

        (address[] memory replaced, address[] memory unchanged) = _before();
        up.run();
        _assertRev031(replaced, unchanged);
    }

    function test_CutRemovesTheZeroSelectorOnlyWhenAsked() public {
        Rev031Upgrade up = new Rev031Upgrade();
        assertFalse(up.zeroSelectorRouted(address(market)));
        IDiamondCut.FacetCut[] memory without = up.cut(false);
        IDiamondCut.FacetCut[] memory with_ = up.cut(true);
        assertEq(with_.length, without.length + 1);
        IDiamondCut.FacetCut memory last = with_[with_.length - 1];
        assertEq(uint8(last.action), uint8(IDiamondCut.FacetCutAction.Remove));
        assertEq(last.functionSelectors.length, 1);
        assertEq(last.functionSelectors[0], bytes4(0));
    }

    function test_TempoSplitCutLandsTheSameRouting() public {
        vm.chainId(42431);
        vm.setEnv("FORGE_DIAMOND_ADDRESS_42431", vm.toString(address(market)));
        (address[] memory replaced, address[] memory unchanged) = _before();
        new Rev031Upgrade().run();
        _assertRev031(replaced, unchanged);
    }

    function test_CutIsSplitOnTempoOnly() public {
        Rev031Upgrade up = new Rev031Upgrade();
        assertTrue(up.splitCut(4217));
        assertTrue(up.splitCut(42431));
        assertFalse(up.splitCut(8453));
        assertFalse(up.splitCut(84532));
    }

    function test_EachCutEntryStaysFarUnderTempoCap() public {
        IDiamondCut.FacetCut[] memory all = new Rev031Upgrade().cut(false);
        uint256 worst;
        for (uint256 i = 0; i < all.length; i++) {
            IDiamondCut.FacetCut[] memory one = new IDiamondCut.FacetCut[](1);
            one[0] = all[i];
            uint256 g = gasleft();
            vm.prank(owner);
            IDiamondCut(address(market)).diamondCut(one, address(0), "");
            uint256 used = g - gasleft();
            if (used > worst) worst = used;
        }
        emit log_named_uint("  largest entry gas", worst);
        assertLt(worst, 8_000_000, "one entry must stay well under Tempo's per-transaction cap");
    }

    function test_RerunAtRev031SendsNoCut() public {
        new Rev031Upgrade().run();
        address facet = IDiamondLoupe(address(market)).facetAddress(FacetSelectors.evalFacetSelectors()[0]);
        vm.recordLogs();
        new Rev031Upgrade().run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IDiamondCut.DiamondCut.selector, "no diamondCut sent again");
        }
        assertEq(
            IDiamondLoupe(address(market)).facetAddress(FacetSelectors.evalFacetSelectors()[0]), facet, "same facet"
        );
        assertEq(AdminFacet(address(market)).diamondVersion(), 31);
        assertFalse(AdminFacet(address(market)).paused());
    }

    function test_RevertsUnlessAtRev030() public {
        placeAtVersion(address(market), 29);
        Rev031Upgrade up = new Rev031Upgrade();
        vm.expectRevert("Rev031Upgrade: diamond is not at rev030");
        up.run();
    }
}
