// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { ITMPTerms } from "../../src/interfaces/ITMPTerms.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev025Upgrade -- settlement terms
/// @dev Appends taskTerms, taskClocks, taskAwarded and termsBounds to AppStorage. Replaces
///      CoreFacet and AdminFacet with their rev024 selector lists, Adds the createTask overload
///      taking TaskTerms to CoreFacet and setTermsBounds to AdminFacet, and Adds SettlementFacet
///      (normalizeTerms, getTaskTerms, termsBounds). The legacy createTask records the default terms. Run normalizeTerms over
///      every live task id after this step, before any other post-upgrade pass over task ids.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  -- Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  -- Diamond proxy on Base Mainnet (chain 8453)
///      FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET -- Diamond proxy on Tempo Moderato (chain 42431)
///      FORGE_DIAMOND_ADDRESS_TEMPO_MAINNET -- Diamond proxy on Tempo mainnet (chain 4217)
/// @dev Usage:
///      make upgrade testnet rev025
///      make upgrade mainnet rev025
contract Rev025Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 24;
    uint256 internal constant TARGET_VERSION = 25;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev025Upgrade: diamond is not at rev024");

        vm.startBroadcast(ownerKey);

        address coreFacet = address(new CoreFacet());
        address adminFacet = address(new AdminFacet());
        address settlementFacet = address(new SettlementFacet());

        bytes4[] memory newCore = new bytes4[](1);
        newCore[0] = ITMPTerms.createTask.selector;
        bytes4[] memory newAdmin = new bytes4[](1);
        newAdmin[0] = AdminFacet.setTermsBounds.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = IDiamondCut.FacetCut(
            coreFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.coreFacetSelectorsThroughRev024()
        );
        cuts[1] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Add, newCore);
        cuts[2] = IDiamondCut.FacetCut(
            adminFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.adminFacetSelectorsThroughRev024()
        );
        cuts[3] = IDiamondCut.FacetCut(adminFacet, IDiamondCut.FacetCutAction.Add, newAdmin);
        cuts[4] = IDiamondCut.FacetCut(
            settlementFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.settlementFacetSelectors()
        );

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        console.log("Rev025 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:      ", coreFacet);
        console.log("SettlementFacet:", settlementFacet);
        console.log("AdminFacet:     ", adminFacet);
        console.log("diamondVersion: ", TARGET_VERSION);
    }
}
