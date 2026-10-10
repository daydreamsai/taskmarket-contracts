// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { FeedbackBackfillFacet } from "../../src/facets/FeedbackBackfillFacet.sol";

/// @title RemoveFeedbackBackfill -- unroute the temporary owner-only feedback backfill
/// @dev Run after the backfill is verified. The facet contract stays deployed but unreachable and
///      holds no storage. After removal the selector must route nowhere.
/// @dev Required env vars: FORGE_DEV_PRIVATE_KEY (owner), FORGE_DIAMOND_ADDRESS_TESTNET or
///      FORGE_DIAMOND_ADDRESS_MAINNET.
contract RemoveFeedbackBackfill is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        require(
            IDiamondLoupe(diamond).facetAddress(FeedbackBackfillFacet.backfillFeedback.selector) != address(0),
            "RemoveFeedbackBackfill: not routed"
        );

        vm.startBroadcast(ownerKey);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = FeedbackBackfillFacet.backfillFeedback.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, selectors);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        require(
            IDiamondLoupe(diamond).facetAddress(FeedbackBackfillFacet.backfillFeedback.selector) == address(0),
            "RemoveFeedbackBackfill: selector still routed"
        );
        console.log("FeedbackBackfillFacet unrouted. Diamond:", diamond);
    }
}
