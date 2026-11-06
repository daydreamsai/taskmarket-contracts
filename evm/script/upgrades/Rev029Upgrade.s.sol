// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { HooksV2Facet } from "../../src/facets/HooksV2Facet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { FundingPool } from "../../src/FundingPool.sol";
import { ITMPProject } from "../../src/interfaces/ITMPProject.sol";
import { IFundingPoolManager } from "../../src/interfaces/IFundingPoolManager.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev029Upgrade -- project grants (re-grant, cap raise), owner transfer and end-date extension
/// @dev See packages/contracts/docs/specs/erc8195/rev029-project-grant-regrant-and-cap-raise.md.
///      Replaces ProjectFacet (grantOperator accepts a revoked grant; the other selectors are
///      unchanged) and Adds raiseGrantCap and the owner transfer and extension functions. LibGuards
///      changes (a project task is acted for by the project's current owner), so the facets that
///      call it are replaced too. The FundingPool proxy is upgraded to the rev029 implementation
///      first (extendClosesAt, moveBacking). AppStorage gains one field at its end. The version is
///      set to 29 after the cut.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY        -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_<chain> -- Diamond proxy on the target chain
/// @dev Usage:
///      make upgrade 84532 rev029
contract Rev029Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 28;
    uint256 internal constant TARGET_VERSION = 29;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(
            currentVersion == EXPECTED_PRE_VERSION || currentVersion == TARGET_VERSION,
            "Rev029Upgrade: diamond is not at rev028"
        );
        bool landed = cutLanded(diamond);
        address pool = ITMPProject(diamond).fundingPool();
        require(pool != address(0), "Rev029Upgrade: funding pool not set");
        bool poolUpgraded = poolLanded(pool);
        bool keepPaused = vm.envOr("FORGE_KEEP_PAUSED", false);

        vm.startBroadcast(ownerKey);
        // Resumable: a cut already on the diamond is skipped and its facet is not deployed again,
        // so after a failure between the cut and the version bump a rerun only bumps the version.
        // Paused across the cut and unpaused after the bump, also on a rerun that finds the
        // diamond paused by the failed run. FORGE_KEEP_PAUSED=true leaves it paused.
        if (!AdminFacet(diamond).paused()) AdminFacet(diamond).pause();
        // The pool first: the new ProjectFacet calls extendClosesAt and moveBacking on it. The
        // pool's owner is the diamond's owner, which is the broadcaster. Skipped on a rerun.
        if (!poolUpgraded) UUPSUpgradeable(pool).upgradeToAndCall(address(new FundingPool()), "");
        if (!landed) IDiamondCut(diamond).diamondCut(cut(), address(0), "");
        // Replace only, so resending it after a failed version bump is harmless.
        if (currentVersion != TARGET_VERSION) IDiamondCut(diamond).diamondCut(cutTwo(), address(0), "");
        if (currentVersion != TARGET_VERSION) AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);
        if (!keepPaused) AdminFacet(diamond).unpause();
        vm.stopBroadcast();

        console.log(landed ? "cut already on the diamond, skipped" : "cut sent");
        console.log("Rev029 upgrade complete. Diamond:", diamond);
        console.log(
            "ProjectFacet:   ", IDiamondLoupe(diamond).facetAddress(FacetSelectors.projectSelectorsAddedRev029()[0])
        );
        console.log("diamondVersion: ", TARGET_VERSION);
    }

    /// @notice Whether the funding pool proxy already runs the rev029 implementation.
    function poolLanded(address pool) public view returns (bool) {
        try IFundingPoolManager(pool).fundingPoolRevision() returns (uint256 revision) {
            return revision >= TARGET_VERSION;
        } catch {
            return false;
        }
    }

    /// @notice Whether the cut is on `diamond`: raiseGrantCap is routed only by this cut.
    function cutLanded(address diamond) public view returns (bool) {
        return IDiamondLoupe(diamond).facetAddress(FacetSelectors.projectSelectorsAddedRev029()[0]) != address(0);
    }

    /// @notice ProjectFacet: Replace what rev028 routes, Add raiseGrantCap.
    function cut() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](2);
        address projectFacet = address(new ProjectFacet());
        cuts[0] = IDiamondCut.FacetCut(
            projectFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.projectFacetSelectorsRev028Routed()
        );
        cuts[1] = IDiamondCut.FacetCut(
            projectFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.projectSelectorsAddedRev029()
        );
    }

    /// @notice The facets that compile LibGuards._requireRequester, and HooksV2Facet's requester role,
    ///         Replace only: a project task is acted for by the project's current owner.
    function cutTwo() public returns (IDiamondCut.FacetCut[] memory cuts) {
        IDiamondCut.FacetCutAction replace = IDiamondCut.FacetCutAction.Replace;
        cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = IDiamondCut.FacetCut(address(new CoreFacet()), replace, FacetSelectors.coreFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(address(new WorkerFacet()), replace, FacetSelectors.workerFacetSelectors());
        cuts[2] =
            IDiamondCut.FacetCut(address(new SettlementFacet()), replace, FacetSelectors.settlementFacetSelectors());
        cuts[3] = IDiamondCut.FacetCut(address(new EvaluatorFacet()), replace, FacetSelectors.evalFacetSelectors());
        cuts[4] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()), replace, FacetSelectors.acceptFacetSelectorsRev028()
        );
        cuts[5] = IDiamondCut.FacetCut(address(new RatingFacet()), replace, FacetSelectors.ratingFacetSelectors());
        cuts[6] = IDiamondCut.FacetCut(address(new HooksV2Facet()), replace, FacetSelectors.hooksV2FacetSelectors());
    }
}
