// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { FeedbackBackfillFacet } from "../../src/facets/FeedbackBackfillFacet.sol";

/// @title AddFeedbackBackfill -- temporarily route the owner-only feedback backfill
/// @dev Not a revision step: it does not change diamondVersion, and it lives outside
///      script/upgrades so the revision-sequence tooling never sees it. Requires revision 23.
///      Undo it with RemoveFeedbackBackfill once the backfill is verified.
/// @dev Required env vars: FORGE_DEV_PRIVATE_KEY (owner), FORGE_DIAMOND_ADDRESS_TESTNET or
///      FORGE_DIAMOND_ADDRESS_MAINNET.
/// @dev Usage, from packages/contracts (dry run first; use `base_sepolia` for testnet):
///      forge script script/temp/AddFeedbackBackfill.s.sol:AddFeedbackBackfill --rpc-url base
///      forge script script/temp/AddFeedbackBackfill.s.sol:AddFeedbackBackfill --rpc-url base --broadcast --verify
contract AddFeedbackBackfill is Script {
    uint256 internal constant REQUIRED_VERSION = 23;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        require(
            AdminFacet(diamond).diamondVersion() == REQUIRED_VERSION, "AddFeedbackBackfill: diamond is not at rev023"
        );
        require(
            IDiamondLoupe(diamond).facetAddress(FeedbackBackfillFacet.backfillFeedback.selector) == address(0),
            "AddFeedbackBackfill: already routed"
        );

        vm.startBroadcast(ownerKey);
        address facet = address(new FeedbackBackfillFacet());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FeedbackBackfillFacet.backfillFeedback.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, selectors);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        require(
            IDiamondLoupe(diamond).facetAddress(FeedbackBackfillFacet.backfillFeedback.selector) == facet,
            "AddFeedbackBackfill: selector not routed"
        );
        console.log("FeedbackBackfillFacet added. Diamond:", diamond);
        console.log("FeedbackBackfillFacet:", facet);
    }
}
