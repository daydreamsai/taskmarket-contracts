// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev021Upgrade — make zero-valued evaluator awards recipient-inert
/// @dev Replaces EvaluatorFacet so Bounty and Benchmark awards select a worker only when an
///      award has a nonzero value. A zero-only final verdict clears an earlier evaluator-selected
///      worker, including while resolving an appeal; Claim, Pitch, and Auction workers remain
///      locked. Selector and storage layouts are unchanged.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
/// @dev Usage:
///      make upgrade testnet rev021
///      make upgrade mainnet rev021
contract Rev021Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 20;
    uint256 internal constant TARGET_VERSION = 21;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev021Upgrade: diamond is not at rev020");

        vm.startBroadcast(ownerKey);

        address evaluatorFacet = address(new EvaluatorFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            evaluatorFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors()
        );

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev021 upgrade complete. Diamond:", diamond);
        console.log("EvaluatorFacet: ", evaluatorFacet);
        console.log("diamondVersion:  ", TARGET_VERSION);
    }
}
