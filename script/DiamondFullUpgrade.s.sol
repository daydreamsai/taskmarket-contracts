// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { AuctionFacet } from "../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";

/// @title DiamondFullUpgrade — replace all facets on an existing Diamond proxy in one tx
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage:
///      make upgrade testnet
///      make upgrade mainnet
///
/// @dev Three upgrade paths — detected automatically via the loupe:
///
///      Path A (_runWithMigration): pre-submission-integrity diamond (has old cancelTask(bytes32)).
///        Removes old selector set and adds new ones atomically, plus all rev010 additions.
///
///      Path B (_runRev010Migration): post-submission-integrity, pre-rev010 diamond
///        (no old cancelTask, but setDefaultHooks is absent). This is the common testnet state
///        when upgrading from any rev007–rev009 deployment to the hook-enabled contracts.
///        Removes old createTask, adds new one; adds new AdminFacet and RegistryFacet functions.
///        Also removes PREV_ACCEPT_SUBMISSIONS if still present.
///
///      Path C (_runReplace): steady-state (post-rev010). All current selectors exist.
///        Pure Replace — no Remove or Add needed.
contract DiamondFullUpgrade is Script {
    // rev007 selectors — present on pre-submission-integrity diamonds.
    bytes4 private constant OLD_CANCEL_TASK = bytes4(keccak256("cancelTask(bytes32)"));
    bytes4 private constant OLD_REFUND_EXPIRED = bytes4(keccak256("refundExpired(bytes32)"));
    bytes4 private constant OLD_ACCEPT_SUBMISSION = bytes4(keccak256("acceptSubmission(bytes32,address,bytes32)"));
    bytes4 private constant OLD_ACCEPT_SUBMISSIONS =
        bytes4(keccak256("acceptSubmissions(bytes32,address[],uint16[],bytes32[])"));
    // rev009 selector — present on rev007–rev008 diamonds (5-param acceptSubmissions not yet added).
    bytes4 private constant PREV_ACCEPT_SUBMISSIONS =
        bytes4(keccak256("acceptSubmissions(bytes32,address[],uint16[],uint256)"));
    // rev010 selector — old createTask before hook config struct refactor.
    bytes4 private constant OLD_CREATE_TASK = bytes4(
        keccak256("createTask(uint256,uint256,bytes4,uint256,uint256,bytes32,string,bytes4,address,bytes32[],bytes)")
    );

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        // Path A: very old diamond — still has pre-submission-integrity selectors.
        bool needsMigration = IDiamondLoupe(diamond).facetAddress(OLD_CANCEL_TASK) != address(0);
        // Path B: post-submission-integrity but pre-rev010 — setDefaultHooks not yet added.
        bool needsRev010Migration =
            !needsMigration && IDiamondLoupe(diamond).facetAddress(AdminFacet.setDefaultHooks.selector) == address(0);
        // Rev009 leftover: PREV_ACCEPT_SUBMISSIONS may still be present on some diamonds.
        bool hasPrevAcceptSubs = IDiamondLoupe(diamond).facetAddress(PREV_ACCEPT_SUBMISSIONS) != address(0);

        vm.startBroadcast(ownerKey);

        address cutFacet = address(new DiamondCutFacet());
        address loupeFacet = address(new DiamondLoupeFacet());
        address adminFacet = address(new AdminFacet());
        address coreFacet = address(new CoreFacet());
        address auctionFacet = address(new AuctionFacet());
        address acceptFacet = address(new AcceptanceFacet());
        address evalFacet = address(new EvaluatorFacet());
        address ratingFacet = address(new RatingFacet());
        address regFacet = address(new RegistryFacet());

        if (needsMigration) {
            _runWithMigration(
                diamond,
                cutFacet,
                loupeFacet,
                adminFacet,
                coreFacet,
                auctionFacet,
                acceptFacet,
                evalFacet,
                ratingFacet,
                regFacet
            );
        } else if (needsRev010Migration) {
            _runRev010Migration(
                diamond,
                cutFacet,
                loupeFacet,
                adminFacet,
                coreFacet,
                auctionFacet,
                acceptFacet,
                evalFacet,
                ratingFacet,
                regFacet,
                hasPrevAcceptSubs
            );
        } else {
            _runReplace(
                diamond,
                cutFacet,
                loupeFacet,
                adminFacet,
                coreFacet,
                auctionFacet,
                acceptFacet,
                evalFacet,
                ratingFacet,
                regFacet
            );
        }

        vm.stopBroadcast();

        console.log("Full upgrade complete. Diamond:", diamond);
        console.log("DiamondCutFacet:  ", cutFacet);
        console.log("DiamondLoupeFacet:", loupeFacet);
        console.log("AdminFacet:       ", adminFacet);
        console.log("CoreFacet:        ", coreFacet);
        console.log("AuctionFacet:     ", auctionFacet);
        console.log("AcceptanceFacet:  ", acceptFacet);
        console.log("EvaluatorFacet:   ", evalFacet);
        console.log("RatingFacet:      ", ratingFacet);
        console.log("RegistryFacet:    ", regFacet);
    }

    // -------------------------------------------------------------------------
    // Path A: pre-submission-integrity diamonds
    // -------------------------------------------------------------------------

    /// @dev Removes rev007 old selectors and adds new ones, plus all rev010 additions.
    ///      14 cuts total.
    function _runWithMigration(
        address diamond,
        address cutFacet,
        address loupeFacet,
        address adminFacet,
        address coreFacet,
        address auctionFacet,
        address acceptFacet,
        address evalFacet,
        address ratingFacet,
        address regFacet
    ) private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](14);

        cuts[0] = _replaceCut(cutFacet, _cutSelectors());
        cuts[1] = _replaceCut(loupeFacet, _loupeSelectors());

        // AdminFacet: Replace 13 existing, Add 2 new (setDefaultHooks, getDefaultHooks).
        cuts[2] = _replaceCut(adminFacet, _adminExistingSelectors());
        cuts[3] = _addCut(adminFacet, _adminNewSelectors());

        // CoreFacet: Remove 3 old changed selectors, Replace 18 unchanged, Add 3 new.
        bytes4[] memory oldCoreChanged = new bytes4[](3);
        oldCoreChanged[0] = OLD_CANCEL_TASK;
        oldCoreChanged[1] = OLD_REFUND_EXPIRED;
        oldCoreChanged[2] = OLD_CREATE_TASK;
        cuts[4] = _removeCut(oldCoreChanged);
        cuts[5] = _replaceCut(coreFacet, _coreRevIntegrityUnchangedSelectors());
        bytes4[] memory newCoreChanged = new bytes4[](3);
        newCoreChanged[0] = CoreFacet.cancelTask.selector;
        newCoreChanged[1] = CoreFacet.refundExpired.selector;
        newCoreChanged[2] = CoreFacet.createTask.selector;
        cuts[6] = _addCut(coreFacet, newCoreChanged);

        cuts[7] = _replaceCut(auctionFacet, _auctionSelectors());

        // AcceptanceFacet: Remove old 2 selectors, Add new 2.
        bytes4[] memory oldAcceptChanged = new bytes4[](2);
        oldAcceptChanged[0] = OLD_ACCEPT_SUBMISSION;
        oldAcceptChanged[1] = OLD_ACCEPT_SUBMISSIONS;
        cuts[8] = _removeCut(oldAcceptChanged);
        bytes4[] memory newAcceptChanged = new bytes4[](2);
        newAcceptChanged[0] = AcceptanceFacet.acceptSubmission.selector;
        newAcceptChanged[1] = AcceptanceFacet.acceptSubmissions.selector;
        cuts[9] = _addCut(acceptFacet, newAcceptChanged);

        cuts[10] = _replaceCut(evalFacet, _evalSelectors());
        cuts[11] = _replaceCut(ratingFacet, _ratingSelectors());

        // RegistryFacet: Replace 21 pre-sub-integrity selectors, Add taskSubmissionHashes + 7 new.
        cuts[12] = _replaceCut(regFacet, _regPreIntegritySelectors());
        cuts[13] = _addCut(regFacet, _regAllNewSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        console.log("Path A: removed pre-submission-integrity selectors, applied rev010 additions.");
    }

    // -------------------------------------------------------------------------
    // Path B: post-submission-integrity, pre-rev010 diamonds (common testnet state)
    // -------------------------------------------------------------------------

    /// @dev Removes old createTask selector, adds new one; adds new AdminFacet and RegistryFacet
    ///      functions; handles PREV_ACCEPT_SUBMISSIONS if still present.
    ///      13 cuts (hasPrevAcceptSubs=false) or 15 cuts (hasPrevAcceptSubs=true).
    function _runRev010Migration(
        address diamond,
        address cutFacet,
        address loupeFacet,
        address adminFacet,
        address coreFacet,
        address auctionFacet,
        address acceptFacet,
        address evalFacet,
        address ratingFacet,
        address regFacet,
        bool hasPrevAcceptSubs
    ) private {
        uint256 cutCount = hasPrevAcceptSubs ? 15 : 13;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](cutCount);
        uint256 i = 0;

        cuts[i++] = _replaceCut(cutFacet, _cutSelectors());
        cuts[i++] = _replaceCut(loupeFacet, _loupeSelectors());

        // AdminFacet: Replace 13 existing, Add 2 new.
        cuts[i++] = _replaceCut(adminFacet, _adminExistingSelectors());
        cuts[i++] = _addCut(adminFacet, _adminNewSelectors());

        // CoreFacet: Remove old createTask, Replace 20 existing (without createTask), Add new createTask.
        bytes4[] memory oldCreateTask = new bytes4[](1);
        oldCreateTask[0] = OLD_CREATE_TASK;
        cuts[i++] = _removeCut(oldCreateTask);
        cuts[i++] = _replaceCut(coreFacet, _coreExistingSelectors());
        bytes4[] memory newCreateTask = new bytes4[](1);
        newCreateTask[0] = CoreFacet.createTask.selector;
        cuts[i++] = _addCut(coreFacet, newCreateTask);

        cuts[i++] = _replaceCut(auctionFacet, _auctionSelectors());

        if (hasPrevAcceptSubs) {
            // Replace acceptSubmission (selector unchanged), Remove PREV_ACCEPT_SUBMISSIONS, Add new acceptSubmissions.
            bytes4[] memory acceptUnchanged = new bytes4[](1);
            acceptUnchanged[0] = AcceptanceFacet.acceptSubmission.selector;
            cuts[i++] = _replaceCut(acceptFacet, acceptUnchanged);
            bytes4[] memory prevAccept = new bytes4[](1);
            prevAccept[0] = PREV_ACCEPT_SUBMISSIONS;
            cuts[i++] = _removeCut(prevAccept);
            bytes4[] memory newAcceptPlural = new bytes4[](1);
            newAcceptPlural[0] = AcceptanceFacet.acceptSubmissions.selector;
            cuts[i++] = _addCut(acceptFacet, newAcceptPlural);
        } else {
            // Both acceptance selectors are already at final signatures — Replace both together.
            bytes4[] memory acceptBoth = new bytes4[](2);
            acceptBoth[0] = AcceptanceFacet.acceptSubmission.selector;
            acceptBoth[1] = AcceptanceFacet.acceptSubmissions.selector;
            cuts[i++] = _replaceCut(acceptFacet, acceptBoth);
        }

        cuts[i++] = _replaceCut(evalFacet, _evalSelectors());
        cuts[i++] = _replaceCut(ratingFacet, _ratingSelectors());

        // RegistryFacet: Replace 22 existing (including taskSubmissionHashes), Add 7 new.
        cuts[i++] = _replaceCut(regFacet, _regRev009Selectors());
        cuts[i++] = _addCut(regFacet, _regRev010NewSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        console.log("Path B: applied rev010 migration (new createTask, admin hooks, registry views).");
    }

    // -------------------------------------------------------------------------
    // Path C: steady-state (post-rev010) — pure Replace
    // -------------------------------------------------------------------------

    /// @dev All selectors at current signatures — Replace everything in 9 cuts.
    function _runReplace(
        address diamond,
        address cutFacet,
        address loupeFacet,
        address adminFacet,
        address coreFacet,
        address auctionFacet,
        address acceptFacet,
        address evalFacet,
        address ratingFacet,
        address regFacet
    ) private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](9);

        cuts[0] = _replaceCut(cutFacet, _cutSelectors());
        cuts[1] = _replaceCut(loupeFacet, _loupeSelectors());
        cuts[2] = _replaceCut(adminFacet, _adminAllSelectors());
        cuts[3] = _replaceCut(coreFacet, _coreAllSelectors());
        cuts[4] = _replaceCut(auctionFacet, _auctionSelectors());
        cuts[5] = _replaceCut(acceptFacet, _acceptAllSelectors());
        cuts[6] = _replaceCut(evalFacet, _evalSelectors());
        cuts[7] = _replaceCut(ratingFacet, _ratingSelectors());
        cuts[8] = _replaceCut(regFacet, _regAllSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        console.log("Path C: steady-state replace, all facets updated in place.");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _replaceCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, selectors);
    }

    function _addCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, selectors);
    }

    function _removeCut(bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, selectors);
    }

    function _cutSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _loupeSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    /// @dev 13 AdminFacet selectors present before rev010.
    function _adminExistingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
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
    }

    /// @dev 2 new AdminFacet selectors added in rev010.
    function _adminNewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.setDefaultHooks.selector;
        s[1] = AdminFacet.getDefaultHooks.selector;
    }

    /// @dev All 15 AdminFacet selectors — used in steady-state Replace path.
    function _adminAllSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](15);
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
    }

    /// @dev 18 CoreFacet selectors unchanged across both rev007 and rev010.
    ///      Excludes cancelTask, refundExpired (changed in rev007) and createTask (changed in rev010).
    function _coreRevIntegrityUnchangedSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](18);
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
        s[10] = CoreFacet.claimTask.selector;
        s[11] = CoreFacet.selectWorker.selector;
        s[12] = CoreFacet.submitPitch.selector;
        s[13] = CoreFacet.submitProof.selector;
        s[14] = CoreFacet.submitWork.selector;
        s[15] = CoreFacet.forfeitAndReopen.selector;
        s[16] = CoreFacet.updateTask.selector;
        s[17] = CoreFacet.rejectSubmission.selector;
    }

    /// @dev 20 CoreFacet selectors present after rev007 but before rev010 (excludes createTask).
    ///      Used in the rev010 migration path Replace cut.
    function _coreExistingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
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
        s[10] = CoreFacet.claimTask.selector;
        s[11] = CoreFacet.selectWorker.selector;
        s[12] = CoreFacet.submitPitch.selector;
        s[13] = CoreFacet.submitProof.selector;
        s[14] = CoreFacet.submitWork.selector;
        s[15] = CoreFacet.forfeitAndReopen.selector;
        s[16] = CoreFacet.updateTask.selector;
        s[17] = CoreFacet.rejectSubmission.selector;
        s[18] = CoreFacet.cancelTask.selector;
        s[19] = CoreFacet.refundExpired.selector;
    }

    /// @dev All 21 CoreFacet selectors — used in steady-state Replace path.
    function _coreAllSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
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
        s[17] = CoreFacet.updateTask.selector;
        s[18] = CoreFacet.rejectSubmission.selector;
        s[19] = CoreFacet.cancelTask.selector;
        s[20] = CoreFacet.refundExpired.selector;
    }

    function _auctionSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = AuctionFacet.submitBid.selector;
        s[1] = AuctionFacet.selectLowestBidder.selector;
        s[2] = AuctionFacet.acceptAuction.selector;
    }

    /// @dev Both AcceptanceFacet selectors at current (post-rev009) signatures.
    function _acceptAllSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AcceptanceFacet.acceptSubmission.selector;
        s[1] = AcceptanceFacet.acceptSubmissions.selector;
    }

    function _evalSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = EvaluatorFacet.assignEvaluator.selector;
        s[1] = EvaluatorFacet.evaluate.selector;
        s[2] = EvaluatorFacet.appeal.selector;
        s[3] = EvaluatorFacet.finalizeVerdict.selector;
        s[4] = EvaluatorFacet.resolveDispute.selector;
        s[5] = EvaluatorFacet.evaluatorTimeout.selector;
    }

    function _ratingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = RatingFacet.rateTask.selector;
        s[1] = RatingFacet.getCredibility.selector;
        s[2] = RatingFacet.getAverageRating.selector;
    }

    /// @dev 21 RegistryFacet selectors present before the submission-integrity upgrade (rev007).
    function _regPreIntegritySelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
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
    }

    /// @dev 8 new RegistryFacet selectors added across rev007–rev010 (taskSubmissionHashes + 7 rev010 views).
    ///      Used in Path A to add everything new in one cut.
    function _regAllNewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = RegistryFacet.taskSubmissionHashes.selector;
        s[1] = RegistryFacet.hasWorkerRated.selector;
        s[2] = RegistryFacet.stakeForfeit.selector;
        s[3] = RegistryFacet.taskSubmissionHashExists.selector;
        s[4] = RegistryFacet.taskActiveSubmissionCount.selector;
        s[5] = RegistryFacet.taskHasSubmissions.selector;
        s[6] = RegistryFacet.taskRejectedWorkers.selector;
        s[7] = RegistryFacet.getTaskHooks.selector;
    }

    /// @dev 22 RegistryFacet selectors present after rev007 (includes taskSubmissionHashes).
    ///      Used in Path B as the Replace cut.
    function _regRev009Selectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](22);
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
    }

    /// @dev 7 new RegistryFacet selectors added in rev010.
    ///      Used in Path B as the Add cut.
    function _regRev010NewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = RegistryFacet.hasWorkerRated.selector;
        s[1] = RegistryFacet.stakeForfeit.selector;
        s[2] = RegistryFacet.taskSubmissionHashExists.selector;
        s[3] = RegistryFacet.taskActiveSubmissionCount.selector;
        s[4] = RegistryFacet.taskHasSubmissions.selector;
        s[5] = RegistryFacet.taskRejectedWorkers.selector;
        s[6] = RegistryFacet.getTaskHooks.selector;
    }

    /// @dev All 29 RegistryFacet selectors — used in steady-state Replace path.
    function _regAllSelectors() private pure returns (bytes4[] memory s) {
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
