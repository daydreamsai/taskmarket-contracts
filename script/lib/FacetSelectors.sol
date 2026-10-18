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
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { ITMPDiamond } from "../../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../../src/interfaces/ITMPTerms.sol";

/// @title FacetSelectors — single source of truth for each facet's current (steady-state)
///        selector set.
/// @dev DiamondDeploy.s.sol (fresh deploy), the RevNNNUpgrade step scripts' steady-state
///      Replace cuts, and DiamondTestHelper.sol (test fixtures) all call these functions
///      instead of maintaining independent copies, so a selector added to a facet only ever
///      needs to be added here once. Historical migration-delta selector lists (selectors that
///      existed only on an old revision, or only get Added/Removed as part of one specific
///      step) have no fresh-deploy equivalent and stay local to the step script or the test
///      that names them.
library FacetSelectors {
    /// @dev The pre-rev018 nine-parameter `createTask`. Rev018 kept it routed beside the
    ///      evaluator-aware overload so off-chain callers could migrate after the facet cut rather
    ///      than in lockstep with it; rev019 removed the shim behind it, so it is no longer part
    ///      of any steady-state selector set and is not in `coreFacetSelectors()`.
    /// @dev It survives as a constant because the historical upgrade paths still have to name it:
    ///      Rev014Upgrade Adds it, Rev018Upgrade Replaces it, and Rev019Upgrade Removes it. A
    ///      selector no facet serves has no `.selector` expression to derive it from, so the
    ///      signature hash is written out -- the same idiom the other historical selectors named
    ///      by a step script or a step test use.
    bytes4 internal constant LEGACY_CREATE_TASK = bytes4(
        keccak256(
            "createTask(uint256,uint256,bytes4,uint256,uint256,bytes4,(bool,uint16),(address[],bytes),(bytes32,string,bytes32[]))"
        )
    );

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
        bytes4[] memory base = adminFacetSelectorsThroughRev024();
        s = new bytes4[](base.length + 3);
        for (uint256 i; i < base.length; ++i) {
            s[i] = base[i];
        }
        // rev025: the owner-only bounds on requester-chosen settlement terms.
        s[base.length] = AdminFacet.setTermsBounds.selector;
        // rev025: the owner-only per-chain limits on tags and hooks per task.
        s[base.length + 1] = AdminFacet.setTaskLimits.selector;
        s[base.length + 2] = AdminFacet.taskLimits.selector;
    }

    /// @dev The AdminFacet selector set as it stood at rev024, cut by the rev024 and rev025 steps.
    function adminFacetSelectorsThroughRev024() internal pure returns (bytes4[] memory s) {
        // initialize is NOT included -- it is called once via the Diamond constructor's
        // _init delegatecall, never added as a routable selector.
        bytes4[] memory base = adminFacetSelectorsThroughRev023();
        s = new bytes4[](base.length + 2);
        for (uint256 i; i < base.length; ++i) {
            s[i] = base[i];
        }
        // rev024: the per-chain feedback gas floor. Kept out of adminFacetSelectorsThroughRev023
        // so the rev017 and rev020 step scripts still cut exactly the set they cut on-chain.
        s[base.length] = AdminFacet.minFeedbackGas.selector;
        s[base.length + 1] = AdminFacet.setMinFeedbackGas.selector;
    }

    /// @dev The AdminFacet selector set as it stood from rev017 to rev023. Historical step
    ///      scripts (rev017, rev020) and Rev024Upgrade's Replace use this; deploys use
    ///      adminFacetSelectors().
    function adminFacetSelectorsThroughRev023() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](19);
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
        // rev017: the appeal-window floor is admin-settable state, so both its getter and its
        // setter must route through the Diamond.
        s[17] = AdminFacet.minAppealWindowSecs.selector;
        s[18] = AdminFacet.setMinAppealWindowSecs.selector;
    }

    function coreFacetSelectors() internal pure returns (bytes4[] memory s) {
        bytes4[] memory base = coreFacetSelectorsThroughRev024();
        bytes4[] memory moved = settlementFacetSelectorsFromCore();
        s = new bytes4[](base.length - moved.length + 1);
        uint256 n;
        for (uint256 i; i < base.length; ++i) {
            if (!_contains(moved, base[i])) s[n++] = base[i];
        }
        // rev025: createTask with explicit settlement terms.
        s[n] = ITMPTerms.createTask.selector;
    }

    function _contains(bytes4[] memory list, bytes4 sel) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == sel) return true;
        }
        return false;
    }

    /// @dev The CoreFacet selector set as it stood from rev018 to rev024. Historical step scripts
    ///      Replace this rather than coreFacetSelectors(), so they cut exactly the set they cut
    ///      on-chain and never name a selector that did not yet exist.
    function coreFacetSelectorsThroughRev024() internal pure returns (bytes4[] memory s) {
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
        s[10] = ITMPDiamond.createTask.selector;
        s[11] = CoreFacet.claimTask.selector;
        s[12] = CoreFacet.selectWorker.selector;
        s[13] = CoreFacet.submitPitch.selector;
        s[14] = CoreFacet.submitProof.selector;
        s[15] = CoreFacet.submitWork.selector;
        s[16] = ITMPDiamond.forfeitAndReopen.selector;
        s[17] = ITMPDiamond.cancelTask.selector;
        s[18] = CoreFacet.updateTask.selector;
        s[19] = ITMPDiamond.refundExpired.selector;
        s[20] = ITMPDiamond.rejectSubmission.selector;
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

    /// @dev rev025: the settlement terms surface plus the settlement calls moved off CoreFacet.
    function settlementFacetSelectors() internal pure returns (bytes4[] memory s) {
        bytes4[] memory added = settlementFacetSelectorsAdded();
        bytes4[] memory moved = settlementFacetSelectorsFromCore();
        s = new bytes4[](added.length + moved.length);
        for (uint256 i; i < added.length; ++i) {
            s[i] = added[i];
        }
        for (uint256 i; i < moved.length; ++i) {
            s[added.length + i] = moved[i];
        }
    }

    /// @dev rev025: the selectors SettlementFacet introduces, which rev025 Adds.
    function settlementFacetSelectorsAdded() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = SettlementFacet.normalizeTerms.selector;
        s[1] = SettlementFacet.getTaskTerms.selector;
        s[2] = SettlementFacet.termsBounds.selector;
        s[3] = SettlementFacet.reviewDeadline.selector;
        s[4] = SettlementFacet.rejectDelivery.selector;
        s[5] = SettlementFacet.requestRevision.selector;
        s[6] = SettlementFacet.settleLapsedReview.selector;
        s[7] = SettlementFacet.MAX_SUBMISSION_WINNERS.selector;
        s[8] = SettlementFacet.releaseClaim.selector;
        s[9] = SettlementFacet.isSettling.selector;
        s[10] = SettlementFacet.getTaskClock.selector;
    }

    /// @dev rev025: the selectors CoreFacet served through rev024 that rev025 Replaces onto
    ///      SettlementFacet.
    function settlementFacetSelectorsFromCore() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = SettlementFacet.rejectSubmission.selector;
        s[1] = SettlementFacet.forfeitAndReopen.selector;
        s[2] = SettlementFacet.cancelTask.selector;
        s[3] = SettlementFacet.refundExpired.selector;
    }
}
