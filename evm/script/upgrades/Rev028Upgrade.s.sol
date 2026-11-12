// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";
import { FeedbackFacet } from "../../src/facets/FeedbackFacet.sol";
import { HookDispatchFacet } from "../../src/facets/HookDispatchFacet.sol";
import { HooksV2Facet } from "../../src/facets/HooksV2Facet.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev028Upgrade -- Task Hook V2, the settlement record and the dispute check-hook context
/// @dev See packages/contracts/docs/specs/erc8195/rev028-task-hook-v2-and-dispute-context.md.
///      Appends the Task Hook V2 fields and the settlement record to AppStorage (every field reads
///      zero as its correct default, so no initializer runs). Adds HookDispatchFacet (the internal
///      dispatch the other facets reach through a call to the diamond itself) and HooksV2Facet
///      (views, owner settings, per-action data, getTaskSettlement). Replaces every facet whose
///      code changed, which is every facet but Cut and Loupe: Admin, Core, Worker, Auction,
///      Settlement, Evaluator, Project, Acceptance, Rating, Registry (getTaskHooks reads a V2
///      task's attachments) and Feedback (the shared guards and libraries changed). Every existing
///      selector keeps its signature; the seven settlement views move from SettlementFacet to
///      RegistryFacet with their selectors unchanged. Four cuts (cutOne to cutFour), each well under Tempo's
///      per-transaction gas cap; the version is set to 28 only after all four.
/// @dev After the cut every new task is a V2 task; tasks created before it keep V1 dispatch.
///      The dispute fix (resolveDispute shows check hooks a Disputed context) is in the replaced
///      EvaluatorFacet. The payout gate hook must not be deployed on a chain before this cut is
///      live there: verify with facetAddress(hookAcceptV2) and diamondVersion() == 28.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY        -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_<chain> -- Diamond proxy on the target chain
/// @dev Usage:
///      make upgrade 84532 rev028
contract Rev028Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 27;
    uint256 internal constant TARGET_VERSION = 28;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(
            currentVersion == EXPECTED_PRE_VERSION || currentVersion == TARGET_VERSION,
            "Rev028Upgrade: diamond is not at rev027"
        );
        bool[4] memory landed = cutsLanded(diamond);
        bool keepPaused = vm.envOr("FORGE_KEEP_PAUSED", false);

        vm.startBroadcast(ownerKey);
        // Four cuts, each well under Tempo's per-transaction gas cap (one 13-facet cut needs about
        // 29.5M of its 29.9M; the facet CREATEs are separate transactions). Each leaves the diamond
        // consistent: the first adds the dispatch facet the replaced facets call, facets not yet
        // replaced keep running rev027 code, and the version stays 27 until all four are in, so
        // new tasks keep V1 hooks until the bump.
        //
        // Resumable: a cut already on the diamond (see cutsLanded) is skipped and its facets are
        // not deployed again, so after a partial failure a rerun sends only the missing cuts.
        // Paused across the cuts and unpaused after the version bump, also on a rerun that finds
        // the diamond paused by the failed run. FORGE_KEEP_PAUSED=true leaves it paused.
        if (!AdminFacet(diamond).paused()) AdminFacet(diamond).pause();
        if (!landed[0]) IDiamondCut(diamond).diamondCut(cutOne(), address(0), "");
        if (!landed[1]) IDiamondCut(diamond).diamondCut(cutTwo(), address(0), "");
        if (!landed[2]) IDiamondCut(diamond).diamondCut(cutThree(), address(0), "");
        if (!landed[3]) IDiamondCut(diamond).diamondCut(cutFour(), address(0), "");
        if (currentVersion != TARGET_VERSION) AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);
        if (!keepPaused) AdminFacet(diamond).unpause();
        vm.stopBroadcast();

        for (uint256 k; k < 4; ++k) {
            console.log(landed[k] ? "cut already on the diamond, skipped:" : "cut sent:", k + 1);
        }
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        console.log("Rev028 upgrade complete. Diamond:", diamond);
        console.log("HookDispatchFacet:", loupe.facetAddress(FacetSelectors.hookDispatchFacetSelectors()[0]));
        console.log("HooksV2Facet:     ", loupe.facetAddress(FacetSelectors.hooksV2FacetSelectors()[0]));
        console.log("EvaluatorFacet:   ", loupe.facetAddress(FacetSelectors.evalFacetSelectors()[0]));
        console.log("diamondVersion:   ", TARGET_VERSION);
    }

    /// @notice Which of the four cuts are already on `diamond`, each read from a routing change only
    ///         that cut makes. cutFour changes no routing and is Replace only, so it counts as landed
    ///         only once the version is 28; resending it after a failed bump is harmless.
    function cutsLanded(address diamond) public view returns (bool[4] memory landed) {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        // cutOne Adds the dispatch facet.
        landed[0] = loupe.facetAddress(FacetSelectors.hookDispatchFacetSelectors()[0]) != address(0);
        // cutTwo moves settleLapsedReview from SettlementFacet to AcceptanceFacet.
        landed[1] = loupe.facetAddress(FacetSelectors.settlementSelectorsMovedToAcceptanceRev028()[0])
            == loupe.facetAddress(FacetSelectors.acceptFacetSelectors()[0]);
        // cutThree moves the settlement views to RegistryFacet.
        landed[2] = loupe.facetAddress(FacetSelectors.settlementViewSelectorsMovedRev028()[0])
            == loupe.facetAddress(FacetSelectors.registryFacetSelectorsThroughRev026()[0]);
        landed[3] = AdminFacet(diamond).diamondVersion() == TARGET_VERSION;
    }

    /// @notice The dispatch and V2 facets (every Add), then Core and Worker.
    function cutOne() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut(
            address(new HookDispatchFacet()),
            IDiamondCut.FacetCutAction.Add,
            FacetSelectors.hookDispatchFacetSelectorsThroughRev029()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new HooksV2Facet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.hooksV2FacetSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(new CoreFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(new WorkerFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.workerFacetSelectors()
        );
    }

    /// @notice The facets that settle money. The settlement views stay on the rev027 SettlementFacet
    ///         until cutFour moves them to RegistryFacet.
    function cutTwo() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = IDiamondCut.FacetCut(
            address(new AuctionFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.auctionFacetSelectors()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new SettlementFacet()),
            IDiamondCut.FacetCutAction.Replace,
            FacetSelectors.settlementFacetSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(new EvaluatorFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()),
            IDiamondCut.FacetCutAction.Replace,
            FacetSelectors.acceptFacetSelectorsRev028()
        );
        cuts[4] = IDiamondCut.FacetCut(
            address(new RatingFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.ratingFacetSelectors()
        );
    }

    /// @notice ProjectFacet, and RegistryFacet, which takes over the settlement views.
    function cutThree() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](4);
        address projectFacet = address(new ProjectFacet());
        // acceptGrant now takes the terms hash: Replace what rev027 routes, Add the new selector and
        // Remove the old one (a Replace of an unrouted selector reverts, and the old selector would
        // otherwise stay routed to a facet that no longer has it).
        cuts[0] = IDiamondCut.FacetCut(
            projectFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.projectFacetSelectorsRev027Routed()
        );
        cuts[1] = IDiamondCut.FacetCut(
            projectFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.projectSelectorsAddedRev028()
        );
        bytes4[] memory oldAcceptGrant = new bytes4[](1);
        oldAcceptGrant[0] = FacetSelectors.acceptGrantSelectorRev027();
        cuts[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, oldAcceptGrant);
        cuts[3] = IDiamondCut.FacetCut(
            address(new RegistryFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.registryFacetSelectors()
        );
    }

    /// @notice AdminFacet and FeedbackFacet. Replace only, so resending it is harmless.
    function cutFour() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(
            address(new AdminFacet()),
            IDiamondCut.FacetCutAction.Replace,
            FacetSelectors.adminFacetSelectorsThroughRev029()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new FeedbackFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.feedbackFacetSelectors()
        );
    }
}
