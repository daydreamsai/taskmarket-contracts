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
/// @dev Selector-change handling (submission-integrity upgrade):
///      Four function signatures gained a requesterAgentId parameter and changed selectors.
///      A new taskSubmissionHashes getter was added to RegistryFacet.
///      If the diamond still has the OLD selectors the script removes them and adds the new
///      ones atomically. If the diamond is already on the new selectors it uses Replace.
///      Detection is via the loupe: presence of cancelTask(bytes32) means old state.
contract DiamondFullUpgrade is Script {
    // Old selectors that were changed in the submission-integrity upgrade.
    bytes4 private constant OLD_CANCEL_TASK = bytes4(keccak256("cancelTask(bytes32)"));
    bytes4 private constant OLD_REFUND_EXPIRED = bytes4(keccak256("refundExpired(bytes32)"));
    bytes4 private constant OLD_ACCEPT_SUBMISSION = bytes4(keccak256("acceptSubmission(bytes32,address,bytes32)"));
    bytes4 private constant OLD_ACCEPT_SUBMISSIONS =
        bytes4(keccak256("acceptSubmissions(bytes32,address[],uint16[],bytes32[])"));

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        // Detect whether this diamond still has the old cancelTask(bytes32) selector.
        // If it does, we must Remove the old selectors and Add the new ones.
        // If not, the diamond is already on new selectors and we can Replace directly.
        bool needsMigration = IDiamondLoupe(diamond).facetAddress(OLD_CANCEL_TASK) != address(0);

        vm.startBroadcast(ownerKey);

        // Deploy fresh implementations for all facets
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

    /// @dev Used when the diamond is in the pre-submission-integrity state.
    ///      Removes old changed selectors atomically with the Replace of everything else.
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
        // DiamondCutFacet, DiamondLoupeFacet, AdminFacet (Replace) = 3
        // Remove old Core changed selectors + Replace unchanged Core + Add new Core changed = 3
        // AuctionFacet (Replace) = 1
        // Remove old Acceptance changed + Add new Acceptance changed = 2
        // EvaluatorFacet, RatingFacet (Replace) = 2
        // Replace existing RegistryFacet selectors + Add taskSubmissionHashes = 2
        // Total = 13
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](13);

        cuts[0] = _replaceCut(cutFacet, _cutSelectors());
        cuts[1] = _replaceCut(loupeFacet, _loupeSelectors());
        cuts[2] = _replaceCut(adminFacet, _adminSelectors());

        // Remove old CoreFacet selectors that changed (cancelTask, refundExpired)
        bytes4[] memory oldCoreChanged = new bytes4[](2);
        oldCoreChanged[0] = OLD_CANCEL_TASK;
        oldCoreChanged[1] = OLD_REFUND_EXPIRED;
        cuts[3] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, oldCoreChanged);

        // Replace the 19 CoreFacet selectors that did not change
        cuts[4] = _replaceCut(coreFacet, _coreUnchangedSelectors());

        // Add the 2 new CoreFacet selectors
        bytes4[] memory newCoreChanged = new bytes4[](2);
        newCoreChanged[0] = CoreFacet.cancelTask.selector;
        newCoreChanged[1] = CoreFacet.refundExpired.selector;
        cuts[5] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Add, newCoreChanged);

        cuts[6] = _replaceCut(auctionFacet, _auctionSelectors());

        // Remove old AcceptanceFacet selectors that changed
        bytes4[] memory oldAcceptChanged = new bytes4[](2);
        oldAcceptChanged[0] = OLD_ACCEPT_SUBMISSION;
        oldAcceptChanged[1] = OLD_ACCEPT_SUBMISSIONS;
        cuts[7] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, oldAcceptChanged);

        // Add new AcceptanceFacet selectors
        bytes4[] memory newAcceptChanged = new bytes4[](2);
        newAcceptChanged[0] = AcceptanceFacet.acceptSubmission.selector;
        newAcceptChanged[1] = AcceptanceFacet.acceptSubmissions.selector;
        cuts[8] = IDiamondCut.FacetCut(acceptFacet, IDiamondCut.FacetCutAction.Add, newAcceptChanged);

        cuts[9] = _replaceCut(evalFacet, _evalSelectors());
        cuts[10] = _replaceCut(ratingFacet, _ratingSelectors());

        // Replace the 21 RegistryFacet selectors that already exist
        cuts[11] = _replaceCut(regFacet, _regExistingSelectors());

        // Add the new taskSubmissionHashes getter
        bytes4[] memory newRegSelector = new bytes4[](1);
        newRegSelector[0] = RegistryFacet.taskSubmissionHashes.selector;
        cuts[12] = IDiamondCut.FacetCut(regFacet, IDiamondCut.FacetCutAction.Add, newRegSelector);

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        console.log("Migration path: removed old selectors, added new selectors.");
    }

    /// @dev Used when the diamond is already on new selectors — Replace everything.
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
        cuts[2] = _replaceCut(adminFacet, _adminSelectors());
        cuts[3] = _replaceCut(coreFacet, _coreAllSelectors());
        cuts[4] = _replaceCut(auctionFacet, _auctionSelectors());

        bytes4[] memory acceptSelectors = new bytes4[](2);
        acceptSelectors[0] = AcceptanceFacet.acceptSubmission.selector;
        acceptSelectors[1] = AcceptanceFacet.acceptSubmissions.selector;
        cuts[5] = _replaceCut(acceptFacet, acceptSelectors);

        cuts[6] = _replaceCut(evalFacet, _evalSelectors());
        cuts[7] = _replaceCut(ratingFacet, _ratingSelectors());
        cuts[8] = _replaceCut(regFacet, _regAllSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        console.log("Replace path: all selectors already on new signatures.");
    }

    function _replaceCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, selectors);
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

    function _adminSelectors() private pure returns (bytes4[] memory s) {
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

    /// @dev The 19 CoreFacet selectors whose signatures did NOT change.
    ///      cancelTask and refundExpired are excluded — they changed selectors.
    function _coreUnchangedSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](19);
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
    }

    /// @dev All 21 CoreFacet selectors — used in the steady-state Replace path.
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

    /// @dev The 21 RegistryFacet selectors that existed before this upgrade.
    ///      Used in the migration path to Replace existing selectors before Adding taskSubmissionHashes.
    function _regExistingSelectors() private pure returns (bytes4[] memory s) {
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

    /// @dev All 22 RegistryFacet selectors — used in the steady-state Replace path.
    function _regAllSelectors() private pure returns (bytes4[] memory s) {
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
}
