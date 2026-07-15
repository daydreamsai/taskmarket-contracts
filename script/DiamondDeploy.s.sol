// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Diamond } from "../src/Diamond.sol";
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

/// @title DiamondDeploy — deploy TaskMarket Diamond proxy + all facets
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — deployer/owner key
///      FORGE_USDC_TOKEN_ADDRESS       — USDC token on target chain
///      FORGE_FEE_RECIPIENT_ADDRESS    — address to receive platform fees
///      FORGE_DEFAULT_PLATFORM_FEE_BPS — default fee in bps (e.g. 500 = 5%); must be <= 10000
/// @dev Optional env vars:
///      FORGE_PGTR_FORWARDER              — if set, registers the PGTR forwarder via addForwarder
///      FORGE_ERC8004_REPUTATION_REGISTRY — if set, registers the reputation registry via setReputationRegistry
contract DiamondDeploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address usdc = vm.envAddress("FORGE_USDC_TOKEN_ADDRESS");
        address feeRecipient = vm.envAddress("FORGE_FEE_RECIPIENT_ADDRESS");
        uint256 feeBpsRaw = vm.envUint("FORGE_DEFAULT_PLATFORM_FEE_BPS");
        require(feeBpsRaw <= 10_000, "FORGE_DEFAULT_PLATFORM_FEE_BPS exceeds 10000");
        uint16 feeBps = uint16(feeBpsRaw);

        vm.startBroadcast(deployerKey);

        // 1. Deploy all facet implementations
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        AdminFacet adminFacet = new AdminFacet();
        CoreFacet coreFacet = new CoreFacet();
        AuctionFacet auctionFacet = new AuctionFacet();
        AcceptanceFacet acceptFacet = new AcceptanceFacet();
        EvaluatorFacet evalFacet = new EvaluatorFacet();
        RatingFacet ratingFacet = new RatingFacet();
        RegistryFacet regFacet = new RegistryFacet();

        // 2. Build FacetCut array
        IDiamondCut.FacetCut[] memory cuts = _buildCuts(
            address(cutFacet),
            address(loupeFacet),
            address(adminFacet),
            address(coreFacet),
            address(auctionFacet),
            address(acceptFacet),
            address(evalFacet),
            address(ratingFacet),
            address(regFacet)
        );

        // 3. Encode initialize call (AdminFacet.initialize is delegatecalled once)
        bytes memory initData = abi.encodeCall(AdminFacet.initialize, (usdc, feeRecipient, feeBps));

        // 4. Deploy Diamond
        Diamond diamond = new Diamond(deployer, cuts, address(adminFacet), initData);

        // 5. Register optional PGTR forwarder and reputation registry
        address forwarder = vm.envOr("FORGE_PGTR_FORWARDER", address(0));
        if (forwarder != address(0)) {
            AdminFacet(address(diamond)).addForwarder(forwarder);
        }

        address reputationRegistry = vm.envOr("FORGE_ERC8004_REPUTATION_REGISTRY", address(0));
        if (reputationRegistry != address(0)) {
            AdminFacet(address(diamond)).setReputationRegistry(reputationRegistry);
        }

        vm.stopBroadcast();

        if (forwarder == address(0)) {
            console.log("WARN: no FORGE_PGTR_FORWARDER set; run addForwarder before task creation");
        }

        console.log("Diamond deployed at:", address(diamond));
        console.log("DiamondCutFacet:    ", address(cutFacet));
        console.log("DiamondLoupeFacet:  ", address(loupeFacet));
        console.log("AdminFacet:         ", address(adminFacet));
        console.log("CoreFacet:          ", address(coreFacet));
        console.log("AuctionFacet:       ", address(auctionFacet));
        console.log("AcceptanceFacet:    ", address(acceptFacet));
        console.log("EvaluatorFacet:     ", address(evalFacet));
        console.log("RatingFacet:        ", address(ratingFacet));
        console.log("RegistryFacet:      ", address(regFacet));
    }

    function _buildCuts(
        address cut,
        address loupe,
        address admin,
        address core,
        address auction,
        address accept,
        address eval,
        address rating,
        address registry
    ) internal pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](9);
        cuts[0] = IDiamondCut.FacetCut(cut, IDiamondCut.FacetCutAction.Add, _cutFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(loupe, IDiamondCut.FacetCutAction.Add, _loupeFacetSelectors());
        cuts[2] = IDiamondCut.FacetCut(admin, IDiamondCut.FacetCutAction.Add, _adminFacetSelectors());
        cuts[3] = IDiamondCut.FacetCut(core, IDiamondCut.FacetCutAction.Add, _coreFacetSelectors());
        cuts[4] = IDiamondCut.FacetCut(auction, IDiamondCut.FacetCutAction.Add, _auctionFacetSelectors());
        cuts[5] = IDiamondCut.FacetCut(accept, IDiamondCut.FacetCutAction.Add, _acceptFacetSelectors());
        cuts[6] = IDiamondCut.FacetCut(eval, IDiamondCut.FacetCutAction.Add, _evalFacetSelectors());
        cuts[7] = IDiamondCut.FacetCut(rating, IDiamondCut.FacetCutAction.Add, _ratingFacetSelectors());
        cuts[8] = IDiamondCut.FacetCut(registry, IDiamondCut.FacetCutAction.Add, _registryFacetSelectors());
    }

    function _cutFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _loupeFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _adminFacetSelectors() internal pure returns (bytes4[] memory s) {
        // initialize is NOT included — it is called once via Diamond constructor _init delegatecall
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

    function _coreFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        // public constant getters — must use keccak256; .selector syntax does not apply to constants
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
        // Core task functions
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
        // Must stay in sync with DiamondFullUpgrade.s.sol's _coreAllSelectors(), the real
        // testnet/mainnet diamond's steady-state selector set.
        s[20] = CoreFacet.rejectSubmission.selector;
    }

    function _auctionFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = AuctionFacet.submitBid.selector;
        s[1] = AuctionFacet.selectLowestBidder.selector;
        s[2] = AuctionFacet.acceptAuction.selector;
    }

    function _acceptFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AcceptanceFacet.acceptSubmission.selector;
        s[1] = AcceptanceFacet.acceptSubmissions.selector;
    }

    function _evalFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = EvaluatorFacet.assignEvaluator.selector;
        s[1] = EvaluatorFacet.evaluate.selector;
        s[2] = EvaluatorFacet.appeal.selector;
        s[3] = EvaluatorFacet.finalizeVerdict.selector;
        s[4] = EvaluatorFacet.resolveDispute.selector;
        s[5] = EvaluatorFacet.evaluatorTimeout.selector;
    }

    function _ratingFacetSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = RatingFacet.rateTask.selector;
        s[1] = RatingFacet.getCredibility.selector;
        s[2] = RatingFacet.getAverageRating.selector;
    }

    function _registryFacetSelectors() internal pure returns (bytes4[] memory s) {
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
}
