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

/// @title Rev028RefreshTestnet -- bring a diamond already cut to an earlier rev028 build up to the
///        shipped rev028 build
/// @dev Replaces every changed facet in place, swaps acceptGrant(uint256) for
///      acceptGrant(uint256,bytes32), and leaves the version at 28. Testnet only: a diamond at
///      rev027 takes Rev028Upgrade instead. Requires version 28 and the old acceptGrant routed.
///      Paused across the cuts, unpaused after.
///      Usage: forge script script/upgrades/Rev028RefreshTestnet.s.sol --rpc-url <chain> --broadcast --slow
contract Rev028RefreshTestnet is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);
        require(AdminFacet(diamond).diamondVersion() == 28, "Rev028RefreshTestnet: diamond is not at 28");
        require(
            IDiamondLoupe(diamond).facetAddress(FacetSelectors.acceptGrantSelectorRev027()) != address(0),
            "Rev028RefreshTestnet: already refreshed"
        );

        vm.startBroadcast(ownerKey);
        bool wasPaused = AdminFacet(diamond).paused();
        if (!wasPaused) AdminFacet(diamond).pause();
        IDiamondCut(diamond).diamondCut(cutOne(), address(0), "");
        IDiamondCut(diamond).diamondCut(cutTwo(), address(0), "");
        IDiamondCut(diamond).diamondCut(cutThree(), address(0), "");
        IDiamondCut(diamond).diamondCut(cutFour(), address(0), "");
        if (!wasPaused) AdminFacet(diamond).unpause();
        vm.stopBroadcast();

        console.log("Rev028 refresh complete. Diamond:", diamond);
    }

    function _r(address f, bytes4[] memory s) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(f, IDiamondCut.FacetCutAction.Replace, s);
    }

    function cutOne() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _r(address(new HookDispatchFacet()), FacetSelectors.hookDispatchFacetSelectorsThroughRev029());
        cuts[1] = _r(address(new HooksV2Facet()), FacetSelectors.hooksV2FacetSelectors());
        cuts[2] = _r(address(new CoreFacet()), FacetSelectors.coreFacetSelectors());
        cuts[3] = _r(address(new WorkerFacet()), FacetSelectors.workerFacetSelectors());
    }

    function cutTwo() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _r(address(new AuctionFacet()), FacetSelectors.auctionFacetSelectors());
        cuts[1] = _r(address(new SettlementFacet()), FacetSelectors.settlementFacetSelectors());
        cuts[2] = _r(address(new EvaluatorFacet()), FacetSelectors.evalFacetSelectors());
        cuts[3] = _r(address(new AcceptanceFacet()), FacetSelectors.acceptFacetSelectorsRev028());
        cuts[4] = _r(address(new RatingFacet()), FacetSelectors.ratingFacetSelectors());
    }

    function cutThree() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](4);
        address projectFacet = address(new ProjectFacet());
        cuts[0] = _r(projectFacet, FacetSelectors.projectFacetSelectorsRev027Routed());
        cuts[1] = IDiamondCut.FacetCut(
            projectFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.projectSelectorsAddedRev028()
        );
        bytes4[] memory oldAcceptGrant = new bytes4[](1);
        oldAcceptGrant[0] = FacetSelectors.acceptGrantSelectorRev027();
        cuts[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, oldAcceptGrant);
        cuts[3] = _r(address(new RegistryFacet()), FacetSelectors.registryFacetSelectors());
    }

    function cutFour() public returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = _r(address(new AdminFacet()), FacetSelectors.adminFacetSelectorsThroughRev029());
        cuts[1] = _r(address(new FeedbackFacet()), FacetSelectors.feedbackFacetSelectors());
    }
}
