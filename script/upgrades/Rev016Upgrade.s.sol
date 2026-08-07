// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev016Upgrade — replace CoreFacet so settled escrow liability is actually extinguished
/// @dev Rev016 fixes two ways the recorded liability (`task.reward`) and the pooled USDC balance
///      could disagree: `refundExpired` did not treat `Expired` -- the status its own refund path
///      assigns -- as terminal and never zeroed the reward it had just paid out, so a repeat call
///      passed every guard and paid the same reward again out of the single escrow pool shared by
///      all tasks; and `updateTask` silently no-op'd a named-but-unchanged reward, absorbing a
///      duplicate relay of a reward increase whose USDC the forwarder had already pulled.
/// @dev Both fixes are confined to CoreFacet's function bodies plus two new errors on ITMPCore.
///      No parameter list changed, so no selector changed: this is a pure Replace across every
///      coreFacetSelectors() selector, with no Remove/Add. Errors are ABI surface but not routing
///      surface -- the diamond does not register selectors for them -- so adding
///      TaskAlreadyRefunded/NoRewardChange needs no cut of its own.
/// @dev Deploy ordering matters. Relayed calls are decoded against FORWARDER_ABI, so a Diamond
///      revert whose selector the backend does not know resolves to the string `unknown revert`,
///      which classifyRelayFailure treats as transient and retries for ever. Both new errors are
///      permanently true once true. Do not cut this facet in before a backend whose KNOWN_ERRORS
///      carries TaskAlreadyRefunded and NoRewardChange, or those reverts become intents that can
///      never succeed and never stop asking.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev016
///      make upgrade mainnet rev016
contract Rev016Upgrade is Script {
    uint256 private constant MAINNET_CHAIN_ID = 8453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 private constant EXPECTED_PRE_VERSION = 15;
    uint256 private constant TARGET_VERSION = 16;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        // Name both chains explicitly instead of treating "not mainnet" as testnet. This is a
        // security upgrade to a live diamond, and an unrecognised chain id under a fallback
        // resolves to the testnet address and broadcasts a cut at whatever happens to live there
        // -- a wrong-contract write that the version precondition below would only catch by luck.
        // An unknown chain has no correct answer here, so it gets no answer.
        address diamond;
        if (block.chainid == MAINNET_CHAIN_ID) {
            diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET");
        } else if (block.chainid == BASE_SEPOLIA_CHAIN_ID) {
            diamond = vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");
        } else {
            revert("Rev016Upgrade: unsupported chain id");
        }

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev016Upgrade: diamond is not at rev015");

        vm.startBroadcast(ownerKey);

        address coreFacet = address(new CoreFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] =
            IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev016 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:      ", coreFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }
}
