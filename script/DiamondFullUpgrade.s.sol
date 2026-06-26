// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
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
contract DiamondFullUpgrade is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

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

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](9);

        // DiamondCutFacet
        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = DiamondCutFacet.diamondCut.selector;
        cuts[0] = IDiamondCut.FacetCut(cutFacet, IDiamondCut.FacetCutAction.Replace, cutSelectors);

        // DiamondLoupeFacet
        bytes4[] memory loupeSelectors = new bytes4[](5);
        loupeSelectors[0] = DiamondLoupeFacet.facets.selector;
        loupeSelectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSelectors[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSelectors[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSelectors[4] = DiamondLoupeFacet.supportsInterface.selector;
        cuts[1] = IDiamondCut.FacetCut(loupeFacet, IDiamondCut.FacetCutAction.Replace, loupeSelectors);

        // AdminFacet
        bytes4[] memory adminSelectors = new bytes4[](13);
        adminSelectors[0] = AdminFacet.paused.selector;
        adminSelectors[1] = AdminFacet.pause.selector;
        adminSelectors[2] = AdminFacet.unpause.selector;
        adminSelectors[3] = AdminFacet.transferOwnership.selector;
        adminSelectors[4] = AdminFacet.acceptOwnership.selector;
        adminSelectors[5] = AdminFacet.owner.selector;
        adminSelectors[6] = AdminFacet.pendingOwner.selector;
        adminSelectors[7] = AdminFacet.addForwarder.selector;
        adminSelectors[8] = AdminFacet.removeForwarder.selector;
        adminSelectors[9] = AdminFacet.isTrustedForwarder.selector;
        adminSelectors[10] = AdminFacet.setDefaultFeeBps.selector;
        adminSelectors[11] = AdminFacet.setFeeRecipient.selector;
        adminSelectors[12] = AdminFacet.setReputationRegistry.selector;
        cuts[2] = IDiamondCut.FacetCut(adminFacet, IDiamondCut.FacetCutAction.Replace, adminSelectors);

        // CoreFacet
        bytes4[] memory coreSelectors = new bytes4[](21);
        coreSelectors[0] = bytes4(keccak256("BOUNTY()"));
        coreSelectors[1] = bytes4(keccak256("CLAIM()"));
        coreSelectors[2] = bytes4(keccak256("PITCH()"));
        coreSelectors[3] = bytes4(keccak256("BENCHMARK()"));
        coreSelectors[4] = bytes4(keccak256("AUCTION()"));
        coreSelectors[5] = bytes4(keccak256("AUCTION_DUTCH()"));
        coreSelectors[6] = bytes4(keccak256("AUCTION_ENGLISH()"));
        coreSelectors[7] = bytes4(keccak256("AUCTION_REVERSE_DUTCH()"));
        coreSelectors[8] = bytes4(keccak256("AUCTION_REVERSE_ENGLISH()"));
        coreSelectors[9] = bytes4(keccak256("MAX_BIDS_PER_TASK()"));
        coreSelectors[10] = CoreFacet.createTask.selector;
        coreSelectors[11] = CoreFacet.claimTask.selector;
        coreSelectors[12] = CoreFacet.selectWorker.selector;
        coreSelectors[13] = CoreFacet.submitPitch.selector;
        coreSelectors[14] = CoreFacet.submitProof.selector;
        coreSelectors[15] = CoreFacet.submitWork.selector;
        coreSelectors[16] = CoreFacet.rejectSubmission.selector;
        coreSelectors[17] = CoreFacet.forfeitAndReopen.selector;
        coreSelectors[18] = CoreFacet.cancelTask.selector;
        coreSelectors[19] = CoreFacet.updateTask.selector;
        coreSelectors[20] = CoreFacet.refundExpired.selector;
        cuts[3] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, coreSelectors);

        // AuctionFacet
        bytes4[] memory auctionSelectors = new bytes4[](3);
        auctionSelectors[0] = AuctionFacet.submitBid.selector;
        auctionSelectors[1] = AuctionFacet.selectLowestBidder.selector;
        auctionSelectors[2] = AuctionFacet.acceptAuction.selector;
        cuts[4] = IDiamondCut.FacetCut(auctionFacet, IDiamondCut.FacetCutAction.Replace, auctionSelectors);

        // AcceptanceFacet
        bytes4[] memory acceptSelectors = new bytes4[](2);
        acceptSelectors[0] = AcceptanceFacet.acceptSubmission.selector;
        acceptSelectors[1] = AcceptanceFacet.acceptSubmissions.selector;
        cuts[5] = IDiamondCut.FacetCut(acceptFacet, IDiamondCut.FacetCutAction.Replace, acceptSelectors);

        // EvaluatorFacet
        bytes4[] memory evalSelectors = new bytes4[](6);
        evalSelectors[0] = EvaluatorFacet.assignEvaluator.selector;
        evalSelectors[1] = EvaluatorFacet.evaluate.selector;
        evalSelectors[2] = EvaluatorFacet.appeal.selector;
        evalSelectors[3] = EvaluatorFacet.finalizeVerdict.selector;
        evalSelectors[4] = EvaluatorFacet.resolveDispute.selector;
        evalSelectors[5] = EvaluatorFacet.evaluatorTimeout.selector;
        cuts[6] = IDiamondCut.FacetCut(evalFacet, IDiamondCut.FacetCutAction.Replace, evalSelectors);

        // RatingFacet
        bytes4[] memory ratingSelectors = new bytes4[](3);
        ratingSelectors[0] = RatingFacet.rateTask.selector;
        ratingSelectors[1] = RatingFacet.getCredibility.selector;
        ratingSelectors[2] = RatingFacet.getAverageRating.selector;
        cuts[7] = IDiamondCut.FacetCut(ratingFacet, IDiamondCut.FacetCutAction.Replace, ratingSelectors);

        // RegistryFacet
        bytes4[] memory regSelectors = new bytes4[](21);
        regSelectors[0] = RegistryFacet.getTask.selector;
        regSelectors[1] = RegistryFacet.getWorkerStats.selector;
        regSelectors[2] = RegistryFacet.requesterNonce.selector;
        regSelectors[3] = RegistryFacet.getTaskState.selector;
        regSelectors[4] = RegistryFacet.getTaskContext.selector;
        regSelectors[5] = RegistryFacet.getTaskVerdict.selector;
        regSelectors[6] = RegistryFacet.evaluatorFor.selector;
        regSelectors[7] = RegistryFacet.taskMode.selector;
        regSelectors[8] = RegistryFacet.defaultFeeBps.selector;
        regSelectors[9] = RegistryFacet.feeRecipient.selector;
        regSelectors[10] = RegistryFacet.totalFeesCollected.selector;
        regSelectors[11] = RegistryFacet.feeForTask.selector;
        regSelectors[12] = RegistryFacet.reputationRegistry.selector;
        regSelectors[13] = RegistryFacet.getTaskEvaluatorConfig.selector;
        regSelectors[14] = RegistryFacet.getTaskAuctionConfig.selector;
        regSelectors[15] = RegistryFacet.getTaskMetadata.selector;
        regSelectors[16] = RegistryFacet.getTaskPitchConfig.selector;
        regSelectors[17] = RegistryFacet.getBids.selector;
        regSelectors[18] = RegistryFacet.usdcToken.selector;
        regSelectors[19] = RegistryFacet.taskPitchHashes.selector;
        regSelectors[20] = RegistryFacet.taskProofHashes.selector;
        cuts[8] = IDiamondCut.FacetCut(regFacet, IDiamondCut.FacetCutAction.Replace, regSelectors);

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

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
}
