// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { FeedbackFacet } from "../../src/facets/FeedbackFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { FundingPoolFacet } from "../../src/facets/FundingPoolFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev027Upgrade -- a Claim task with a reserved worker, and projects
/// @dev Appends reservedWorkers and workerAgentIds to AppStorage, and TaskTerms gains
///      acceptWindowSecs in the slot's four spare bytes (terms version 2). Replaces CoreFacet and
///      Adds the version 2 createTask and createTask with a reserved worker; the rev025 selector
///      stays routed to the version 1 overload. Adds WorkerFacet with claimTask taking the
///      worker's agent ID. Replaces SettlementFacet and Adds
///      declineReservation, getReservation and requesterTimeout (the permissionless refund of a
///      Bounty or Benchmark whose decision window lapsed with live submissions). Replaces
///      FeedbackFacet and Adds workerAgentOf; its views also report the default for the new
///      "requester_timeout" event key. Replaces EvaluatorFacet: evaluatorTimeout no longer
///      requires the forwarder, so anyone can call it directly.
/// @dev Projects: appends the project and funding pool fields to AppStorage and Adds ProjectFacet
///      and FundingPoolFacet (a project's budget is a funding pool backers fund and claim from). Replaces
///      AcceptanceFacet and RatingFacet as well: with CoreFacet, EvaluatorFacet, SettlementFacet
///      and WorkerFacet above, they pay money owed to a project task's requester back into its
///      project and follow an operator's grant terms in their requester checks.
///      Every other facet is unchanged.
/// @dev CoreFacet is also split: claimTask (both overloads), selectWorker, submitPitch, submitProof
///      and submitWork move to a new WorkerFacet with their selectors unchanged, and task creation
///      moves into LibTaskCreation, so CoreFacet keeps room under the contract size limit.
/// @dev One diamondCut transaction: nine facets and 73 selectors, which must stay under
///      the Tempo per-transaction gas cap that made rev026 split its cut (simulate first).
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_84532  -- Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_8453  -- Diamond proxy on Base Mainnet (chain 8453)
///      FORGE_DIAMOND_ADDRESS_42431 -- Diamond proxy on Tempo Moderato (chain 42431)
///      FORGE_DIAMOND_ADDRESS_4217 -- Diamond proxy on Tempo mainnet (chain 4217)
/// @dev Usage:
///      make upgrade 84532 rev027
///      make upgrade 8453 rev027
contract Rev027Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 26;
    uint256 internal constant TARGET_VERSION = 27;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev027Upgrade: diamond is not at rev026");

        vm.startBroadcast(ownerKey);
        IDiamondCut(diamond).diamondCut(_cut(), address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);
        vm.stopBroadcast();

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        console.log("Rev027 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:      ", loupe.facetAddress(FacetSelectors.coreFacetSelectors()[0]));
        console.log("WorkerFacet:    ", loupe.facetAddress(FacetSelectors.workerFacetSelectors()[0]));
        console.log("SettlementFacet:", loupe.facetAddress(FacetSelectors.settlementFacetSelectors()[0]));
        console.log("FeedbackFacet:  ", loupe.facetAddress(FacetSelectors.feedbackFacetSelectors()[0]));
        console.log("EvaluatorFacet: ", loupe.facetAddress(FacetSelectors.evalFacetSelectors()[0]));
        console.log("ProjectFacet:   ", loupe.facetAddress(FacetSelectors.projectFacetSelectors()[0]));
        console.log("FundingPoolFacet:", loupe.facetAddress(FacetSelectors.fundingPoolFacetSelectors()[0]));
        console.log("AcceptanceFacet:", loupe.facetAddress(FacetSelectors.acceptFacetSelectors()[0]));
        console.log("RatingFacet:    ", loupe.facetAddress(FacetSelectors.ratingFacetSelectors()[0]));
        console.log("diamondVersion: ", TARGET_VERSION);
    }

    function _cut() internal returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](13);
        address core = address(new CoreFacet());
        address worker = address(new WorkerFacet());
        address settlement = address(new SettlementFacet());
        address feedback = address(new FeedbackFacet());
        address evaluator = address(new EvaluatorFacet());
        cuts[0] = IDiamondCut.FacetCut(
            core, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectorsKeptRev027()
        );
        cuts[1] =
            IDiamondCut.FacetCut(core, IDiamondCut.FacetCutAction.Add, FacetSelectors.coreFacetSelectorsAddedRev027());
        cuts[2] = IDiamondCut.FacetCut(
            worker, IDiamondCut.FacetCutAction.Replace, FacetSelectors.workerFacetSelectorsFromCore()
        );
        cuts[3] = IDiamondCut.FacetCut(
            worker, IDiamondCut.FacetCutAction.Add, FacetSelectors.workerFacetSelectorsAddedRev027()
        );
        cuts[4] = IDiamondCut.FacetCut(
            settlement, IDiamondCut.FacetCutAction.Replace, FacetSelectors.settlementFacetSelectorsThroughRev026()
        );
        cuts[5] = IDiamondCut.FacetCut(
            settlement, IDiamondCut.FacetCutAction.Add, FacetSelectors.settlementFacetSelectorsAddedRev027()
        );
        cuts[6] = IDiamondCut.FacetCut(
            feedback, IDiamondCut.FacetCutAction.Replace, FacetSelectors.feedbackFacetSelectorsThroughRev026()
        );
        cuts[7] = IDiamondCut.FacetCut(
            feedback, IDiamondCut.FacetCutAction.Add, FacetSelectors.feedbackFacetSelectorsAddedRev027()
        );
        cuts[8] =
            IDiamondCut.FacetCut(evaluator, IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors());
        cuts[9] = IDiamondCut.FacetCut(
            address(new ProjectFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.projectFacetSelectors()
        );
        cuts[10] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.acceptFacetSelectors()
        );
        cuts[11] = IDiamondCut.FacetCut(
            address(new RatingFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.ratingFacetSelectors()
        );
        cuts[12] = IDiamondCut.FacetCut(
            address(new FundingPoolFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.fundingPoolFacetSelectors()
        );
    }
}
