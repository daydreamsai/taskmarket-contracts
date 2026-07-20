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
    }
}
