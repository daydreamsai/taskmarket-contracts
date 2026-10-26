// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { DeployTarget } from "./lib/DeployTarget.sol";

/// @title DiamondUpgradeAcceptPinning — atomically migrate acceptSubmissions to the 5-param pinning signature
///
/// @dev This upgrade swaps the old 4-param acceptSubmissions selector for the new 5-param one.
///      The old selector (bytes32,address[],uint16[],uint256) is removed and the new selector
///      (bytes32,address[],uint16[],bytes32[],uint256) is added in a single diamondCut call so
///      the function is never unrouted between the two operations.
///
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_84532  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_8453  — Diamond proxy on Base Mainnet (chain 8453)
///      FORGE_DIAMOND_ADDRESS_42431 / _4217 — Diamond proxy on Tempo (42431 / 4217)
///
/// @dev Usage:
///      make upgrade-accept-pinning 84532
///      make upgrade-accept-pinning 8453
contract DiamondUpgradeAcceptPinning is Script {
    // Old 4-param selector — must be hardcoded; source no longer compiles this signature.
    bytes4 private constant OLD_ACCEPT_SUBMISSIONS =
        bytes4(keccak256("acceptSubmissions(bytes32,address[],uint16[],uint256)"));

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        vm.startBroadcast(ownerKey);

        AcceptanceFacet newFacet = new AcceptanceFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);

        bytes4[] memory oldSelectors = new bytes4[](1);
        oldSelectors[0] = OLD_ACCEPT_SUBMISSIONS;
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, oldSelectors);

        bytes4[] memory newSelectors = new bytes4[](1);
        newSelectors[0] = AcceptanceFacet.acceptSubmissions.selector;
        cuts[1] = IDiamondCut.FacetCut(address(newFacet), IDiamondCut.FacetCutAction.Add, newSelectors);

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        console.log("AcceptPinning upgrade complete.");
        console.log("Diamond:       ", diamond);
        console.log("New facet:     ", address(newFacet));
        console.log("Old selector:  ");
        console.logBytes4(OLD_ACCEPT_SUBMISSIONS);
        console.log("New selector:  ");
        console.logBytes4(AcceptanceFacet.acceptSubmissions.selector);
    }
}
