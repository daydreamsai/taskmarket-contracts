// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev019Upgrade — remove the deprecated pre-rev018 createTask selector
/// @dev The contract half of the expand-then-contract pair rev018 began. Rev018 added the
///      evaluator-aware `createTask` and deliberately left the nine-parameter selector routed to
///      a deprecated shim, so the facet cut and the redeploy of every off-chain caller could
///      happen on their own schedules instead of as one indivisible operation spanning two
///      systems. This step ends that window: the shim is gone from CoreFacet's source, and the
///      selector is removed from the diamond.
///
/// @dev DEPLOY PRECONDITION -- this step is only safe once nothing encodes selector 0xa595d889.
///      After it lands, any caller still sending that selector gets `FunctionNotFound` from the
///      diamond's fallback, on every attempt, with no partial degradation. The backend having
///      been redeployed is necessary but not sufficient: verify against the chain rather than
///      against the deploy pipeline. See rev019 for the operator checklist.
///
/// @dev The cut is Remove(legacy selector) + Replace(CoreFacet's remaining selectors). The
///      Replace is not optional bundling: deleting the shim changes CoreFacet's bytecode, so the
///      diamond has to be pointed at a newly deployed facet or the removal saves nothing on
///      chain. Removing the route while leaving the old facet in place would recover no bytecode
///      and leave the dead code deployed.
///
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev019
///      make upgrade mainnet rev019
contract Rev019Upgrade is Script {
    uint256 private constant EXPECTED_PRE_VERSION = 18;
    uint256 private constant TARGET_VERSION = 19;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev019Upgrade: diamond is not at rev018");

        vm.startBroadcast(ownerKey);

        address coreFacet = address(new CoreFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);

        // Replace first, then Remove. The other order works too, but this way every selector the
        // diamond routes points at the new facet at all times.
        cuts[0] =
            IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors());

        bytes4[] memory legacyCreateTask = new bytes4[](1);
        legacyCreateTask[0] = FacetSelectors.LEGACY_CREATE_TASK;
        cuts[1] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, legacyCreateTask);

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev019 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:      ", coreFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }
}
