// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev012Upgrade — replace AcceptanceFacet + CoreFacet to surface swallowed
///        giveFeedback reverts via ReputationFeedbackFailed
/// @dev First versioned upgrade step script (see rev011's diamondVersion tracking). Selector set
///      is unchanged -- ReputationFeedbackFailed is an event, not a new external function -- so
///      this is a pure Replace on the two facets whose bytecode changed.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev012
///      make upgrade mainnet rev012
contract Rev012Upgrade is Script {
    uint256 private constant EXPECTED_PRE_VERSION = 11;
    uint256 private constant TARGET_VERSION = 12;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev012Upgrade: diamond is not at rev011");

        vm.startBroadcast(ownerKey);

        address coreFacet = address(new CoreFacet());
        address acceptFacet = address(new AcceptanceFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] =
            IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(
            acceptFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.acceptFacetSelectors()
        );

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev012 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:       ", coreFacet);
        console.log("AcceptanceFacet: ", acceptFacet);
        console.log("diamondVersion:  ", TARGET_VERSION);
    }
}
