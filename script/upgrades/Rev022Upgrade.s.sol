// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev022Upgrade -- make rateTask fail loudly when the feedback call is under-funded
/// @dev Replaces RatingFacet so rateTask reverts below a minimum gas floor before calling the
///      reputation registry, and emits ReputationFeedbackFailed when that call reverts. Selector
///      and storage layouts are unchanged.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
/// @dev Usage:
///      make upgrade testnet rev022
///      make upgrade mainnet rev022
contract Rev022Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 21;
    uint256 internal constant TARGET_VERSION = 22;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev022Upgrade: diamond is not at rev021");

        vm.startBroadcast(ownerKey);

        address ratingFacet = address(new RatingFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            ratingFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.ratingFacetSelectors()
        );

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev022 upgrade complete. Diamond:", diamond);
        console.log("RatingFacet: ", ratingFacet);
        console.log("diamondVersion:  ", TARGET_VERSION);
    }
}
