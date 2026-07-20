// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DiamondCutFacet } from "../../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";

/// @title FacetSelectors — single source of truth for each facet's current (steady-state)
///        selector set.
/// @dev DiamondDeploy.s.sol (fresh deploy), DiamondFullUpgrade.s.sol's steady-state
///      Replace path, and DiamondTestHelper.sol (test fixtures) all call these functions
///      instead of maintaining independent copies, so a selector added to a facet only ever
///      needs to be added here once. Historical migration-delta selector lists (selectors that
///      existed only on an old revision, or only get Added/Removed as part of a specific
///      upgrade path) have no fresh-deploy equivalent and stay local to
///      DiamondFullUpgrade.s.sol.
library FacetSelectors {
    function cutFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function loupeFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function adminFacetSelectors() internal pure returns (bytes4[] memory s) {
        // initialize is NOT included -- it is called once via the Diamond constructor's
        // _init delegatecall, never added as a routable selector.
        s = new bytes4[](17);
        s[0] = AdminFacet.paused.selector;
        s[1] = AdminFacet.pause.selector;
        s[2] = AdminFacet.unpause.selector;
        s[3] = AdminFacet.transferOwnership.selector;
        s[4] = AdminFacet.acceptOwnership.selector;
        s[5] = AdminFacet.owner.selector;
        s[6] = AdminFacet.pendingOwner.selector;
        s[7] = AdminFacet.addForwarder.selector;
        s[8] = AdminFacet.removeForwarder.selector;
        s[9] = AdminFacet.isTrustedForwarder.selector;
        s[10] = AdminFacet.setDefaultFeeBps.selector;
        s[11] = AdminFacet.setFeeRecipient.selector;
        s[12] = AdminFacet.setReputationRegistry.selector;
        s[13] = AdminFacet.setDefaultHooks.selector;
        s[14] = AdminFacet.getDefaultHooks.selector;
        s[15] = AdminFacet.diamondVersion.selector;
        s[16] = AdminFacet.setDiamondVersion.selector;
    }

    function coreFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        // public constant getters -- must use keccak256; .selector syntax does not apply to constants
        s[0] = bytes4(keccak256("BOUNTY()"));
        s[1] = bytes4(keccak256("CLAIM()"));
        s[2] = bytes4(keccak256("PITCH()"));
        s[3] = bytes4(keccak256("BENCHMARK()"));
        s[4] = bytes4(keccak256("AUCTION()"));
        s[5] = bytes4(keccak256("AUCTION_DUTCH()"));
        s[6] = bytes4(keccak256("AUCTION_ENGLISH()"));
        s[7] = bytes4(keccak256("AUCTION_REVERSE_DUTCH()"));
        s[8] = bytes4(keccak256("AUCTION_REVERSE_ENGLISH()"));
        s[9] = bytes4(keccak256("MAX_BIDS_PER_TASK()"));
        s[10] = CoreFacet.createTask.selector;
        s[11] = CoreFacet.claimTask.selector;
        s[12] = CoreFacet.selectWorker.selector;
        s[13] = CoreFacet.submitPitch.selector;
        s[14] = CoreFacet.submitProof.selector;
        s[15] = CoreFacet.submitWork.selector;
        s[16] = CoreFacet.forfeitAndReopen.selector;
        s[17] = CoreFacet.cancelTask.selector;
        s[18] = CoreFacet.updateTask.selector;
        s[19] = CoreFacet.refundExpired.selector;
        s[20] = CoreFacet.rejectSubmission.selector;
    }

    function auctionFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = AuctionFacet.submitBid.selector;
        s[1] = AuctionFacet.selectLowestBidder.selector;
        s[2] = AuctionFacet.acceptAuction.selector;
    }

    function acceptFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AcceptanceFacet.acceptSubmission.selector;
        s[1] = AcceptanceFacet.acceptSubmissions.selector;
    }

    function evalFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = EvaluatorFacet.assignEvaluator.selector;
        s[1] = EvaluatorFacet.evaluate.selector;
        s[2] = EvaluatorFacet.appeal.selector;
        s[3] = EvaluatorFacet.finalizeVerdict.selector;
        s[4] = EvaluatorFacet.resolveDispute.selector;
        s[5] = EvaluatorFacet.evaluatorTimeout.selector;
    }

    function ratingFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = RatingFacet.rateTask.selector;
        s[1] = RatingFacet.getCredibility.selector;
        s[2] = RatingFacet.getAverageRating.selector;
    }

    function registryFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](29);
        s[0] = RegistryFacet.getTask.selector;
        s[1] = RegistryFacet.getWorkerStats.selector;
        s[2] = RegistryFacet.requesterNonce.selector;
        s[3] = RegistryFacet.getTaskState.selector;
        s[4] = RegistryFacet.getTaskContext.selector;
        s[5] = RegistryFacet.getTaskVerdict.selector;
        s[6] = RegistryFacet.evaluatorFor.selector;
        s[7] = RegistryFacet.taskMode.selector;
        s[8] = RegistryFacet.defaultFeeBps.selector;
        s[9] = RegistryFacet.feeRecipient.selector;
        s[10] = RegistryFacet.totalFeesCollected.selector;
        s[11] = RegistryFacet.feeForTask.selector;
        s[12] = RegistryFacet.reputationRegistry.selector;
        s[13] = RegistryFacet.getTaskEvaluatorConfig.selector;
        s[14] = RegistryFacet.getTaskAuctionConfig.selector;
        s[15] = RegistryFacet.getTaskMetadata.selector;
        s[16] = RegistryFacet.getTaskPitchConfig.selector;
        s[17] = RegistryFacet.getBids.selector;
        s[18] = RegistryFacet.usdcToken.selector;
        s[19] = RegistryFacet.taskPitchHashes.selector;
        s[20] = RegistryFacet.taskProofHashes.selector;
        s[21] = RegistryFacet.taskSubmissionHashes.selector;
        s[22] = RegistryFacet.hasWorkerRated.selector;
        s[23] = RegistryFacet.stakeForfeit.selector;
        s[24] = RegistryFacet.taskSubmissionHashExists.selector;
        s[25] = RegistryFacet.taskActiveSubmissionCount.selector;
        s[26] = RegistryFacet.taskHasSubmissions.selector;
        s[27] = RegistryFacet.taskRejectedWorkers.selector;
        s[28] = RegistryFacet.getTaskHooks.selector;
    }
}
