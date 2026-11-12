// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DiamondCutFacet } from "../../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { FeedbackFacet } from "../../src/facets/FeedbackFacet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { HookDispatchFacet } from "../../src/facets/HookDispatchFacet.sol";
import { HooksV2Facet } from "../../src/facets/HooksV2Facet.sol";
import { ITMPDiamond } from "../../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../../src/interfaces/ITMPTerms.sol";
import { ITMPReservation } from "../../src/interfaces/ITMPReservation.sol";

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

    /// @dev The rev018 `createTask` taking a StakeConfig, which rev025 kept beside the
    ///      terms-taking overload and rev026 Removes. Written out for the same reason as
    ///      LEGACY_CREATE_TASK: no facet serves it any more.
    bytes4 internal constant REV018_CREATE_TASK = bytes4(
        keccak256(
            "createTask((uint256,uint256,bytes4,uint256,uint256,bytes4),(bool,uint16),(address[],bytes),(bytes32,string,bytes32[]),(address,uint256,uint16,uint32,uint32,address))"
        )
    );

    /// @dev The rev025 `createTask` taking version 1 terms. rev027's version 2 TaskTerms changed
    ///      `ITMPTerms.createTask.selector`, so the selector rev025 Added, and rev027 keeps routed
    ///      to its legacy overload, is written out.
    bytes4 internal constant REV025_CREATE_TASK = bytes4(
        keccak256(
            "createTask((uint256,uint256,bytes4,uint256,uint256,bytes4),(address[],bytes),(bytes32,string,bytes32[]),(address,uint256,uint16,uint32,uint32,address),(uint8,bool,uint16,uint8,uint32,uint32,uint32,uint8,uint16,uint8,uint16,uint8,uint32))"
        )
    );

    /// @dev rev025's permissionless normalizeTerms, which rev026 Removes.
    bytes4 internal constant NORMALIZE_TERMS = bytes4(keccak256("normalizeTerms(bytes32[])"));

    /// @dev rev008's V1 protocol default hook setter, which rev030 Removes with the rest of V1 hook
    ///      dispatch. No facet serves it any more, so the signature hash is written out, as for the
    ///      other selectors a historical step still has to name.
    bytes4 internal constant SET_DEFAULT_HOOKS = bytes4(keccak256("setDefaultHooks(address[])"));

    /// @dev rev008's V1 protocol default hook view, which rev030 Removes.
    bytes4 internal constant GET_DEFAULT_HOOKS = bytes4(keccak256("getDefaultHooks()"));

    /// @dev rev028's internal V1 checkComplete dispatch on HookDispatchFacet, which rev030 Removes.
    bytes4 internal constant HOOK_CHECK_COMPLETE_V1 = bytes4(
        keccak256(
            "hookCheckCompleteV1(bytes32,(bool,uint8,uint16,uint16,bytes32[],bytes32,(address,uint256,uint16)[]),bool)"
        )
    );

    /// @dev The selectors rev030 Removes: the V1 default hook setter and view (AdminFacet) and the V1
    ///      checkComplete dispatch (HookDispatchFacet).
    function selectorsRemovedRev030() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = SET_DEFAULT_HOOKS;
        s[1] = GET_DEFAULT_HOOKS;
        s[2] = HOOK_CHECK_COMPLETE_V1;
    }

    /// @dev The two AdminFacet selectors rev030 Removes.
    function adminSelectorsRemovedRev030() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = SET_DEFAULT_HOOKS;
        s[1] = GET_DEFAULT_HOOKS;
    }

    /// @dev The selectors rev026 Removes.
    function selectorsRemovedRev026() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = REV018_CREATE_TASK;
        s[1] = NORMALIZE_TERMS;
    }

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
        bytes4[] memory base = adminFacetSelectorsKeptRev030();
        bytes4[] memory added = adminFacetSelectorsAddedRev030();
        s = new bytes4[](base.length + added.length);
        for (uint256 i; i < base.length; ++i) {
            s[i] = base[i];
        }
        for (uint256 i; i < added.length; ++i) {
            s[base.length + i] = added[i];
        }
    }

    /// @dev The AdminFacet selectors a rev029 diamond routes that rev030 keeps, for the rev030 Replace.
    function adminFacetSelectorsKeptRev030() internal pure returns (bytes4[] memory s) {
        s = _without(adminFacetSelectorsThroughRev029(), adminSelectorsRemovedRev030());
    }

    /// @dev rev030: the per-chain cap on the winners one settlement may pay.
    function adminFacetSelectorsAddedRev030() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.maxSubmissionWinners.selector;
        s[1] = AdminFacet.setMaxSubmissionWinners.selector;
    }

    /// @dev The AdminFacet selector set as it stood from rev026 to rev029, Replaced by the rev030
    ///      step.
    function adminFacetSelectorsThroughRev029() internal pure returns (bytes4[] memory s) {
        bytes4[] memory base = adminFacetSelectorsThroughRev025();
        bytes4[] memory added = adminFacetSelectorsAddedRev026();
        s = new bytes4[](base.length + added.length);
        for (uint256 i; i < base.length; ++i) {
            s[i] = base[i];
        }
        for (uint256 i; i < added.length; ++i) {
            s[base.length + i] = added[i];
        }
    }

    /// @dev rev026: the owner-only liability backfill and escrow surplus sweep, and the per-chain
    ///      hook gas stipend.
    function adminFacetSelectorsAddedRev026() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = AdminFacet.sweepSurplus.selector;
        s[1] = AdminFacet.backfillLiabilities.selector;
        s[2] = AdminFacet.completeLiabilities.selector;
        s[3] = AdminFacet.hookGasStipend.selector;
        s[4] = AdminFacet.setHookGasStipend.selector;
    }

    /// @dev The AdminFacet selector set as it stood at rev025, Replaced by the rev026 step.
    function adminFacetSelectorsThroughRev025() internal pure returns (bytes4[] memory s) {
        bytes4[] memory base = adminFacetSelectorsThroughRev024();
        s = new bytes4[](base.length + 7);
        for (uint256 i; i < base.length; ++i) {
            s[i] = base[i];
        }
        // rev025: the owner-only bounds on requester-chosen settlement terms.
        s[base.length] = AdminFacet.setTermsBounds.selector;
        // rev025: the owner-only per-chain limits on tags and hooks per task.
        s[base.length + 1] = AdminFacet.setTaskLimits.selector;
        s[base.length + 2] = AdminFacet.taskLimits.selector;
        // rev025: the owner-only per-chain minimum evaluation window.
        s[base.length + 3] = AdminFacet.minEvaluationWindowSecs.selector;
        s[base.length + 4] = AdminFacet.setMinEvaluationWindowSecs.selector;
        // rev025: the owner-only ERC-8004 identity registry.
        s[base.length + 5] = AdminFacet.setIdentityRegistry.selector;
        s[base.length + 6] = AdminFacet.identityRegistry.selector;
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
        s[13] = SET_DEFAULT_HOOKS;
        s[14] = GET_DEFAULT_HOOKS;
        s[15] = AdminFacet.diamondVersion.selector;
        s[16] = AdminFacet.setDiamondVersion.selector;
        // rev017: the appeal-window floor is admin-settable state, so both its getter and its
        // setter must route through the Diamond.
        s[17] = AdminFacet.minAppealWindowSecs.selector;
        s[18] = AdminFacet.setMinAppealWindowSecs.selector;
    }

    function coreFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = _concat(coreFacetSelectorsKeptRev027(), coreFacetSelectorsAddedRev027());
    }

    /// @dev rev027: the CoreFacet selectors through rev026 that stay on CoreFacet, Replaced by the
    ///      rev027 step; the rest move to WorkerFacet.
    function coreFacetSelectorsKeptRev027() internal pure returns (bytes4[] memory s) {
        s = _without(coreFacetSelectorsThroughRev026(), workerFacetSelectorsFromCore());
    }

    /// @dev rev027: the CoreFacet selectors it Adds, without the one it Adds to WorkerFacet.
    function coreFacetSelectorsAddedRev027() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = ITMPTerms.createTask.selector;
        s[1] = ITMPReservation.createTask.selector;
    }

    /// @dev rev027: the claim, worker selection and submission entrypoints, on WorkerFacet.
    function workerFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = _concat(workerFacetSelectorsFromCore(), workerFacetSelectorsAddedRev027());
    }

    /// @dev rev027: the selectors CoreFacet served through rev026 that rev027 Replaces onto
    ///      WorkerFacet, with their signatures unchanged.
    function workerFacetSelectorsFromCore() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = ITMPDiamond.claimTask.selector;
        s[1] = WorkerFacet.selectWorker.selector;
        s[2] = WorkerFacet.submitPitch.selector;
        s[3] = WorkerFacet.submitProof.selector;
        s[4] = WorkerFacet.submitWork.selector;
    }

    /// @dev Every selector rev027 Adds, on any facet, projects included.
    function selectorsAddedRev027() internal pure returns (bytes4[] memory s) {
        s = _concat(
            _concat(
                _concat(coreFacetSelectorsAddedRev027(), workerFacetSelectorsAddedRev027()),
                _concat(settlementFacetSelectorsAddedRev027(), feedbackFacetSelectorsAddedRev027())
            ),
            projectFacetSelectorsRev027()
        );
    }

    /// @dev The selectors rev027 added that a rev028 diamond still routes: selectorsAddedRev027 without
    ///      acceptGrant, which rev028 swapped (see projectSelectorsAddedRev028). For tests that strip a
    ///      current diamond back to rev026.
    function selectorsAddedRev027OnRev028() internal pure returns (bytes4[] memory s) {
        s = _concat(
            _concat(
                _concat(coreFacetSelectorsAddedRev027(), workerFacetSelectorsAddedRev027()),
                _concat(settlementFacetSelectorsAddedRev027(), feedbackFacetSelectorsAddedRev027())
            ),
            projectFacetSelectorsRev027Routed()
        );
    }

    /// @dev rev027: claimTask with the worker's agent ID.
    function workerFacetSelectorsAddedRev027() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ITMPReservation.claimTask.selector;
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) private pure returns (bytes4[] memory s) {
        s = new bytes4[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            s[i] = a[i];
        }
        for (uint256 i; i < b.length; ++i) {
            s[a.length + i] = b[i];
        }
    }

    function _without(bytes4[] memory a, bytes4[] memory b) private pure returns (bytes4[] memory s) {
        uint256 n;
        for (uint256 i; i < a.length; ++i) {
            if (!_contains(b, a[i])) ++n;
        }
        s = new bytes4[](n);
        n = 0;
        for (uint256 i; i < a.length; ++i) {
            if (!_contains(b, a[i])) s[n++] = a[i];
        }
    }

    /// @dev The CoreFacet selector set as it stood at rev026, Replaced by the rev026 and rev027 steps.
    function coreFacetSelectorsThroughRev026() internal pure returns (bytes4[] memory s) {
        bytes4[] memory base = coreFacetSelectorsThroughRev024();
        bytes4[] memory moved = settlementFacetSelectorsFromCore();
        // rev026 drops the rev018 createTask, which is in base and not in moved.
        s = new bytes4[](base.length - moved.length);
        uint256 n;
        for (uint256 i; i < base.length; ++i) {
            if (!_contains(moved, base[i]) && base[i] != REV018_CREATE_TASK) s[n++] = base[i];
        }
        // rev025: createTask with explicit (version 1) settlement terms.
        s[n] = REV025_CREATE_TASK;
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
        s[10] = REV018_CREATE_TASK;
        s[11] = ITMPDiamond.claimTask.selector;
        s[12] = WorkerFacet.selectWorker.selector;
        s[13] = WorkerFacet.submitPitch.selector;
        s[14] = WorkerFacet.submitProof.selector;
        s[15] = WorkerFacet.submitWork.selector;
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
        s = _concat(registryFacetSelectorsThroughRev026(), settlementViewSelectorsMovedRev028());
    }

    /// @dev The RegistryFacet selector set as it stood through rev027.
    function registryFacetSelectorsThroughRev026() internal pure returns (bytes4[] memory s) {
        s = _concat(registryFacetSelectorsThroughRev025(), registryFacetSelectorsAddedRev026());
    }

    /// @dev rev026: the escrow liability views.
    function registryFacetSelectorsAddedRev026() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = RegistryFacet.totalLiabilities.selector;
        s[1] = RegistryFacet.escrowRecord.selector;
        s[2] = RegistryFacet.liabilitiesInitialised.selector;
    }

    /// @dev The RegistryFacet selector set as it stood through rev025, Replaced by the rev026 step.
    function registryFacetSelectorsThroughRev025() internal pure returns (bytes4[] memory s) {
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

    /// @dev rev025: the settlement terms surface plus the settlement calls moved off CoreFacet,
    ///      less normalizeTerms, which rev026 removed.
    /// @dev rev028: the settlement views move to RegistryFacet (settlementViewSelectorsMovedRev028).
    function settlementFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = _without(
            _without(
                _concat(settlementFacetSelectorsThroughRev026(), settlementFacetSelectorsAddedRev027()),
                settlementViewSelectorsMovedRev028()
            ),
            settlementSelectorsMovedToAcceptanceRev028()
        );
    }

    /// @dev The rev026 SettlementFacet set less what this build's SettlementFacet no longer serves
    ///      (rev028 moved the views to RegistryFacet and settleLapsedReview to AcceptanceFacet). The
    ///      historical rev027 step Replaces this list, so a test that runs it with this build's
    ///      bytecode never routes a selector to a facet that lacks it.
    function settlementFacetSelectorsThroughRev026ServedNow() internal pure returns (bytes4[] memory s) {
        s = _without(
            _without(settlementFacetSelectorsThroughRev026(), settlementViewSelectorsMovedRev028()),
            settlementSelectorsMovedToAcceptanceRev028()
        );
    }

    /// @dev rev027's added settlement selectors less getReservation, which this build serves from
    ///      RegistryFacet.
    function settlementFacetSelectorsAddedRev027ServedNow() internal pure returns (bytes4[] memory s) {
        s = _without(settlementFacetSelectorsAddedRev027(), rev027SelectorsServedByRegistryNow());
    }

    function rev027SelectorsServedByRegistryNow() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = RegistryFacet.getReservation.selector;
    }

    /// @dev rev028: settleLapsedReview moves to AcceptanceFacet, selector unchanged.
    function settlementSelectorsMovedToAcceptanceRev028() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = AcceptanceFacet.settleLapsedReview.selector;
    }

    /// @dev rev028: the steady-state AcceptanceFacet set (acceptFacetSelectors stays the historical
    ///      list the earlier step scripts Replace).
    function acceptFacetSelectorsRev028() internal pure returns (bytes4[] memory s) {
        s = _concat(acceptFacetSelectors(), settlementSelectorsMovedToAcceptanceRev028());
    }

    /// @dev rev028: the settlement views RegistryFacet serves from rev028 on, selectors unchanged, so
    ///      SettlementFacet fits under the contract size limit.
    function settlementViewSelectorsMovedRev028() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = RegistryFacet.getTaskTerms.selector;
        s[1] = RegistryFacet.getTaskClock.selector;
        s[2] = RegistryFacet.termsBounds.selector;
        s[3] = RegistryFacet.getReservation.selector;
        s[4] = RegistryFacet.isSettling.selector;
        s[5] = RegistryFacet.MAX_SUBMISSION_WINNERS.selector;
        s[6] = RegistryFacet.reviewDeadline.selector;
    }

    /// @dev rev027: decline, the reservation view and the permissionless requester timeout.
    function settlementFacetSelectorsAddedRev027() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = SettlementFacet.declineReservation.selector;
        s[1] = RegistryFacet.getReservation.selector;
        s[2] = SettlementFacet.requesterTimeout.selector;
    }

    /// @dev The SettlementFacet selector set as it stood at rev026, Replaced by the rev026 and
    ///      rev027 steps.
    function settlementFacetSelectorsThroughRev026() internal pure returns (bytes4[] memory s) {
        bytes4[] memory added = settlementFacetSelectorsAdded();
        bytes4[] memory moved = settlementFacetSelectorsFromCore();
        s = new bytes4[](added.length - 1 + moved.length);
        uint256 n;
        for (uint256 i; i < added.length; ++i) {
            if (added[i] != NORMALIZE_TERMS) s[n++] = added[i];
        }
        for (uint256 i; i < moved.length; ++i) {
            s[n + i] = moved[i];
        }
    }

    /// @dev rev025: the selectors SettlementFacet introduces, which rev025 Adds. Historical: it
    ///      still names normalizeTerms, which rev026 Removes.
    function settlementFacetSelectorsAdded() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = NORMALIZE_TERMS;
        s[1] = RegistryFacet.getTaskTerms.selector;
        s[2] = RegistryFacet.termsBounds.selector;
        s[3] = RegistryFacet.reviewDeadline.selector;
        s[4] = SettlementFacet.rejectDelivery.selector;
        s[5] = SettlementFacet.requestRevision.selector;
        s[6] = AcceptanceFacet.settleLapsedReview.selector;
        s[7] = RegistryFacet.MAX_SUBMISSION_WINNERS.selector;
        s[8] = SettlementFacet.releaseClaim.selector;
        s[9] = RegistryFacet.isSettling.selector;
        s[10] = RegistryFacet.getTaskClock.selector;
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

    /// @dev rev025: owner-configurable feedback values and the requester agent binding.
    function feedbackFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = _concat(feedbackFacetSelectorsThroughRev026(), feedbackFacetSelectorsAddedRev027());
    }

    /// @dev rev027: the worker agent binding view.
    function feedbackFacetSelectorsAddedRev027() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = FeedbackFacet.workerAgentOf.selector;
    }

    /// @dev The FeedbackFacet selector set rev025 Added, Replaced by the rev027 step.
    function feedbackFacetSelectorsThroughRev026() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = FeedbackFacet.setFeedbackValue.selector;
        s[1] = FeedbackFacet.feedbackValue.selector;
        s[2] = FeedbackFacet.requesterAgentOf.selector;
    }

    /// @dev rev027: projects, with the relayed fund and claim entries of the funding pool contract.
    ///      Every ProjectFacet selector is new in rev027 except the ones rev029 Adds (raiseGrantCap, lowerGrantCap,
    ///      setGrantLimits, getGrantLimits).
    function projectFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](30);
        bytes4[] memory ownerSelectors = projectOwnerSelectorsRev029();
        for (uint256 i; i < ownerSelectors.length; ++i) {
            s[25 + i] = ownerSelectors[i];
        }
        s[0] = ProjectFacet.createProject.selector;
        s[1] = ProjectFacet.projectPoolId.selector;
        s[2] = ProjectFacet.closeProject.selector;
        s[3] = ProjectFacet.createProjectTask.selector;
        s[4] = ProjectFacet.getProject.selector;
        s[5] = ProjectFacet.projectOf.selector;
        s[6] = ProjectFacet.taskCreatedBy.selector;
        s[7] = ProjectFacet.projectTaskCount.selector;
        s[8] = ProjectFacet.projectTasks.selector;
        s[9] = ProjectFacet.projectCount.selector;
        s[10] = ProjectFacet.grantOperator.selector;
        s[11] = ProjectFacet.acceptGrant.selector;
        s[12] = ProjectFacet.revokeOperator.selector;
        s[13] = ProjectFacet.getGrant.selector;
        s[14] = ProjectFacet.taskOperator.selector;
        s[15] = ProjectFacet.drawTopUp.selector;
        s[16] = ProjectFacet.initFundingPool.selector;
        s[17] = ProjectFacet.fundingPool.selector;
        s[18] = ProjectFacet.fund.selector;
        s[19] = ProjectFacet.claim.selector;
        s[20] = ProjectFacet.refundProjectTask.selector;
        s[21] = ProjectFacet.raiseGrantCap.selector;
        s[22] = ProjectFacet.lowerGrantCap.selector;
        s[23] = ProjectFacet.setGrantLimits.selector;
        s[24] = ProjectFacet.getGrantLimits.selector;
    }

    /// @dev rev028: every selector rev028 Adds.
    function selectorsAddedRev028() internal pure returns (bytes4[] memory s) {
        s = _concat(_concat(hookDispatchFacetSelectors(), hooksV2FacetSelectors()), projectSelectorsAddedRev028());
    }

    /// @dev rev028: acceptGrant gained the terms hash argument. The new selector is an Add and the
    ///      rev027 selector is Removed, since a Replace of a selector the diamond does not route
    ///      reverts FunctionNotFound and the old selector would otherwise stay routed.
    function projectSelectorsAddedRev028() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ProjectFacet.acceptGrant.selector;
    }

    /// @dev rev027: the ProjectFacet selectors as rev027 routed them, with acceptGrant(uint256).
    function projectFacetSelectorsRev027() internal pure returns (bytes4[] memory s) {
        s = projectFacetSelectorsRev028Routed();
        bytes4 current = ProjectFacet.acceptGrant.selector;
        for (uint256 i; i < s.length; i++) {
            if (s[i] == current) {
                s[i] = acceptGrantSelectorRev027();
                return s;
            }
        }
        revert("acceptGrant selector missing");
    }

    /// @dev rev028: the acceptGrant(uint256) selector rev027 routes and rev028 removes.
    function acceptGrantSelectorRev027() internal pure returns (bytes4) {
        return bytes4(keccak256("acceptGrant(uint256)"));
    }

    /// @dev rev028: the ProjectFacet selectors a rev027 diamond already routes, for a Replace.
    function projectFacetSelectorsRev027Routed() internal pure returns (bytes4[] memory s) {
        bytes4[] memory all = projectFacetSelectorsRev028Routed();
        s = new bytes4[](all.length - 1);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i] == ProjectFacet.acceptGrant.selector) continue;
            s[n++] = all[i];
        }
    }

    /// @dev rev029: the ProjectFacet selectors rev029 Adds. raiseGrantCap stays first: the upgrade
    ///      script and its resume check test routing against it.
    function projectSelectorsAddedRev029() internal pure returns (bytes4[] memory s) {
        bytes4[] memory owner = projectOwnerSelectorsRev029();
        s = new bytes4[](4 + owner.length);
        s[0] = ProjectFacet.raiseGrantCap.selector;
        s[1] = ProjectFacet.lowerGrantCap.selector;
        s[2] = ProjectFacet.setGrantLimits.selector;
        s[3] = ProjectFacet.getGrantLimits.selector;
        for (uint256 i; i < owner.length; ++i) {
            s[4 + i] = owner[i];
        }
    }

    /// @dev rev029: owner transfer and end-date extension. Every selector is new.
    function projectOwnerSelectorsRev029() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = ProjectFacet.proposeProjectOwner.selector;
        s[1] = ProjectFacet.cancelProjectOwner.selector;
        s[2] = ProjectFacet.acceptProjectOwner.selector;
        s[3] = ProjectFacet.extendProject.selector;
        s[4] = ProjectFacet.pendingProjectOwner.selector;
    }

    /// @dev rev029: every selector rev029 Adds.
    function selectorsAddedRev029() internal pure returns (bytes4[] memory s) {
        s = projectSelectorsAddedRev029();
    }

    /// @dev rev030: every selector rev030 Adds.
    function selectorsAddedRev030() internal pure returns (bytes4[] memory s) {
        s = adminFacetSelectorsAddedRev030();
    }

    /// @dev rev029: the ProjectFacet selectors a rev028 diamond already routes, for a Replace.
    function projectFacetSelectorsRev028Routed() internal pure returns (bytes4[] memory s) {
        bytes4[] memory all = projectFacetSelectors();
        bytes4[] memory added = projectSelectorsAddedRev029();
        s = new bytes4[](all.length - added.length);
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            bool isNew;
            for (uint256 j; j < added.length; ++j) {
                if (all[i] == added[j]) isNew = true;
            }
            if (!isNew) s[n++] = all[i];
        }
    }

    /// @dev The internal hook dispatch, callable only by the diamond itself. Every selector is new in
    ///      rev028; rev030 drops hookCheckCompleteV1 (hookDispatchFacetSelectorsThroughRev029).
    function hookDispatchFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[6] = HookDispatchFacet.hookCall.selector;
        s[0] = HookDispatchFacet.hookAttach.selector;
        s[1] = HookDispatchFacet.hookReadManifest.selector;
        s[2] = HookDispatchFacet.hookBefore.selector;
        s[3] = HookDispatchFacet.hookObserve.selector;
        s[4] = HookDispatchFacet.hookAcceptV2.selector;
        s[5] = HookDispatchFacet.hookSettle.selector;
    }

    /// @dev The HookDispatchFacet selector set as rev028 added it and rev029 left it: today's set
    ///      plus the V1 checkComplete dispatch. The rev028 step Adds it and the rev030 step
    ///      Removes hookCheckCompleteV1 from it.
    function hookDispatchFacetSelectorsThroughRev029() internal pure returns (bytes4[] memory s) {
        s = _concat(hookDispatchFacetSelectors(), _single(HOOK_CHECK_COMPLETE_V1));
    }

    function _single(bytes4 sel) private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = sel;
    }

    /// @dev rev028: Task Hook V2 views, owner settings, per-action data and the settlement record.
    ///      Every selector is new in rev028.
    function hooksV2FacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[11] = HooksV2Facet.callTaskHook.selector;
        s[12] = HooksV2Facet.taskCallerRoles.selector;
        s[0] = HooksV2Facet.getTaskHooksV2.selector;
        s[1] = HooksV2Facet.getTaskHookVersion.selector;
        s[2] = HooksV2Facet.getTaskSettlement.selector;
        s[3] = HooksV2Facet.getDefaultHooksV2.selector;
        s[4] = HooksV2Facet.hookCapabilityGas.selector;
        s[5] = HooksV2Facet.maxHookFeeBps.selector;
        s[6] = HooksV2Facet.hookCallSeq.selector;
        s[7] = HooksV2Facet.setDefaultHooksV2.selector;
        s[8] = HooksV2Facet.setHookCapabilityGas.selector;
        s[9] = HooksV2Facet.setMaxHookFeeBps.selector;
        s[10] = HooksV2Facet.withActionData.selector;
    }
}
