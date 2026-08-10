// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { AuctionFacet } from "../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { Rev013Upgrade } from "../script/upgrades/Rev013Upgrade.s.sol";
import { Rev015Upgrade } from "../script/upgrades/Rev015Upgrade.s.sol";
import { Rev017Upgrade } from "../script/upgrades/Rev017Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev017UpgradeTest
/// @dev Deploys a diamond placed at rev011 (the step tests' baseline), advances it through
///      rev012/013/014/015/016 to reach rev017's precondition, applies the rev017 step, and
///      asserts diamondVersion bumps to 17, all four hook-dispatching facets are genuinely
///      replaced, every pre-existing selector still routes, and the one new selector
///      (MIN_APPEAL_WINDOW_SECS) is added and answers.
contract Rev017UpgradeTest is Test, DiamondTestHelper {
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

    /// @dev A fresh test diamond is deployed from FacetSelectors.sol, the single source of truth
    ///      for the *current* (post-rev017) steady state, so it already routes the two new
    ///      AdminFacet selectors. Rev017Upgrade Adds them, and LibDiamond rejects an Add for a
    ///      selector that already routes, so the pre-rev017 on-chain state has to be
    ///      reconstructed by removing them first. This is also what makes the Add path genuinely
    ///      exercised rather than trivially satisfied.
    function _removeNewSelectors(address diamond) internal {
        bytes4[] memory sel = new bytes4[](2);
        sel[0] = AdminFacet.minAppealWindowSecs.selector;
        sel[1] = AdminFacet.setMinAppealWindowSecs.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, sel);
        vm.prank(owner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function _advanceToRev016(address diamond) internal {
        _setUpgradeEnv(diamond);
        new Rev012Upgrade().run();
        new Rev013Upgrade().run();
        // Rev014Upgrade cannot run here (it Removes a pre-rev014 createTask selector this repo
        // no longer has bytecode for -- see Rev015UpgradeTest for the full explanation), so the
        // version counter is nudged forward instead; the diamond's code is already equivalent.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(14);
        new Rev015Upgrade().run();
        // Rev016 (escrow-liability fixes in CoreFacet) is a pure Replace with no selector change,
        // so a diamond built from current FacetSelectors.sol is already code-equivalent to
        // post-rev016; only the counter needs to catch up. Same reasoning as rev014 above.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(16);
    }

    function test_Rev017Upgrade_BumpsVersionAndReplacesHookDispatchingFacets() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _advanceToRev016(diamond);
        // Reconstruct the pre-rev017 selector set only after the intervening steps have run --
        // rev012/rev013 Replace whole facet selector sets, and LibDiamond rejects a Replace of a
        // selector the diamond does not currently route.
        _removeNewSelectors(diamond);
        assertEq(AdminFacet(diamond).diamondVersion(), 16, "must be at rev016 before rev017");

        address oldAdmin = IDiamondLoupe(diamond).facetAddress(AdminFacet.pause.selector);
        address oldCore = IDiamondLoupe(diamond).facetAddress(CoreFacet.refundExpired.selector);
        address oldAuction = IDiamondLoupe(diamond).facetAddress(AuctionFacet.submitBid.selector);
        address oldAccept = IDiamondLoupe(diamond).facetAddress(AcceptanceFacet.acceptSubmission.selector);
        address oldEval = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.evaluate.selector);

        new Rev017Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 17, "diamondVersion must be 17 after rev017 upgrade");

        // All four facets that inline LibTaskMarket's patched hook dispatch must be new
        // implementations -- replacing only EvaluatorFacet would leave #317's refundExpired
        // fund-freeze path live on CoreFacet's old bytecode.
        address newAdmin = IDiamondLoupe(diamond).facetAddress(AdminFacet.pause.selector);
        address newCore = IDiamondLoupe(diamond).facetAddress(CoreFacet.refundExpired.selector);
        address newAuction = IDiamondLoupe(diamond).facetAddress(AuctionFacet.submitBid.selector);
        address newAccept = IDiamondLoupe(diamond).facetAddress(AcceptanceFacet.acceptSubmission.selector);
        address newEval = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.evaluate.selector);
        assertTrue(newCore != oldCore, "CoreFacet must be replaced");
        assertTrue(newAuction != oldAuction, "AuctionFacet must be replaced");
        assertTrue(newAccept != oldAccept, "AcceptanceFacet must be replaced");
        assertTrue(newEval != oldEval, "EvaluatorFacet must be replaced");
        assertTrue(newAdmin != oldAdmin, "AdminFacet must be replaced");

        // Every pre-existing selector of each replaced facet still routes, to the new address.
        // Rev018 added a second createTask overload and rev019 removed the legacy one again, so
        // `CoreFacet.createTask` names the single surviving entry point -- which is what the
        // CoreFacet this path deploys actually serves.
        _assertRoutes(diamond, CoreFacet.createTask.selector, newCore, "createTask");
        _assertRoutes(diamond, CoreFacet.claimTask.selector, newCore, "claimTask");
        _assertRoutes(diamond, CoreFacet.submitWork.selector, newCore, "submitWork");
        _assertRoutes(diamond, CoreFacet.cancelTask.selector, newCore, "cancelTask");
        _assertRoutes(diamond, CoreFacet.forfeitAndReopen.selector, newCore, "forfeitAndReopen");
        _assertRoutes(diamond, AuctionFacet.selectLowestBidder.selector, newAuction, "selectLowestBidder");
        _assertRoutes(diamond, AuctionFacet.acceptAuction.selector, newAuction, "acceptAuction");
        _assertRoutes(diamond, AcceptanceFacet.acceptSubmissions.selector, newAccept, "acceptSubmissions");
        _assertRoutes(diamond, EvaluatorFacet.assignEvaluator.selector, newEval, "assignEvaluator");
        _assertRoutes(diamond, EvaluatorFacet.appeal.selector, newEval, "appeal");
        _assertRoutes(diamond, EvaluatorFacet.finalizeVerdict.selector, newEval, "finalizeVerdict");
        _assertRoutes(diamond, EvaluatorFacet.resolveDispute.selector, newEval, "resolveDispute");
        _assertRoutes(diamond, EvaluatorFacet.evaluatorTimeout.selector, newEval, "evaluatorTimeout");

        _assertRoutes(diamond, AdminFacet.diamondVersion.selector, newAdmin, "diamondVersion");
        _assertRoutes(diamond, AdminFacet.setDefaultHooks.selector, newAdmin, "setDefaultHooks");

        // Both added selectors route, and the getter answers with the lazy default rather than
        // the raw zero actually sitting in the freshly-appended storage slot -- the guard must be
        // live on upgrade, not on first setter call.
        _assertRoutes(diamond, AdminFacet.minAppealWindowSecs.selector, newAdmin, "minAppealWindowSecs");
        _assertRoutes(diamond, AdminFacet.setMinAppealWindowSecs.selector, newAdmin, "setMinAppealWindowSecs");
        assertEq(AdminFacet(diamond).minAppealWindowSecs(), 300, "appeal-window floor must default to 300 on upgrade");
    }

    function test_RevertWhen_Rev017Upgrade_NotAtRev016() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _setUpgradeEnv(diamond);

        // Diamond is still at rev011 -- rev017 requires rev016.
        Rev017Upgrade runner = new Rev017Upgrade();
        vm.expectRevert(bytes("Rev017Upgrade: diamond is not at rev016"));
        runner.run();
    }

    function _assertRoutes(address diamond, bytes4 selector, address expected, string memory label) private view {
        assertEq(IDiamondLoupe(diamond).facetAddress(selector), expected, label);
    }
}
