// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { Diamond } from "../src/Diamond.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { WorkerFacet } from "../src/facets/WorkerFacet.sol";
import { ProjectFacet } from "../src/facets/ProjectFacet.sol";
import { AuctionFacet } from "../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { SettlementFacet } from "../src/facets/SettlementFacet.sol";
import { FeedbackFacet } from "../src/facets/FeedbackFacet.sol";
import { DeployTarget } from "./lib/DeployTarget.sol";
import { FacetSelectors } from "./lib/FacetSelectors.sol";

/// @title DiamondDeploy — deploy TaskMarket Diamond proxy + all facets
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — deployer/owner key
///      FORGE_USDC_TOKEN_ADDRESS       — USDC token on target chain
///      FORGE_FEE_RECIPIENT_ADDRESS    — address to receive platform fees
///      FORGE_DEFAULT_PLATFORM_FEE_BPS — default fee in bps (e.g. 500 = 5%); must be <= 10000
/// @dev Optional env vars:
///      FORGE_PGTR_FORWARDER              — if set, registers the PGTR forwarder via addForwarder
///      FORGE_ERC8004_REPUTATION_REGISTRY — if set, registers the reputation registry via setReputationRegistry
///      FORGE_MIN_FEEDBACK_GAS            — if set, the feedback gas floor passed to setMinFeedbackGas;
///                                          unset leaves the 450,000 default (script/tempo.sh
///                                          requires FORGE_MIN_FEEDBACK_GAS_TEMPO_* for Tempo)
///      FORGE_HOOK_GAS_STIPEND            — if set, the hook gas stipend passed to setHookGasStipend;
///                                          unset leaves the 1,000,000 default (script/tempo.sh
///                                          requires FORGE_HOOK_GAS_STIPEND_TEMPO_* for Tempo)
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

        // 4. Deploy Diamond with only the cut facet, then add the rest one facet per transaction.
        // A single constructor carrying every cut needs ~47M gas on Tempo, which caps a
        // transaction at 30M. AdminFacet's cut runs initialize.
        IDiamondCut.FacetCut[] memory first = new IDiamondCut.FacetCut[](1);
        first[0] = cuts[0];
        Diamond diamond = new Diamond(deployer, first, address(0), "");
        for (uint256 i = 1; i < cuts.length; i++) {
            IDiamondCut.FacetCut[] memory step = new IDiamondCut.FacetCut[](1);
            step[0] = cuts[i];
            bool isAdmin = cuts[i].facetAddress == address(adminFacet);
            IDiamondCut(address(diamond))
                .diamondCut(step, isAdmin ? address(adminFacet) : address(0), isAdmin ? initData : bytes(""));
        }

        // 5. Register optional PGTR forwarder and reputation registry
        address forwarder = vm.envOr("FORGE_PGTR_FORWARDER", address(0));
        if (forwarder != address(0)) {
            AdminFacet(address(diamond)).addForwarder(forwarder);
        }

        address reputationRegistry = vm.envOr("FORGE_ERC8004_REPUTATION_REGISTRY", address(0));
        if (reputationRegistry != address(0)) {
            AdminFacet(address(diamond)).setReputationRegistry(reputationRegistry);
        }

        // rev024: per-chain floor on the gas left before a swallowed giveFeedback call.
        uint256 feedbackGasFloor = vm.envOr("FORGE_MIN_FEEDBACK_GAS", uint256(0));
        if (feedbackGasFloor != 0) {
            AdminFacet(address(diamond)).setMinFeedbackGas(feedbackGasFloor);
        }

        // rev026: per-chain gas stipend forwarded to each hook call.
        uint256 hookStipend = vm.envOr("FORGE_HOOK_GAS_STIPEND", uint256(0));
        if (hookStipend != 0) {
            AdminFacet(address(diamond)).setHookGasStipend(hookStipend);
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
        console.log("SettlementFacet:    ", cuts[9].facetAddress);
        console.log("FeedbackFacet:      ", cuts[10].facetAddress);
        console.log("WorkerFacet:        ", cuts[11].facetAddress);
        console.log("ProjectFacet:       ", cuts[12].facetAddress);
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
    ) internal returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](13);
        cuts[0] = IDiamondCut.FacetCut(cut, IDiamondCut.FacetCutAction.Add, FacetSelectors.cutFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(loupe, IDiamondCut.FacetCutAction.Add, FacetSelectors.loupeFacetSelectors());
        cuts[2] = IDiamondCut.FacetCut(admin, IDiamondCut.FacetCutAction.Add, FacetSelectors.adminFacetSelectors());
        cuts[3] = IDiamondCut.FacetCut(core, IDiamondCut.FacetCutAction.Add, FacetSelectors.coreFacetSelectors());
        cuts[4] = IDiamondCut.FacetCut(auction, IDiamondCut.FacetCutAction.Add, FacetSelectors.auctionFacetSelectors());
        cuts[5] = IDiamondCut.FacetCut(accept, IDiamondCut.FacetCutAction.Add, FacetSelectors.acceptFacetSelectors());
        cuts[6] = IDiamondCut.FacetCut(eval, IDiamondCut.FacetCutAction.Add, FacetSelectors.evalFacetSelectors());
        cuts[7] = IDiamondCut.FacetCut(rating, IDiamondCut.FacetCutAction.Add, FacetSelectors.ratingFacetSelectors());
        cuts[8] =
            IDiamondCut.FacetCut(registry, IDiamondCut.FacetCutAction.Add, FacetSelectors.registryFacetSelectors());
        cuts[9] = IDiamondCut.FacetCut(
            address(new SettlementFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.settlementFacetSelectors()
        );
        cuts[10] = _feedbackCut();
        cuts[11] = _workerCut();
        cuts[12] = _projectCut();
    }

    /// @dev Its own frame keeps _buildCuts under the stack limit.
    function _feedbackCut() internal returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(
            address(new FeedbackFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.feedbackFacetSelectors()
        );
    }

    /// @dev rev027: the claim, worker selection and submission entrypoints. Its own frame keeps
    ///      _buildCuts under the stack limit.
    function _workerCut() internal returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(
            address(new WorkerFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.workerFacetSelectors()
        );
    }

    /// @dev rev027: projects. Its own frame keeps _buildCuts under the stack limit.
    function _projectCut() internal returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(
            address(new ProjectFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.projectFacetSelectors()
        );
    }
}
