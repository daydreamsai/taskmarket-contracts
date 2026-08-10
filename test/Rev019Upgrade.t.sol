// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { Rev013Upgrade } from "../script/upgrades/Rev013Upgrade.s.sol";
import { Rev015Upgrade } from "../script/upgrades/Rev015Upgrade.s.sol";
import { Rev019Upgrade } from "../script/upgrades/Rev019Upgrade.s.sol";
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @title Rev019UpgradeTest
/// @dev Rev019 is the contract half of rev018's expand-then-contract: it removes the pre-rev018
///      nine-parameter `createTask` selector and the shim behind it. The assertion this test
///      exists for is that the legacy selector stops routing -- everything else here is context
///      for that one fact, and it is the easiest thing in a removal revision to leave untested,
///      because a cut that quietly drops its Remove still passes every "the new thing works"
///      assertion.
///
///      A fresh test diamond is built from FacetSelectors, the current (post-rev019) steady
///      state, so it does not route the legacy selector at all -- the reverse of what rev019
///      expects to find. The precondition is reconstructed by Adding it back, pointed at the
///      CoreFacet the diamond already uses. Routing is the entire thing this cut manipulates, so
///      a reconstruction at that level is faithful even though no historical CoreFacet bytecode
///      containing the shim survives in this repo.
contract Rev019UpgradeTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    address internal owner;
    address internal usdc = address(0xACDC);
    address internal feeRecipient = address(0xFEE0);
    uint16 internal feeBps = 500;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    /// @dev Brings a diamond placed at rev011 to rev019's precondition: version 18, with
    ///      both createTask selectors routed.
    function _atRev018WithBothCreateTaskSelectors(address diamond) internal {
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
        // Rev016 (escrow liability), rev017 (evaluator award recipients) and rev018 (evaluator
        // config on createTask) are separate changes with no step scripts on this branch, and a
        // diamond built from current FacetSelectors is already code-equivalent to all three. Only
        // rev018's routing differs, and that is reconstructed explicitly below.
        vm.prank(owner);
        AdminFacet(diamond).setDiamondVersion(18);

        // Reconstruct rev018 routing: the legacy selector routed alongside the new one, both on
        // the same CoreFacet.
        address coreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);
        bytes4[] memory legacySel = new bytes4[](1);
        legacySel[0] = FacetSelectors.LEGACY_CREATE_TASK;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Add, legacySel);
        vm.prank(owner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    function test_Rev019Upgrade_RemovesLegacySelectorAndReplacesCoreFacet() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _atRev018WithBothCreateTaskSelectors(diamond);

        assertEq(AdminFacet(diamond).diamondVersion(), 18, "must be at rev018 before rev019");
        address oldCoreFacet = IDiamondLoupe(diamond).facetAddress(FacetSelectors.LEGACY_CREATE_TASK);
        assertNotEq(oldCoreFacet, address(0), "legacy selector routed pre-upgrade");

        new Rev019Upgrade().run();

        assertEq(AdminFacet(diamond).diamondVersion(), 19, "diamondVersion must be 19 after rev019 upgrade");

        // The point of the revision.
        assertEq(
            IDiamondLoupe(diamond).facetAddress(FacetSelectors.LEGACY_CREATE_TASK),
            address(0),
            "legacy createTask must no longer route to any facet"
        );

        // CoreFacet's bytecode changed with the shim's deletion, so the diamond must be pointed
        // at a new deployment. Removing the route while leaving the old facet in place would
        // recover none of the bytecode the revision exists to recover.
        address newCoreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);
        assertNotEq(newCoreFacet, address(0), "evaluator-aware createTask must still route");
        assertNotEq(newCoreFacet, oldCoreFacet, "CoreFacet must be replaced");

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
        assertEq(
            IDiamondLoupe(diamond).facetAddress(CoreFacet.refundExpired.selector),
            newCoreFacet,
            "refundExpired must route to the new facet"
        );
    }

    /// @dev An empty loupe entry and an actually-unreachable function are not the same claim. A
    ///      caller that never migrated must be rejected by the diamond's fallback -- the specific,
    ///      diagnosable failure -- rather than reaching a facet at all.
    /// @dev The expected payload is `Error("Diamond: function not found")`, the require in
    ///      Diamond.fallback, NOT `LibDiamond.FunctionNotFound`. That custom error is raised by
    ///      `_removeFunction` when a *cut* tries to remove a selector that is not routed; it never
    ///      appears on the call path. Asserting the wrong one of the two still fails when the
    ///      Remove is dropped, but for the wrong reason, and would pass against a diamond that had
    ///      never routed the selector in the first place.
    function test_Rev019Upgrade_LegacySelectorRevertsWhenUnrouted() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _atRev018WithBothCreateTaskSelectors(diamond);
        new Rev019Upgrade().run();

        // Asserted on the returned data rather than with vm.expectRevert, so the exact revert
        // payload is checked, not just that something threw.
        (bool ok, bytes memory err) = diamond.call(_legacyCreateTaskCalldata());
        assertFalse(ok, "legacy createTask must revert");
        assertEq(
            err,
            abi.encodeWithSignature("Error(string)", "Diamond: function not found"),
            "legacy createTask must be rejected by the diamond fallback, not by a facet"
        );
    }

    /// @dev The other half of the same fact: the surviving selector still executes, so the cut
    ///      removed one route rather than breaking task creation outright.
    function test_Rev019Upgrade_NewSelectorStillExecutes() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);
        _atRev018WithBothCreateTaskSelectors(diamond);
        new Rev019Upgrade().run();

        // Not relayed by a trusted forwarder, so it must fail the first guard in the creation
        // body -- proving it reached CoreFacet rather than the fallback.
        (bool ok, bytes memory err) = diamond.call(_createTaskCalldata());
        assertFalse(ok, "createTask reverts without a trusted forwarder");
        assertEq(bytes4(err), ITMPCore.NotTrustedForwarder.selector, "new selector reached CoreFacet");
    }

    function test_RevertWhen_Rev019Upgrade_NotAtRev018() public {
        address diamond = deployDiamondAtVersion(owner, usdc, feeRecipient, feeBps, 11);

        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        // Diamond is still at rev011 -- rev019 requires rev018.
        Rev019Upgrade runner = new Rev019Upgrade();
        vm.expectRevert(bytes("Rev019Upgrade: diamond is not at rev018"));
        runner.run();
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
            CoreFacet.createTask.selector,
            taskConfig(1, 1 days, bytes4(0)),
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
}
