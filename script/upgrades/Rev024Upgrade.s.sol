// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev024Upgrade -- every terminal path returns the stakes it holds
/// @dev Replaces AcceptanceFacet, CoreFacet, EvaluatorFacet and RatingFacet with their full selector lists.
///      finalizeVerdict and resolveDispute return a Claim worker's stake, cancelTask returns the
///      requester's evaluator stake, and acceptSubmissions returns the rounding remainder of a
///      multi-winner split to the requester. Before this, each left the amount in the diamond owed
///      to no task.
/// @dev Rev024 also makes the gas floor before a swallowed giveFeedback call per chain. It appends
///      `minFeedbackGas` to AppStorage (zero reads as the rev023 default of 450,000), Replaces
///      AdminFacet's existing selectors and Adds `minFeedbackGas()` and `setMinFeedbackGas(uint256)`,
///      and Replaces RatingFacet, whose rateTask checks the floor (AcceptanceFacet and CoreFacet are
///      already cut above). When FORGE_MIN_FEEDBACK_GAS is set the same broadcast sets the floor to
///      it; script/tempo.sh requires FORGE_MIN_FEEDBACK_GAS_TEMPO_* so Tempo never runs the new
///      facets with the Base default.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  -- Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  -- Diamond proxy on Base Mainnet (chain 8453)
///      FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET -- Diamond proxy on Tempo Moderato (chain 42431)
///      FORGE_DIAMOND_ADDRESS_TEMPO_MAINNET -- Diamond proxy on Tempo mainnet (chain 4217)
/// @dev Usage:
///      make upgrade testnet rev024
///      make upgrade mainnet rev024
contract Rev024Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 23;
    uint256 internal constant TARGET_VERSION = 24;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev024Upgrade: diamond is not at rev023");

        vm.startBroadcast(ownerKey);

        address acceptanceFacet = address(new AcceptanceFacet());
        address coreFacet = address(new CoreFacet());
        address evaluatorFacet = address(new EvaluatorFacet());
        address ratingFacet = address(new RatingFacet());
        address adminFacet = address(new AdminFacet());

        bytes4[] memory newAdminSelectors = new bytes4[](2);
        newAdminSelectors[0] = AdminFacet.minFeedbackGas.selector;
        newAdminSelectors[1] = AdminFacet.setMinFeedbackGas.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](6);
        cuts[0] = IDiamondCut.FacetCut(
            acceptanceFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.acceptFacetSelectors()
        );
        cuts[1] =
            IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors());
        cuts[2] = IDiamondCut.FacetCut(
            evaluatorFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            ratingFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.ratingFacetSelectors()
        );
        cuts[4] = IDiamondCut.FacetCut(
            adminFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.adminFacetSelectorsThroughRev023()
        );
        cuts[5] = IDiamondCut.FacetCut(adminFacet, IDiamondCut.FacetCutAction.Add, newAdminSelectors);

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        uint256 feedbackGasFloor = vm.envOr("FORGE_MIN_FEEDBACK_GAS", uint256(0));
        if (feedbackGasFloor != 0) AdminFacet(diamond).setMinFeedbackGas(feedbackGasFloor);
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev024 upgrade complete. Diamond:", diamond);
        console.log("AcceptanceFacet:", acceptanceFacet);
        console.log("CoreFacet:      ", coreFacet);
        console.log("EvaluatorFacet: ", evaluatorFacet);
        console.log("RatingFacet:    ", ratingFacet);
        console.log("AdminFacet:     ", adminFacet);
        console.log("minFeedbackGas: ", AdminFacet(diamond).minFeedbackGas());
        console.log("diamondVersion: ", TARGET_VERSION);
    }
}
