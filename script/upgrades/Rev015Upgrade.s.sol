// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev015Upgrade — replace RegistryFacet so getTask() returns the rev014 Task fields
/// @dev Rev014 (ADR-0029) added `stakeRequired`/`stakeBps` to the shared `ITMPCore.Task` struct
///      and updated `createTask` (CoreFacet) to write them, but never redeployed RegistryFacet
///      -- its `getTask()` returns `ITMPCore.Task memory` by value, so its deployed bytecode
///      still ABI-encodes whatever Task shape it was compiled against (the pre-rev014, 12-field
///      struct) regardless of what the struct looks like in current source. No RegistryFacet
///      selector's signature changed (only the return *type* of getTask widened), so this is a
///      pure Replace across every registryFacetSelectors() selector -- no Remove/Add needed,
///      unlike rev014's createTask (whose parameter list, and therefore selector, changed).
/// @dev This closes the gap PR #274 worked around on the backend: mainnet's getTask() was
///      returning 384 bytes (12 words) while the backend's ABI expected 448 bytes (14 words),
///      crashing the indexer's startup event-replay (`decodeFunctionResult` reading past the
///      actual return data) the first time it read a task settled after rev014. #274 reverted
///      the backend's ABI to match the then-live 12-field response so it stops crashing
///      regardless of when this upgrade lands; after this upgrade, getTask() genuinely returns
///      stakeRequired/stakeBps on-chain to any caller, matching current source.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage (normally applied automatically by `make upgrade <testnet|mainnet>` as part of the
///      pending-steps sequence; direct single-step invocation):
///      make upgrade testnet rev015
///      make upgrade mainnet rev015
contract Rev015Upgrade is Script {
    uint256 private constant EXPECTED_PRE_VERSION = 14;
    uint256 private constant TARGET_VERSION = 15;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev015Upgrade: diamond is not at rev014");

        vm.startBroadcast(ownerKey);

        address registryFacet = address(new RegistryFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            registryFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.registryFacetSelectors()
        );

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev015 upgrade complete. Diamond:", diamond);
        console.log("RegistryFacet:  ", registryFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }
}
