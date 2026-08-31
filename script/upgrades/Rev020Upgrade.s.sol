// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev020Upgrade — seed the fresh-deploy version from the build
/// @dev Rev020 changes no selector on any facet. The only source change it carries into deployed
///      bytecode is in `AdminFacet.initialize()`, which stamps `LibRevision.CURRENT_REVISION`
///      instead of the literal 11, and `initialize()` can never run again on a live diamond --
///      it is `initializer`-guarded and already spent. So this step alters no behaviour a live
///      diamond can reach.
///
/// @dev It exists anyway, for one reason: without it, a fresh deploy of this build would report
///      20 while a live diamond carried forward by the step sequence stopped at 19, with the two
///      running identical code. `diamondVersion` would then mean different things depending on
///      how the diamond got there, which is the exact defect rev020 set out to remove. A step
///      script keeps the two paths convergent, and the parity test asserts that convergence.
///
/// @dev The cut is a pure Replace of AdminFacet's selector set. In the original rev020 build it
///      pointed the diamond at the source carrying this revision's seed fix. Like every historical
///      step compiled in-tree, a later sequence run builds the facet from the current checkout;
///      the literal target below keeps the version transition itself fixed at 19 -> 20.
///
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev020
///      make upgrade mainnet rev020
contract Rev020Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 19;
    // Revision steps are immutable historical transitions. This must stay literal so a later
    // LibRevision bump cannot make rev020 skip an intervening step in the upgrade sequence.
    uint256 internal constant TARGET_VERSION = 20;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev020Upgrade: diamond is not at rev019");

        vm.startBroadcast(ownerKey);

        address adminFacet = address(new AdminFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] =
            IDiamondCut.FacetCut(adminFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.adminFacetSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev020 upgrade complete. Diamond:", diamond);
        console.log("AdminFacet:     ", adminFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }
}
