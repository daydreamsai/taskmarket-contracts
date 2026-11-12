// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { DiamondCutFacet } from "../../src/facets/DiamondCutFacet.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { HookDispatchFacet } from "../../src/facets/HookDispatchFacet.sol";
import { HooksV2Facet } from "../../src/facets/HooksV2Facet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { FundingPool } from "../../src/FundingPool.sol";
import { ITMPProject } from "../../src/interfaces/ITMPProject.sol";
import { IFundingPoolManager } from "../../src/interfaces/IFundingPoolManager.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev030Upgrade -- hook roles follow task control, the rev030 security fixes, and the end of V1 hooks
/// @dev See packages/contracts/docs/specs/erc8195/rev030-hook-roles-follow-task-control.md.
///      Replaces every facet whose code changes in rev030 (AcceptanceFacet, AdminFacet, AuctionFacet,
///      CoreFacet, EvaluatorFacet, HookDispatchFacet, HooksV2Facet, ProjectFacet, RatingFacet,
///      RegistryFacet, SettlementFacet, WorkerFacet, and the DiamondCutFacet that executes the cut),
///      Adds the AdminFacet winner-cap setter and view, and Removes the three selectors V1 hook
///      dispatch used (setDefaultHooks and getDefaultHooks on AdminFacet, hookCheckCompleteV1 on
///      HookDispatchFacet). The FundingPool proxy is upgraded to the rev030 implementation first (no
///      new generation while money is outstanding). AppStorage gains one field at its end
///      (maxSubmissionWinners); the V1 hook fields stay, unused. On Tempo the winner cap is set to
///      TEMPO_MAX_SUBMISSION_WINNERS. The version is set to 30 after the cut.
///      The DREAMS reward hook is upgraded separately, after this cut (DeployHooksV2.s.sol:
///      UpgradeRewardHookV2).
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY        -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_<chain> -- Diamond proxy on the target chain
///      FORGE_KEEP_PAUSED            -- optional; true leaves the diamond paused after the run
/// @dev Usage:
///      make upgrade 84532 rev030
contract Rev030Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 29;
    uint256 internal constant TARGET_VERSION = 30;
    /// @notice The winner cap on Tempo: a Bounty payout to fresh recipients costs about 0.78M gas
    ///         per winner there, so 30 settles well inside the 30M transaction cap.
    uint16 internal constant TEMPO_MAX_SUBMISSION_WINNERS = 30;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(
            currentVersion == EXPECTED_PRE_VERSION || currentVersion == TARGET_VERSION,
            "Rev030Upgrade: diamond is not at rev029"
        );
        bool landed = cutLanded(diamond);
        address pool = ITMPProject(diamond).fundingPool();
        require(pool != address(0), "Rev030Upgrade: funding pool not set");
        bool poolUpgraded = poolLanded(pool);
        bool keepPaused = vm.envOr("FORGE_KEEP_PAUSED", false);
        uint16 winnerCap = winnerCapFor(block.chainid);

        vm.startBroadcast(ownerKey);
        // Resumable: each step is skipped when it already landed, so after a failure part way a
        // rerun only sends what is missing. Paused across the cut and unpaused after the bump,
        // also on a rerun that finds the diamond paused by the failed run.
        if (!AdminFacet(diamond).paused()) AdminFacet(diamond).pause();
        // The pool first. Its owner is the diamond's owner, which is the broadcaster.
        if (!poolUpgraded) UUPSUpgradeable(pool).upgradeToAndCall(address(new FundingPool()), "");
        if (!landed) IDiamondCut(diamond).diamondCut(cut(), address(0), "");
        if (winnerCap != 0 && AdminFacet(diamond).maxSubmissionWinners() != winnerCap) {
            AdminFacet(diamond).setMaxSubmissionWinners(winnerCap);
        }
        if (currentVersion != TARGET_VERSION) AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);
        if (!keepPaused) AdminFacet(diamond).unpause();
        vm.stopBroadcast();

        console.log(landed ? "cut already on the diamond, skipped" : "cut sent");
        console.log("Rev030 upgrade complete. Diamond:", diamond);
        console.log(
            "AdminFacet:     ", IDiamondLoupe(diamond).facetAddress(FacetSelectors.adminFacetSelectorsAddedRev030()[0])
        );
        console.log("winner cap:     ", AdminFacet(diamond).maxSubmissionWinners());
        console.log("diamondVersion: ", TARGET_VERSION);
    }

    /// @notice The winner cap to set on `chainId`, or 0 to keep the default of 50.
    function winnerCapFor(uint256 chainId) public pure returns (uint16) {
        if (chainId == 4217 || chainId == 42431) return TEMPO_MAX_SUBMISSION_WINNERS;
        return 0;
    }

    /// @notice Whether the funding pool proxy already runs the rev030 implementation.
    function poolLanded(address pool) public view returns (bool) {
        try IFundingPoolManager(pool).fundingPoolRevision() returns (uint256 revision) {
            return revision >= TARGET_VERSION;
        } catch {
            return false;
        }
    }

    /// @notice Whether the cut is on `diamond`: maxSubmissionWinners is routed only by this cut.
    function cutLanded(address diamond) public view returns (bool) {
        return IDiamondLoupe(diamond).facetAddress(FacetSelectors.adminFacetSelectorsAddedRev030()[0]) != address(0);
    }

    /// @notice One cut: Replace every facet rev030 changes, with the selectors a rev029 diamond
    ///         routes to it that rev030 keeps, Add the AdminFacet winner-cap selectors and Remove the
    ///         three V1 hook selectors.
    function cut() public returns (IDiamondCut.FacetCut[] memory cuts) {
        IDiamondCut.FacetCutAction replace = IDiamondCut.FacetCutAction.Replace;
        cuts = new IDiamondCut.FacetCut[](15);
        address adminFacet = address(new AdminFacet());
        cuts[0] = IDiamondCut.FacetCut(adminFacet, replace, FacetSelectors.adminFacetSelectorsKeptRev030());
        cuts[1] = IDiamondCut.FacetCut(
            adminFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.adminFacetSelectorsAddedRev030()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()), replace, FacetSelectors.acceptFacetSelectorsRev028()
        );
        cuts[3] = IDiamondCut.FacetCut(address(new AuctionFacet()), replace, FacetSelectors.auctionFacetSelectors());
        cuts[4] = IDiamondCut.FacetCut(address(new CoreFacet()), replace, FacetSelectors.coreFacetSelectors());
        cuts[5] = IDiamondCut.FacetCut(address(new EvaluatorFacet()), replace, FacetSelectors.evalFacetSelectors());
        cuts[6] = IDiamondCut.FacetCut(
            address(new HookDispatchFacet()), replace, FacetSelectors.hookDispatchFacetSelectors()
        );
        cuts[7] = IDiamondCut.FacetCut(address(new HooksV2Facet()), replace, FacetSelectors.hooksV2FacetSelectors());
        cuts[8] = IDiamondCut.FacetCut(address(new ProjectFacet()), replace, FacetSelectors.projectFacetSelectors());
        cuts[9] = IDiamondCut.FacetCut(address(new RatingFacet()), replace, FacetSelectors.ratingFacetSelectors());
        cuts[10] = IDiamondCut.FacetCut(address(new RegistryFacet()), replace, FacetSelectors.registryFacetSelectors());
        cuts[11] =
            IDiamondCut.FacetCut(address(new SettlementFacet()), replace, FacetSelectors.settlementFacetSelectors());
        cuts[12] = IDiamondCut.FacetCut(address(new WorkerFacet()), replace, FacetSelectors.workerFacetSelectors());
        // The retired V1 selectors: no facet serves them any more.
        cuts[13] = IDiamondCut.FacetCut(
            address(0), IDiamondCut.FacetCutAction.Remove, FacetSelectors.selectorsRemovedRev030()
        );
        // The facet that runs this cut is replaced last: the router entry changes when the cut ends,
        // so the cut in flight finishes on the old code and the next one runs the new guards.
        cuts[14] = IDiamondCut.FacetCut(address(new DiamondCutFacet()), replace, FacetSelectors.cutFacetSelectors());
    }
}
