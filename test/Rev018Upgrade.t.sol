// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { Rev013Upgrade } from "../script/upgrades/Rev013Upgrade.s.sol";
import { Rev015Upgrade } from "../script/upgrades/Rev015Upgrade.s.sol";
import { Rev018Upgrade } from "../script/upgrades/Rev018Upgrade.s.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title Rev018UpgradeTest
/// @dev Rev018 adds a createTask overload carrying evaluator terms, keeps the pre-rev018
///      nine-parameter selector routed to the same facet, and replaces EvaluatorFacet's bytecode
///      without changing any of its selectors. This exercises all three.
///
///      A fresh test diamond is built from FacetSelectors, which is the *current* steady state --
///      post-rev019, so it routes rev018's new selector and not the legacy one, the reverse of
///      what rev018 expects to find on both counts. Rather than skip the step, this test
///      reconstructs the pre-rev018 routing directly. Routing is the entire thing the cut
///      manipulates, so a reconstruction at that level is a faithful precondition even though no
///      historical CoreFacet bytecode survives in this repo to deploy.
contract Rev018UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    /// @dev Brings a diamond placed at rev011 to rev018's precondition: version 17, with
    ///      the legacy createTask selector routed and the new one absent.
    function _atRev017WithOnlyLegacyCreateTask(address diamond) internal {
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        new Rev012Upgrade().run();
        new Rev013Upgrade().run();
        // Rev014Upgrade cannot run here for the reason Rev015UpgradeTest documents: it Removes a
        // pre-rev014 createTask selector that no fresh test diamond has ever routed. The code is
        // already equivalent to rev014, so only the counter needs to catch up.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(14);
        new Rev015Upgrade().run();
        // Rev016 (escrow liability) is a pure Replace with no selector change, and rev017's own
        // Adds are already present on a diamond built from current FacetSelectors.sol, so this
        // diamond is code-equivalent to post-rev017 and only the counter needs to catch up.
        // Rev017UpgradeTest is what exercises those two steps' cuts; rev018's cut depends only on
        // createTask's routing, reconstructed below. Same reasoning as rev014 above.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(17);

        // Reconstruct pre-rev018 routing: only the legacy createTask selector exists. Since
        // rev019 removed the shim, a fresh diamond routes neither the legacy selector (it is no
        // longer in coreFacetSelectors()) nor, once this Remove lands, the new one -- so the
        // legacy selector has to be Added back as well as the new one Removed. It is pointed at
        // the CoreFacet the diamond already uses: no bytecode in this tree serves that signature
        // any more, and routing is the entire thing rev018's cut manipulates.
        address coreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.claimTask.selector);

        bytes4[] memory newSel = new bytes4[](1);
        newSel[0] = CoreFacet.createTask.selector;
        bytes4[] memory legacySel = new bytes4[](1);
        legacySel[0] = FacetSelectors.LEGACY_CREATE_TASK;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, newSel);
        cuts[1] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Add, legacySel);
        vm.prank(owner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function test_Rev018Upgrade_AddsCreateTaskOverloadAndKeepsLegacyRouted() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _atRev017WithOnlyLegacyCreateTask(diamond);

        assertEq(AdminFacet(diamond).diamondVersion(), 17, "must be at rev017 before rev018");
        assertEq(
            IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector),
            address(0),
            "new selector must be absent pre-upgrade"
        );
        address oldCoreFacet = IDiamondLoupe(diamond).facetAddress(FacetSelectors.LEGACY_CREATE_TASK);
        assertNotEq(oldCoreFacet, address(0), "legacy selector routed pre-upgrade");
        address oldEvalFacet = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.assignEvaluator.selector);

        new Rev018Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 18, "diamondVersion must be 18 after rev018 upgrade");

        address newCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);
        assertNotEq(newCoreFacet, address(0), "evaluator-aware createTask must route");
        assertNotEq(newCoreFacet, oldCoreFacet, "CoreFacet must be replaced");

        // The whole point of expand-then-contract: a caller still encoding the nine-parameter
        // signature keeps working, and lands on the same freshly deployed facet. An untested shim
        // is a shim that silently stops working.
        assertEq(
            IDiamondLoupe(diamond).facetAddress(FacetSelectors.LEGACY_CREATE_TASK),
            newCoreFacet,
            "legacy createTask must still route, to the new CoreFacet"
        );

        assertEq(
            IDiamondLoupe(diamond).facetAddress(CoreFacet.claimTask.selector),
            newCoreFacet,
            "unchanged CoreFacet selectors must route to the same new facet"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(CoreFacet.rejectSubmission.selector),
            newCoreFacet,
            "rejectSubmission must route to the new facet"
        );

        // EvaluatorFacet: same selectors, new implementation.
        address newEvalFacet = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.assignEvaluator.selector);
        assertNotEq(newEvalFacet, oldEvalFacet, "EvaluatorFacet must be replaced");
        assertEq(
            IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.evaluate.selector),
            newEvalFacet,
            "evaluate must route to the new EvaluatorFacet"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.evaluatorTimeout.selector),
            newEvalFacet,
            "evaluatorTimeout must route to the new EvaluatorFacet"
        );
    }

    /// @dev Routing tables are not behaviour. The selector rev018 adds must actually execute
    ///      after the cut, not merely appear in the loupe.
    ///
    ///      Rev018's own branch asserted the same of the legacy selector, since a caller
    ///      mid-migration depends on it. That half cannot survive rev019: no bytecode in this
    ///      tree serves the nine-parameter signature any more, so the fixture can restore the
    ///      routing entry but not the code behind it, and a call would reach a CoreFacet with no
    ///      such function. This is the same limitation Rev014UpgradeTest and Rev015UpgradeTest
    ///      document for their own superseded signatures. Deleted rather than weakened into an
    ///      assertion that would pass without proving anything.
    function test_Rev018Upgrade_NewSelectorExecutesAfterTheCut() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _atRev017WithOnlyLegacyCreateTask(diamond);
        new Rev018Upgrade().run();

        // The call is not relayed by a trusted forwarder, so it must fail the very first guard in
        // the shared creation body -- proving it reached CoreFacet's code rather than the
        // diamond's "function does not exist" fallback, which reverts with a plain string.
        (bool okNew, bytes memory newErr) = diamond.call(_createTaskCalldata());
        assertFalse(okNew, "createTask reverts without a trusted forwarder");
        assertEq(bytes4(newErr), ITMPCore.NotTrustedForwarder.selector, "new selector reached CoreFacet");
    }

    function _createTaskCalldata() private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CoreFacet.createTask.selector,
            ITMPCore.TaskConfig({
                reward: 1,
                duration: 1 days,
                mode: bytes4(0),
                pitchDeadline: 0,
                bidDeadline: 0,
                auctionSubtype: bytes4(0)
            }),
            ITMPCore.StakeConfig({ required: false, bps: 0 }),
            ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
            ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
            ITMPCore.TaskEvaluatorConfig({
                evaluator: address(0),
                evaluatorStake: 0,
                evaluatorFeeBps: 0,
                evaluationWindow: 0,
                appealWindow: 0,
                disputeResolver: address(0)
            })
        );
    }

    function test_RevertWhen_Rev018Upgrade_NotAtRev017() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        // Diamond is still at rev011 -- rev018 requires rev017.
        Rev018Upgrade runner = new Rev018Upgrade();
        vm.expectRevert(bytes("Rev018Upgrade: diamond is not at rev017"));
        runner.run();
    }
}
