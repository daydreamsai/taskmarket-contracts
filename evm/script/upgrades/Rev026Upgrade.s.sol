// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { DeployTarget } from "../lib/DeployTarget.sol";
import { FacetSelectors } from "../lib/FacetSelectors.sol";

/// @title Rev026Upgrade -- escrow liabilities and the solvency check
/// @dev Appends totalLiabilities, escrowRecords and liabilitiesInitialised to AppStorage. Replaces
///      CoreFacet, SettlementFacet, AcceptanceFacet and EvaluatorFacet (every funding and payout
///      path books or releases its liability through LibEscrow), Replaces AdminFacet and Adds
///      sweepSurplus, backfillLiabilities and completeLiabilities, and Replaces RegistryFacet and Adds totalLiabilities, escrowRecord and
///      liabilitiesInitialised.
/// @dev Appends hookGasStipend to AppStorage and Adds hookGasStipend and setHookGasStipend to
///      AdminFacet: the gas each hook call gets becomes a per-chain value, read by every facet
///      that dispatches hooks, so AuctionFacet is Replaced too. When FORGE_HOOK_GAS_STIPEND is
///      set the same broadcast sets the stipend to it; script/tempo.sh requires
///      FORGE_HOOK_GAS_STIPEND_TEMPO_* so Tempo never runs rev026 on the 1,000,000 default.
/// @dev Removes the rev018 createTask overload (the one taking a StakeConfig) and normalizeTerms.
///      Every task live at the rev025 cut was normalized then, so neither has work left to do.
/// @dev Live tasks created before rev026 are not booked by the cut: Rev026Backfill books them,
///      the runbook reconciles the surplus against the escrow monitor, and the owner calls
///      completeLiabilities. Until then an unbooked task's payouts release nothing. See
///      docs/runbooks/rev026-upgrade.md.
/// @dev The cut goes out as two diamondCut transactions: as one it needs about 38M gas on Tempo,
///      over its 30M per-transaction limit. The first carries the four settlement-path facets
///      and Adds the RegistryFacet views; the second the rest. A run that stops between them
///      leaves the diamond at rev025 with those views present, so a re-run skips the first
///      cut and sends only the second.
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          -- owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_84532  -- Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_8453  -- Diamond proxy on Base Mainnet (chain 8453)
///      FORGE_DIAMOND_ADDRESS_42431 -- Diamond proxy on Tempo Moderato (chain 42431)
///      FORGE_DIAMOND_ADDRESS_4217 -- Diamond proxy on Tempo mainnet (chain 4217)
contract Rev026Upgrade is Script {
    uint256 internal constant EXPECTED_PRE_VERSION = 25;
    uint256 internal constant TARGET_VERSION = 26;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = DeployTarget.diamondFor(vm);

        uint256 currentVersion = AdminFacet(diamond).diamondVersion();
        require(currentVersion == EXPECTED_PRE_VERSION, "Rev026Upgrade: diamond is not at rev025");

        bool firstCutDone = firstCutApplied(diamond);

        vm.startBroadcast(ownerKey);

        address registryFacet;
        if (firstCutDone) {
            registryFacet = IDiamondLoupe(diamond).facetAddress(FacetSelectors.registryFacetSelectorsAddedRev026()[0]);
            console.log("First rev026 cut already applied; sending the second.");
        } else {
            registryFacet = address(new RegistryFacet());
            IDiamondCut(diamond).diamondCut(_firstCut(registryFacet), address(0), "");
        }
        IDiamondCut(diamond).diamondCut(_secondCut(registryFacet), address(0), "");

        uint256 hookStipend = vm.envOr("FORGE_HOOK_GAS_STIPEND", uint256(0));
        if (hookStipend != 0) AdminFacet(diamond).setHookGasStipend(hookStipend);
        AdminFacet(diamond).setDiamondVersion(TARGET_VERSION);

        vm.stopBroadcast();

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        console.log("Rev026 upgrade complete. Diamond:", diamond);
        console.log("CoreFacet:      ", loupe.facetAddress(FacetSelectors.coreFacetSelectorsThroughRev026()[0]));
        console.log("SettlementFacet:", loupe.facetAddress(FacetSelectors.settlementFacetSelectorsThroughRev026()[0]));
        console.log("AcceptanceFacet:", loupe.facetAddress(FacetSelectors.acceptFacetSelectors()[0]));
        console.log("EvaluatorFacet: ", loupe.facetAddress(FacetSelectors.evalFacetSelectors()[0]));
        console.log("AdminFacet:     ", loupe.facetAddress(FacetSelectors.adminFacetSelectorsAddedRev026()[0]));
        console.log("RegistryFacet:  ", registryFacet);
        console.log("AuctionFacet:   ", loupe.facetAddress(FacetSelectors.auctionFacetSelectors()[0]));
        console.log("hookGasStipend: ", AdminFacet(diamond).hookGasStipend());
        console.log("diamondVersion: ", TARGET_VERSION);
        console.log("Run Rev026Backfill next.");
    }

    /// @notice True once the first cut has landed: it is the only one that Adds the RegistryFacet views.
    function firstCutApplied(address diamond) public view returns (bool) {
        return IDiamondLoupe(diamond).facetAddress(FacetSelectors.registryFacetSelectorsAddedRev026()[0]) != address(0);
    }

    function _firstCut(address registryFacet) internal returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = IDiamondCut.FacetCut(
            address(new CoreFacet()),
            IDiamondCut.FacetCutAction.Replace,
            FacetSelectors.coreFacetSelectorsThroughRev026()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new SettlementFacet()),
            IDiamondCut.FacetCutAction.Replace,
            FacetSelectors.settlementFacetSelectorsThroughRev026()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.acceptFacetSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(new EvaluatorFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.evalFacetSelectors()
        );
        cuts[4] = IDiamondCut.FacetCut(
            registryFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.registryFacetSelectorsAddedRev026()
        );
    }

    function _secondCut(address registryFacet) internal returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](5);
        address adminFacet = address(new AdminFacet());
        cuts[0] = IDiamondCut.FacetCut(
            adminFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.adminFacetSelectorsThroughRev025()
        );
        cuts[1] = IDiamondCut.FacetCut(
            adminFacet, IDiamondCut.FacetCutAction.Add, FacetSelectors.adminFacetSelectorsAddedRev026()
        );
        cuts[2] = IDiamondCut.FacetCut(
            registryFacet, IDiamondCut.FacetCutAction.Replace, FacetSelectors.registryFacetSelectorsThroughRev025()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(0), IDiamondCut.FacetCutAction.Remove, FacetSelectors.selectorsRemovedRev026()
        );
        cuts[4] = IDiamondCut.FacetCut(
            address(new AuctionFacet()), IDiamondCut.FacetCutAction.Replace, FacetSelectors.auctionFacetSelectors()
        );
    }
}
