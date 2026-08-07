// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev017Upgrade — escrow payout-recipient validation and bounded hook calls
/// @dev Deploys and cuts in the rev017 fixes for issues #316 (evaluator award recipients were
///      never validated against the task's real worker/submitter) and #317 (a requester-supplied
///      hook could force an out-of-gas in the caller purely by returning an oversized blob).
///
/// @dev Four facets are replaced, not one. Only `EvaluatorFacet` changed at the source level for
///      #316, but #317's fix lives in `LibTaskMarket`, an `internal` library -- Solidity inlines
///      internal library code into every contract that calls it, so the patched hook-dispatch
///      bytecode only reaches the chain by redeploying each facet that dispatches hooks:
///      `CoreFacet` (claimTask/submitWork/refundExpired/cancelTask/forfeitAndReopen),
///      `AuctionFacet` (bid/select flows), `AcceptanceFacet` (acceptSubmission(s)) and
///      `EvaluatorFacet` (evaluate/_payAwards). Replacing only EvaluatorFacet would leave the
///      HIGH-severity `refundExpired` fund-freeze path in #317 live on `CoreFacet`'s old bytecode.
///
/// @dev A fifth facet, `AdminFacet`, is redeployed for a different reason: rev017 makes the
///      appeal-window floor admin-settable state (`AppStorage.minAppealWindowSecs`) rather than
///      a compiled-in constant, which adds `minAppealWindowSecs()` and
///      `setMinAppealWindowSecs(uint32)` to `AdminFacet`.
///
/// @dev SELECTOR CHANGE: this step is not a pure Replace. Two selectors are added --
///      `minAppealWindowSecs()` and `setMinAppealWindowSecs(uint32)`, both on `AdminFacet`.
///      `AdminFacet` is therefore cut in two operations: a `Replace` of its seventeen
///      pre-existing selectors, then an `Add` of the two new ones (a `Replace` on a selector the
///      diamond does not yet route reverts in `LibDiamond`). No selector is removed and no
///      existing selector's signature changed. The other four facets are pure `Replace`.
///
/// @dev No storage migration is needed for the new `AppStorage.minAppealWindowSecs` field. It is
///      appended to the end of the struct, so it occupies a previously-unused slot on every
///      existing diamond, and it reads back as zero. Zero is treated as "unset" rather than "no
///      minimum" (`LibTaskMarket._minAppealWindowSecs` substitutes the compiled default), so the
///      guard is live the instant this cut lands -- it does not wait on anyone calling the
///      setter.
///
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev017
///      make upgrade mainnet rev017
contract Rev017Upgrade is Script {
    uint256 private constant EXPECTED_PRE_VERSION = 16;
    uint256 private constant TARGET_VERSION = 17;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev017Upgrade: diamond is not at rev016");

        vm.startBroadcast(ownerKey);

        address adminFacet = address(new AdminFacet());
        address coreFacet = address(new CoreFacet());
        address auctionFacet = address(new AuctionFacet());
        address acceptFacet = address(new AcceptanceFacet());
        address evalFacet = address(new EvaluatorFacet());

        // adminFacetSelectors() is the post-rev017 set (nineteen entries, the last two being the
        // new minAppealWindowSecs getter/setter). Split it: the first seventeen exist on-chain
        // already and must be Replaced, the last two do not and must be Added.
        bytes4[] memory allAdminSelectors = FacetSelectors.adminFacetSelectors();
        uint256 addedCount = 2;
        bytes4[] memory existingAdminSelectors = new bytes4[](allAdminSelectors.length - addedCount);
        for (uint256 i; i < existingAdminSelectors.length; ++i) {
            existingAdminSelectors[i] = allAdminSelectors[i];
        }
        bytes4[] memory newAdminSelectors = new bytes4[](addedCount);
        for (uint256 i; i < addedCount; ++i) {
            newAdminSelectors[i] = allAdminSelectors[existingAdminSelectors.length + i];
        }

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](6);
        cuts[0] =
            IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(
            auctionFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.auctionFacetSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(
            acceptFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.acceptFacetSelectors()
        );
        cuts[3] =
            IDiamondCut.FacetCut(evalFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors());
        cuts[4] = IDiamondCut.FacetCut(adminFacet, IDiamondCut.FacetCutAction.Replace, existingAdminSelectors);
        cuts[5] = IDiamondCut.FacetCut(adminFacet, IDiamondCut.FacetCutAction.Add, newAdminSelectors);

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev017 upgrade complete. Diamond:", diamond);
        console.log("AdminFacet:      ", adminFacet);
        console.log("CoreFacet:       ", coreFacet);
        console.log("AuctionFacet:    ", auctionFacet);
        console.log("AcceptanceFacet: ", acceptFacet);
        console.log("EvaluatorFacet:  ", evalFacet);
        console.log("diamondVersion:  ", TARGET_VERSION);
    }
}
