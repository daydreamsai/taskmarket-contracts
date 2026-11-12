// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";

/// @title FacetSelectorsTest
/// @dev Every selector list FacetSelectors builds is a cut payload: a zero selector or a repeat
///      inside one list is a bad Add on a fresh deploy. Lists that are bound for different facets
///      may share a selector (a move), so only each list on its own is checked.
///      A list added to FacetSelectors needs a line in `testNoSelectorListHasZeroOrDuplicate`.
contract FacetSelectorsTest is Test {
    function testNoSelectorListHasZeroOrDuplicate() public pure {
        _check("selectorsRemovedRev026", FacetSelectors.selectorsRemovedRev026());
        _check("selectorsRemovedRev030", FacetSelectors.selectorsRemovedRev030());
        _check("adminSelectorsRemovedRev030", FacetSelectors.adminSelectorsRemovedRev030());
        _check("adminFacetSelectorsKeptRev030", FacetSelectors.adminFacetSelectorsKeptRev030());
        _check("hookDispatchFacetSelectorsThroughRev029", FacetSelectors.hookDispatchFacetSelectorsThroughRev029());
        _check("cutFacetSelectors", FacetSelectors.cutFacetSelectors());
        _check("loupeFacetSelectors", FacetSelectors.loupeFacetSelectors());
        _check("adminFacetSelectors", FacetSelectors.adminFacetSelectors());
        _check("adminFacetSelectorsAddedRev030", FacetSelectors.adminFacetSelectorsAddedRev030());
        _check("adminFacetSelectorsThroughRev029", FacetSelectors.adminFacetSelectorsThroughRev029());
        _check("adminFacetSelectorsAddedRev026", FacetSelectors.adminFacetSelectorsAddedRev026());
        _check("adminFacetSelectorsThroughRev025", FacetSelectors.adminFacetSelectorsThroughRev025());
        _check("adminFacetSelectorsThroughRev024", FacetSelectors.adminFacetSelectorsThroughRev024());
        _check("adminFacetSelectorsThroughRev023", FacetSelectors.adminFacetSelectorsThroughRev023());
        _check("coreFacetSelectors", FacetSelectors.coreFacetSelectors());
        _check("coreFacetSelectorsKeptRev027", FacetSelectors.coreFacetSelectorsKeptRev027());
        _check("coreFacetSelectorsAddedRev027", FacetSelectors.coreFacetSelectorsAddedRev027());
        _check("workerFacetSelectors", FacetSelectors.workerFacetSelectors());
        _check("workerFacetSelectorsFromCore", FacetSelectors.workerFacetSelectorsFromCore());
        _check("selectorsAddedRev027", FacetSelectors.selectorsAddedRev027());
        _check("selectorsAddedRev027OnRev028", FacetSelectors.selectorsAddedRev027OnRev028());
        _check("workerFacetSelectorsAddedRev027", FacetSelectors.workerFacetSelectorsAddedRev027());
        _check("coreFacetSelectorsThroughRev026", FacetSelectors.coreFacetSelectorsThroughRev026());
        _check("coreFacetSelectorsThroughRev024", FacetSelectors.coreFacetSelectorsThroughRev024());
        _check("auctionFacetSelectors", FacetSelectors.auctionFacetSelectors());
        _check("acceptFacetSelectors", FacetSelectors.acceptFacetSelectors());
        _check("evalFacetSelectors", FacetSelectors.evalFacetSelectors());
        _check("ratingFacetSelectors", FacetSelectors.ratingFacetSelectors());
        _check("registryFacetSelectors", FacetSelectors.registryFacetSelectors());
        _check("registryFacetSelectorsThroughRev026", FacetSelectors.registryFacetSelectorsThroughRev026());
        _check("registryFacetSelectorsAddedRev026", FacetSelectors.registryFacetSelectorsAddedRev026());
        _check("registryFacetSelectorsThroughRev025", FacetSelectors.registryFacetSelectorsThroughRev025());
        _check("settlementFacetSelectors", FacetSelectors.settlementFacetSelectors());
        _check(
            "settlementFacetSelectorsThroughRev026ServedNow",
            FacetSelectors.settlementFacetSelectorsThroughRev026ServedNow()
        );
        _check(
            "settlementFacetSelectorsAddedRev027ServedNow",
            FacetSelectors.settlementFacetSelectorsAddedRev027ServedNow()
        );
        _check("rev027SelectorsServedByRegistryNow", FacetSelectors.rev027SelectorsServedByRegistryNow());
        _check(
            "settlementSelectorsMovedToAcceptanceRev028", FacetSelectors.settlementSelectorsMovedToAcceptanceRev028()
        );
        _check("acceptFacetSelectorsRev028", FacetSelectors.acceptFacetSelectorsRev028());
        _check("settlementViewSelectorsMovedRev028", FacetSelectors.settlementViewSelectorsMovedRev028());
        _check("settlementFacetSelectorsAddedRev027", FacetSelectors.settlementFacetSelectorsAddedRev027());
        _check("settlementFacetSelectorsThroughRev026", FacetSelectors.settlementFacetSelectorsThroughRev026());
        _check("settlementFacetSelectorsAdded", FacetSelectors.settlementFacetSelectorsAdded());
        _check("settlementFacetSelectorsFromCore", FacetSelectors.settlementFacetSelectorsFromCore());
        _check("feedbackFacetSelectors", FacetSelectors.feedbackFacetSelectors());
        _check("feedbackFacetSelectorsAddedRev027", FacetSelectors.feedbackFacetSelectorsAddedRev027());
        _check("feedbackFacetSelectorsThroughRev026", FacetSelectors.feedbackFacetSelectorsThroughRev026());
        _check("projectFacetSelectors", FacetSelectors.projectFacetSelectors());
        _check("selectorsAddedRev028", FacetSelectors.selectorsAddedRev028());
        _check("projectSelectorsAddedRev028", FacetSelectors.projectSelectorsAddedRev028());
        _check("projectFacetSelectorsRev027", FacetSelectors.projectFacetSelectorsRev027());
        _check("projectFacetSelectorsRev027Routed", FacetSelectors.projectFacetSelectorsRev027Routed());
        _check("projectSelectorsAddedRev029", FacetSelectors.projectSelectorsAddedRev029());
        _check("projectOwnerSelectorsRev029", FacetSelectors.projectOwnerSelectorsRev029());
        _check("selectorsAddedRev029", FacetSelectors.selectorsAddedRev029());
        _check("selectorsAddedRev030", FacetSelectors.selectorsAddedRev030());
        _check("projectFacetSelectorsRev028Routed", FacetSelectors.projectFacetSelectorsRev028Routed());
        _check("hookDispatchFacetSelectors", FacetSelectors.hookDispatchFacetSelectors());
        _check("hooksV2FacetSelectors", FacetSelectors.hooksV2FacetSelectors());
    }

    /// @dev The rev030 Removed selectors are written out (no facet serves them any more), so a typo in
    ///      the signature would Remove nothing. These are the ids the rev029 facets routed.
    function testRetiredV1SelectorsMatchWhatRev029Routed() public pure {
        assertEq(FacetSelectors.SET_DEFAULT_HOOKS, bytes4(0x435f2c47), "setDefaultHooks(address[])");
        assertEq(FacetSelectors.GET_DEFAULT_HOOKS, bytes4(0xe98650f3), "getDefaultHooks()");
        assertEq(FacetSelectors.HOOK_CHECK_COMPLETE_V1, bytes4(0x9685ec9c), "hookCheckCompleteV1");
    }

    function _check(string memory name, bytes4[] memory list) internal pure {
        for (uint256 i = 0; i < list.length; i++) {
            require(list[i] != bytes4(0), string.concat(name, ": zero selector"));
            for (uint256 j = i + 1; j < list.length; j++) {
                require(list[i] != list[j], string.concat(name, ": duplicate selector"));
            }
        }
    }
}
