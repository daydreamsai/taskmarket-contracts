// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev028Upgrade -- projects
/// @dev Appends the project fields to AppStorage. Adds ProjectFacet. Replaces CoreFacet,
///      AcceptanceFacet, EvaluatorFacet and SettlementFacet, which now pay money owed to a project
///      task's requester back into its project, and whose task-creation payment checks accept a
///      task the project paid for. Replaces those four, RatingFacet and WorkerFacet, whose
///      requester checks now follow an operator's grant terms. Every other facet is unchanged.
/// @dev One diamondCut transaction: seven facets, about fifty selectors.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_84532  -- Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_8453  -- Diamond proxy on Base Mainnet (chain 8453)
///      FORGE_DIAMOND_ADDRESS_42431 -- Diamond proxy on Tempo Moderato (chain 42431)
///      FORGE_DIAMOND_ADDRESS_4217 -- Diamond proxy on Tempo mainnet (chain 4217)
/// @dev Usage:
///      make upgrade 84532 rev028
///      make upgrade 8453 rev028
contract Rev028Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 27;
    uint256 internal constant TARGET_VERSION = 28;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev028Upgrade: diamond is not at rev027");

        vm.startBroadcast(ownerKey);
        IDiamondCut(diamond).diamondCut(_cut(), address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);
        vm.stopBroadcast();

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        console.log("Rev028 upgrade complete. Diamond:", diamond);
        console.log("ProjectFacet:   ", loupe.facetAddress(FacetSelectors.projectFacetSelectors()[0]));
        console.log("CoreFacet:      ", loupe.facetAddress(FacetSelectors.coreFacetSelectors()[0]));
        console.log("AcceptanceFacet:", loupe.facetAddress(FacetSelectors.acceptFacetSelectors()[0]));
        console.log("EvaluatorFacet: ", loupe.facetAddress(FacetSelectors.evalFacetSelectors()[0]));
        console.log("SettlementFacet:", loupe.facetAddress(FacetSelectors.settlementFacetSelectors()[0]));
        console.log("diamondVersion: ", TARGET_VERSION);
    }

    function _cut() internal returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](7);
        cuts[0] = IDiamondCut.FacetCut(
            address(new ProjectFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.projectFacetSelectors()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new CoreFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.acceptFacetSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(new EvaluatorFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors()
        );
        cuts[4] = IDiamondCut.FacetCut(
            address(new SettlementFacet()),
            IDiamondCut.FacetCutAction.Replace,
            FacetSelectors.settlementFacetSelectors()
        );
        cuts[5] = IDiamondCut.FacetCut(
            address(new RatingFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.ratingFacetSelectors()
        );
        cuts[6] = IDiamondCut.FacetCut(
            address(new WorkerFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.workerFacetSelectors()
        );
    }
}
