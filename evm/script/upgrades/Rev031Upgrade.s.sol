// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { HookDispatchFacet } from "../../src/facets/HookDispatchFacet.sol";
import { HooksV2Facet } from "../../src/facets/HooksV2Facet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev031Upgrade -- Sponsored Tasks fixes and the rev031 diamond security fixes
/// @dev See packages/contracts/docs/specs/erc8195/rev031-sponsored-tasks-payouts-sweeps-and-releases.md.
///      Replaces every facet whose code changes in rev030 to rev031 (AcceptanceFacet, AdminFacet,
///      AuctionFacet, CoreFacet, EvaluatorFacet, HookDispatchFacet, HooksV2Facet, ProjectFacet,
///      RatingFacet, SettlementFacet, WorkerFacet). RegistryFacet, FeedbackFacet, DiamondCutFacet and
///      DiamondLoupeFacet are unchanged and keep their routes. On ProjectFacet, grantOperator takes the
///      grant's limits: the new selector is Added and the terms-only rev030 selector is Removed. Where
///      the diamond routes the zero selector (facetAddress(0x00000000) is set), the cut also Removes
///      it. AppStorage does not change. The diamond is paused across the cut, and the version is set
///      to 31 after it. A fresh deploy stamps 31 (LibRevision.CURRENT_REVISION).
///      The rest of rev031 ships outside the diamond, after this step: the two Sponsored Task V2
///      hooks are upgraded in place (DeployHooksV2.s.sol: UpgradeSponsoredTaskHookV2 and
///      UpgradeRemoteSponsoredTaskHookV2), a new vault factory is deployed next to each live one
///      (RedeploySponsoredTaskFactoryV2), PayoutGateHook is redeployed, and the Solana program is
///      deployed fresh when it goes live. The fixed TaskTokenRewardHookV2 and EpochBudget are built
///      but not deployed in this rollout.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY        -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_<chain> -- Diamond proxy on the target chain
///      FORGE_KEEP_PAUSED            -- optional; true leaves the diamond paused after the run
/// @dev Usage:
///      make upgrade 84532 rev031
contract Rev031Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 30;
    uint256 internal constant TARGET_VERSION = 31;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(
            currentVersion == EXPECTED_PRE_VERSION || currentVersion == TARGET_VERSION,
            "Rev031Upgrade: diamond is not at rev030"
        );
        bool landed = cutLanded(diamond);
        bool removeZero = zeroSelectorRouted(diamond);
        bool keepPaused = vm.envOr("FORGE_KEEP_PAUSED", false);

        vm.startBroadcast(ownerKey);
        // Resumable: after a failure part way a rerun only sends what is missing. Paused across the
        // cut and unpaused after the bump, also on a rerun that finds the diamond paused by the
        // failed run.
        if (!AdminFacet(diamond).paused()) AdminFacet(diamond).pause();
        if (splitCut(block.chainid)) {
            if (currentVersion != TARGET_VERSION) sendSplitCut(diamond, removeZero);
        } else if (!landed) {
            IDiamondCut(diamond).diamondCut(cut(removeZero), address(0), "");
        } else if (removeZero) {
            IDiamondCut(diamond).diamondCut(zeroSelectorCut(), address(0), "");
        }
        if (currentVersion != TARGET_VERSION) AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);
        if (!keepPaused) AdminFacet(diamond).unpause();
        vm.stopBroadcast();

        console.log(landed && currentVersion == TARGET_VERSION ? "cut already on the diamond, skipped" : "cut sent");
        console.log(removeZero ? "zero selector removed" : "zero selector not routed, nothing to remove");
        console.log("Rev031 upgrade complete. Diamond:", diamond);
        console.log(
            "ProjectFacet:   ", IDiamondLoupe(diamond).facetAddress(FacetSelectors.projectSelectorsAddedRev031()[0])
        );
        console.log("diamondVersion: ", TARGET_VERSION);
    }

    /// @notice Whether the cut goes out as one transaction per facet entry on `chainId`. Rev030's
    ///         15-entry cut needed about 60M gas on Tempo, over its 30M transaction cap; this one
    ///         deploys eleven facets.
    function splitCut(uint256 chainId) public pure returns (bool) {
        return chainId == 4217 || chainId == 42431;
    }

    /// @notice Sends each entry of `cut(removeZero)` as its own diamondCut. Replace entries are sent
    ///         again on a rerun (harmless); the Add and Remove entries are skipped once they landed,
    ///         because the diamond refuses to add a routed selector or remove a missing one.
    function sendSplitCut(address diamond, bool removeZero) internal {
        IDiamondCut.FacetCut[] memory all = cut(removeZero);
        for (uint256 i = 0; i < all.length; i++) {
            IDiamondCut.FacetCut memory entry = all[i];
            if (entry.action == IDiamondCut.FacetCutAction.Add && cutLanded(diamond)) continue;
            if (
                entry.action == IDiamondCut.FacetCutAction.Remove
                    && IDiamondLoupe(diamond).facetAddress(entry.functionSelectors[0]) == address(0)
            ) continue;
            IDiamondCut.FacetCut[] memory one = new IDiamondCut.FacetCut[](1);
            one[0] = entry;
            IDiamondCut(diamond).diamondCut(one, address(0), "");
        }
    }

    /// @notice Whether the cut is on `diamond`: on a live chain the grantOperator that takes limits is
    ///         routed only by this cut. A diamond built from this code and walked through the earlier
    ///         steps (DiamondSelectorParity) routes it already and takes only the version step.
    function cutLanded(address diamond) public view returns (bool) {
        return IDiamondLoupe(diamond).facetAddress(FacetSelectors.projectSelectorsAddedRev031()[0]) != address(0);
    }

    /// @notice Whether `diamond` routes the zero selector, which an Add of a list with an unset entry
    ///         routes. Calls with no selector would reach that facet.
    function zeroSelectorRouted(address diamond) public view returns (bool) {
        return IDiamondLoupe(diamond).facetAddress(bytes4(0)) != address(0);
    }

    /// @notice A Remove of the zero selector alone.
    function zeroSelectorCut() public pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, new bytes4[](1));
    }

    /// @notice One cut: Replace every facet rev031 changes, with the selectors a rev030 diamond
    ///         routes to it that rev031 keeps, Add the grantOperator that takes limits, Remove the
    ///         terms-only one, and with `removeZero` Remove the zero selector.
    function cut(bool removeZero) public returns (IDiamondCut.FacetCut[] memory cuts) {
        IDiamondCut.FacetCutAction replace = IDiamondCut.FacetCutAction.Replace;
        cuts = new IDiamondCut.FacetCut[](removeZero ? 14 : 13);
        cuts[0] = IDiamondCut.FacetCut(address(new AdminFacet()), replace, FacetSelectors.adminFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()), replace, FacetSelectors.acceptFacetSelectorsRev028()
        );
        cuts[2] = IDiamondCut.FacetCut(address(new AuctionFacet()), replace, FacetSelectors.auctionFacetSelectors());
        cuts[3] = IDiamondCut.FacetCut(address(new CoreFacet()), replace, FacetSelectors.coreFacetSelectors());
        cuts[4] = IDiamondCut.FacetCut(address(new EvaluatorFacet()), replace, FacetSelectors.evalFacetSelectors());
        cuts[5] = IDiamondCut.FacetCut(
            address(new HookDispatchFacet()), replace, FacetSelectors.hookDispatchFacetSelectors()
        );
        cuts[6] = IDiamondCut.FacetCut(address(new HooksV2Facet()), replace, FacetSelectors.hooksV2FacetSelectors());
        address projectFacet = address(new ProjectFacet());
        cuts[7] = IDiamondCut.FacetCut(projectFacet, replace, FacetSelectors.projectFacetSelectorsKeptRev031());
        cuts[8] = IDiamondCut.FacetCut(
            projectFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.projectSelectorsAddedRev031()
        );
        cuts[9] = IDiamondCut.FacetCut(address(new RatingFacet()), replace, FacetSelectors.ratingFacetSelectors());
        cuts[10] =
            IDiamondCut.FacetCut(address(new SettlementFacet()), replace, FacetSelectors.settlementFacetSelectors());
        cuts[11] = IDiamondCut.FacetCut(address(new WorkerFacet()), replace, FacetSelectors.workerFacetSelectors());
        cuts[12] = IDiamondCut.FacetCut(
            address(0), IDiamondCut.FacetCutAction.Remove, FacetSelectors.selectorsRemovedRev031()
        );
        if (removeZero) cuts[13] = zeroSelectorCut()[0];
    }
}
