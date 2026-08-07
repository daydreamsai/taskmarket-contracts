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
///      A fresh test diamond is built from FacetSelectors, which is the *current* steady state,
///      so it already routes rev018's new selector -- the reverse of what rev018 expects to find.
///      Rather than skip the step, this test reconstructs the pre-rev018 routing directly by
///      removing the new selector. Routing is the entire thing the cut manipulates, so a
///      reconstruction at that level is a faithful precondition even though no historical
///      CoreFacet bytecode survives in this repo to deploy.
contract Rev018UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    /// @dev Brings a fresh (rev011 baseline) diamond to rev018's precondition: version 17, with
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
        // Rev016 (escrow liability) and rev017 (evaluator award recipients, self-assignment
        // guards, minimum appeal window) are separate changes that are not on this branch, so
        // there are no step scripts here to run. Their cuts do not touch createTask's routing,
        // which is all rev018's cut depends on, so advancing the counter reproduces the
        // precondition faithfully.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(17);

        // Reconstruct pre-rev018 routing: only the legacy createTask selector exists.
        bytes4[] memory newSel = new bytes4[](1);
        newSel[0] = FacetSelectors.CREATE_TASK;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, newSel);
        vm.prank(owner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function test_Rev018Upgrade_AddsCreateTaskOverloadAndKeepsLegacyRouted() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));
        _atRev017WithOnlyLegacyCreateTask(diamond);

        assertEq(AdminFacet(diamond).diamondVersion(), 17, "must be at rev017 before rev018");
        assertEq(
            IDiamondLoupe(diamond).facetAddress(FacetSelectors.CREATE_TASK),
            address(0),
            "new selector must be absent pre-upgrade"
        );
        address oldCoreFacet = IDiamondLoupe(diamond).facetAddress(FacetSelectors.LEGACY_CREATE_TASK);
        assertNotEq(oldCoreFacet, address(0), "legacy selector routed pre-upgrade");
        address oldEvalFacet = IDiamondLoupe(diamond).facetAddress(EvaluatorFacet.assignEvaluator.selector);

        new Rev018Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 18, "diamondVersion must be 18 after rev018 upgrade");

        address newCoreFacet = IDiamondLoupe(diamond).facetAddress(FacetSelectors.CREATE_TASK);
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

    /// @dev Routing tables are not behaviour. Both selectors must actually execute after the cut,
    ///      which is what a caller mid-migration experiences.
    function test_Rev018Upgrade_BothSelectorsExecuteAfterTheCut() public {
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));
        _atRev017WithOnlyLegacyCreateTask(diamond);
        new Rev018Upgrade().run();

        // Neither call is relayed by a trusted forwarder, so both must fail the very first guard
        // in the shared creation body -- proving the call reached CoreFacet's code rather than
        // the diamond's "function does not exist" fallback, which reverts with empty data.
        (bool okLegacy, bytes memory legacyErr) = diamond.call(_legacyCreateTaskCalldata());
        assertFalse(okLegacy, "legacy createTask reverts without a trusted forwarder");
        assertEq(bytes4(legacyErr), ITMPCore.NotTrustedForwarder.selector, "legacy selector reached CoreFacet");

        (bool okNew, bytes memory newErr) = diamond.call(_createTaskCalldata());
        assertFalse(okNew, "createTask reverts without a trusted forwarder");
        assertEq(bytes4(newErr), ITMPCore.NotTrustedForwarder.selector, "new selector reached CoreFacet");
    }

    function _legacyCreateTaskCalldata() private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            FacetSelectors.LEGACY_CREATE_TASK,
            uint256(1),
            uint256(1 days),
            bytes4(0),
            uint256(0),
            uint256(0),
            bytes4(0),
            ITMPCore.StakeConfig({ required: false, bps: 0 }),
            ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
            ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
        );
    }

    function _createTaskCalldata() private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            FacetSelectors.CREATE_TASK,
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
        address diamond = address(deployDiamond(owner, usdc, feeRecipient, feeBps));

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        // Diamond is still at rev011 -- rev018 requires rev017.
        Rev018Upgrade runner = new Rev018Upgrade();
        vm.expectRevert(bytes("Rev018Upgrade: diamond is not at rev017"));
        runner.run();
    }
}
