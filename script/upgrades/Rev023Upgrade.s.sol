// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";

/// @title Rev023Upgrade -- gas guards on every swallowed reputation call and on settlement hooks
/// @dev The guards live in LibTaskMarket, an internal library, so they are compiled into each facet
///      that uses them. Replaces AcceptanceFacet, CoreFacet, EvaluatorFacet and RatingFacet with
///      their full selector lists: a facet left out would keep the old, unguarded bytecode.
///      acceptSubmission(s), cancelTask, refundExpired and rateTask revert below a minimum gas floor
///      instead of dropping their reputation call, and onComplete / onForfeit hook dispatch reverts
///      when a hook could not be given its full gas stipend. Selectors and storage layout are
///      unchanged.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  -- Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  -- Diamond proxy on Base Mainnet (chain 8453)
///      FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET -- Diamond proxy on Tempo Moderato (chain 42431)
///      FORGE_DIAMOND_ADDRESS_TEMPO_MAINNET -- Diamond proxy on Tempo mainnet (chain 4217)
/// @dev Usage:
///      make upgrade testnet rev023
///      make upgrade mainnet rev023
contract Rev023Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 22;
    uint256 internal constant TARGET_VERSION = 23;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev023Upgrade: diamond is not at rev022");

        vm.startBroadcast(ownerKey);

        address acceptanceFacet = address(new AcceptanceFacet());
        address coreFacet = address(new CoreFacet());
        address evaluatorFacet = address(new EvaluatorFacet());
        address ratingFacet = address(new RatingFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
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

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev023 upgrade complete. Diamond:", diamond);
        console.log("AcceptanceFacet:", acceptanceFacet);
        console.log("CoreFacet:      ", coreFacet);
        console.log("EvaluatorFacet: ", evaluatorFacet);
        console.log("RatingFacet:    ", ratingFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }
}
