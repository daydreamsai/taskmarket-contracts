// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev013Upgrade — replace CoreFacet + EvaluatorFacet with five bundled security fixes
///        (issues #198, #199, #200, #201, #203)
/// @dev CoreFacet carries the #198 refundExpired double-refund fix, the #199 rejectSubmission
///      phantom-clear fix, the #200 auction-claim-requires-deliverable fix, and the #203
///      updateTask reward-increase funding check. EvaluatorFacet carries the #201
///      empty-award appeal fix. None of these add, remove, or rename an external/public
///      function, so the selector set for both facets is unchanged from rev012 -- this is a
///      pure Replace on the two facets whose bytecode changed.
/// @dev Issue #202's EpochBudget.release() epoch-mismatch fix is intentionally NOT part of this
///      upgrade: TaskTokenRewardHook is not a Diamond facet and follows a separate deployment
///      shape (fresh hook + EpochBudget pair, old ones left authorized until drained), not a
///      diamondCut facet replacement.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev013
///      make upgrade mainnet rev013
contract Rev013Upgrade is Script {
    uint256 private constant EXPECTED_PRE_VERSION = 12;
    uint256 private constant TARGET_VERSION = 13;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev013Upgrade: diamond is not at rev012");

        vm.startBroadcast(ownerKey);

        address coreFacet = address(new CoreFacet());
        address evalFacet = address(new EvaluatorFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] =
            IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors());
        cuts[1] =
            IDiamondCut.FacetCut(evalFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev013 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:       ", coreFacet);
        console.log("EvaluatorFacet:  ", evalFacet);
        console.log("diamondVersion:  ", TARGET_VERSION);
    }
}
