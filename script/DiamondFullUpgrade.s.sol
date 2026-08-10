// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { AuctionFacet } from "../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { FacetSelectors } from "./lib/FacetSelectors.sol";

/// @title DiamondFullUpgrade — replace all facets on an existing Diamond proxy in one tx
/// @dev Required env vars:
///      FORGE_DEV_PRIVATE_KEY          — owner key (must match Diamond owner)
///      FORGE_DIAMOND_ADDRESS_TESTNET  — Diamond proxy on Base Sepolia (chain 84532)
///      FORGE_DIAMOND_ADDRESS_MAINNET  — Diamond proxy on Base Mainnet (chain 8453)
///
/// @dev Usage:
///      make upgrade testnet
///      make upgrade mainnet
///
/// @dev Three upgrade paths — detected automatically via the loupe:
///
///      Path A (_runWithMigration): pre-submission-integrity diamond (has old cancelTask(bytes32)).
///        Removes old selector set and adds new ones atomically, plus all rev010 additions.
///
///      Path B (_runRev010Migration): post-submission-integrity, pre-rev010 diamond
///        (no old cancelTask, but setDefaultHooks is absent). This is the common testnet state
///        when upgrading from any rev007–rev009 deployment to the hook-enabled contracts.
///        Removes old createTask, adds new one; adds new AdminFacet and RegistryFacet functions.
///        Also removes PREV_ACCEPT_SUBMISSIONS if still present.
///
///      Path C (_runReplace): steady-state (post-rev010). All current selectors exist.
///        Pure Replace, plus one Add cut for the new rev011 diamondVersion selectors.
///
/// @dev rev011: every path also adds AdminFacet.diamondVersion()/setDiamondVersion() (absent on
///      every diamond deployed before this upgrade) and calls setDiamondVersion() once the cut
///      lands, so a diamond's upgrade-step version becomes an explicit on-chain fact instead of
///      something inferred from selector presence/absence.
contract DiamondFullUpgrade is Script {
    // rev007 selectors — present on pre-submission-integrity diamonds.
    bytes4 private constant OLD_CANCEL_TASK = bytes4(keccak256("cancelTask(bytes32)"));
    bytes4 private constant OLD_REFUND_EXPIRED = bytes4(keccak256("refundExpired(bytes32)"));
    bytes4 private constant OLD_ACCEPT_SUBMISSION = bytes4(keccak256("acceptSubmission(bytes32,address,bytes32)"));
    bytes4 private constant OLD_ACCEPT_SUBMISSIONS =
        bytes4(keccak256("acceptSubmissions(bytes32,address[],uint16[],bytes32[])"));
    // rev009 selector — present on rev007–rev008 diamonds (5-param acceptSubmissions not yet added).
    bytes4 private constant PREV_ACCEPT_SUBMISSIONS =
        bytes4(keccak256("acceptSubmissions(bytes32,address[],uint16[],uint256)"));
    // rev010 selector — old createTask before hook config struct refactor.
    bytes4 private constant OLD_CREATE_TASK = bytes4(
        keccak256("createTask(uint256,uint256,bytes4,uint256,uint256,bytes32,string,bytes4,address,bytes32[],bytes)")
    );

    // rev011: the diamondVersion value every path lands on today. All three paths apply the
    // same steady-state target, so all three set the same version. Matches this codebase's
    // existing revision numbering (rev007, rev008, ... rev011), backfilled here since the
    // counter did not exist before this upgrade.
    uint256 private constant CURRENT_VERSION = 11;

    function run() external {
        uint256 ownerKey = vm.envUint("FORGE_DEV_PRIVATE_KEY");
        address diamond = block.chainid == 8453
            ? vm.envAddress("FORGE_DIAMOND_ADDRESS_MAINNET")
            : vm.envAddress("FORGE_DIAMOND_ADDRESS_TESTNET");

        // Path A: very old diamond — still has pre-submission-integrity selectors.
        bool needsMigration = IDiamondLoupe(diamond).facetAddress(OLD_CANCEL_TASK) != address(0);
        // Path B: post-submission-integrity but pre-rev010 — setDefaultHooks not yet added.
        bool needsRev010Migration =
            !needsMigration && IDiamondLoupe(diamond).facetAddress(AdminFacet.setDefaultHooks.selector) == address(0);
        // Rev009 leftover: PREV_ACCEPT_SUBMISSIONS may still be present on some diamonds.
        bool hasPrevAcceptSubs = IDiamondLoupe(diamond).facetAddress(PREV_ACCEPT_SUBMISSIONS) != address(0);

        vm.startBroadcast(ownerKey);

        address cutFacet = address(new DiamondCutFacet());
        address loupeFacet = address(new DiamondLoupeFacet());
        address adminFacet = address(new AdminFacet());
        address coreFacet = address(new CoreFacet());
        address auctionFacet = address(new AuctionFacet());
        address acceptFacet = address(new AcceptanceFacet());
        address evalFacet = address(new EvaluatorFacet());
        address ratingFacet = address(new RatingFacet());
        address regFacet = address(new RegistryFacet());

        if (needsMigration) {
            _runWithMigration(
                diamond,
                cutFacet,
                loupeFacet,
                adminFacet,
                coreFacet,
                auctionFacet,
                acceptFacet,
                evalFacet,
                ratingFacet,
                regFacet
            );
        } else if (needsRev010Migration) {
            _runRev010Migration(
                diamond,
                cutFacet,
                loupeFacet,
                adminFacet,
                coreFacet,
                auctionFacet,
                acceptFacet,
                evalFacet,
                ratingFacet,
                regFacet,
                hasPrevAcceptSubs
            );
        } else {
            _runReplace(
                diamond,
                cutFacet,
                loupeFacet,
                adminFacet,
                coreFacet,
                auctionFacet,
                acceptFacet,
                evalFacet,
                ratingFacet,
                regFacet
            );
        }

        vm.stopBroadcast();

        console.log("Full upgrade complete. Diamond:", diamond);
        console.log("DiamondCutFacet:  ", cutFacet);
        console.log("DiamondLoupeFacet:", loupeFacet);
        console.log("AdminFacet:       ", adminFacet);
        console.log("CoreFacet:        ", coreFacet);
        console.log("AuctionFacet:     ", auctionFacet);
        console.log("AcceptanceFacet:  ", acceptFacet);
        console.log("EvaluatorFacet:   ", evalFacet);
        console.log("RatingFacet:      ", ratingFacet);
        console.log("RegistryFacet:    ", regFacet);
    }

    // -------------------------------------------------------------------------
    // Path A: pre-submission-integrity diamonds
    // -------------------------------------------------------------------------

    /// @dev Removes rev007 old selectors and adds new ones, plus all rev010 and rev011 additions.
    ///      15 cuts total.
    function _runWithMigration(
        address diamond,
        address cutFacet,
        address loupeFacet,
        address adminFacet,
        address coreFacet,
        address auctionFacet,
        address acceptFacet,
        address evalFacet,
        address ratingFacet,
        address regFacet
    ) private {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](15);

        cuts[0] = _replaceCut(cutFacet, FacetSelectors.cutFacetSelectors());
        cuts[1] = _replaceCut(loupeFacet, FacetSelectors.loupeFacetSelectors());

        // AdminFacet: Replace 13 existing, Add 2 rev010 (setDefaultHooks, getDefaultHooks) +
        // 2 rev011 (diamondVersion, setDiamondVersion).
        cuts[2] = _replaceCut(adminFacet, _adminExistingSelectors());
        cuts[3] = _addCut(adminFacet, _adminNewSelectors());
        cuts[14] = _addCut(adminFacet, _diamondVersionSelectors());

        // CoreFacet: Remove 3 old changed selectors, Replace 18 unchanged, Add 3 new.
        bytes4[] memory oldCoreChanged = new bytes4[](3);
        oldCoreChanged[0] = OLD_CANCEL_TASK;
        oldCoreChanged[1] = OLD_REFUND_EXPIRED;
        oldCoreChanged[2] = OLD_CREATE_TASK;
        cuts[4] = _removeCut(oldCoreChanged);
        cuts[5] = _replaceCut(coreFacet, _coreRevIntegrityUnchangedSelectors());
        bytes4[] memory newCoreChanged = new bytes4[](3);
        newCoreChanged[0] = CoreFacet.cancelTask.selector;
        newCoreChanged[1] = CoreFacet.refundExpired.selector;
        // Only the evaluator-aware createTask. Rev018 briefly had this path add the legacy
        // nine-parameter selector too, so a diamond this old landed mid-migration alongside
        // everything else; rev019 removed the shim, so there is nothing to route it to.
        newCoreChanged[2] = CoreFacet.createTask.selector;
        cuts[6] = _addCut(coreFacet, newCoreChanged);

        cuts[7] = _replaceCut(auctionFacet, FacetSelectors.auctionFacetSelectors());

        // AcceptanceFacet: Remove old 2 selectors, Add new 2.
        bytes4[] memory oldAcceptChanged = new bytes4[](2);
        oldAcceptChanged[0] = OLD_ACCEPT_SUBMISSION;
        oldAcceptChanged[1] = OLD_ACCEPT_SUBMISSIONS;
        cuts[8] = _removeCut(oldAcceptChanged);
        bytes4[] memory newAcceptChanged = new bytes4[](2);
        newAcceptChanged[0] = AcceptanceFacet.acceptSubmission.selector;
        newAcceptChanged[1] = AcceptanceFacet.acceptSubmissions.selector;
        cuts[9] = _addCut(acceptFacet, newAcceptChanged);

        cuts[10] = _replaceCut(evalFacet, FacetSelectors.evalFacetSelectors());
        cuts[11] = _replaceCut(ratingFacet, FacetSelectors.ratingFacetSelectors());

        // RegistryFacet: Replace 21 pre-sub-integrity selectors, Add taskSubmissionHashes + 7 new.
        cuts[12] = _replaceCut(regFacet, _regPreIntegritySelectors());
        cuts[13] = _addCut(regFacet, _regAllNewSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(CURRENT_VERSION);
        console.log("Path A: removed pre-submission-integrity selectors, applied rev010+rev011 additions.");
    }

    // -------------------------------------------------------------------------
    // Path B: post-submission-integrity, pre-rev010 diamonds (common testnet state)
    // -------------------------------------------------------------------------

    /// @dev Removes old createTask selector, adds new one; adds new AdminFacet and RegistryFacet
    ///      functions; handles PREV_ACCEPT_SUBMISSIONS if still present.
    ///      14 cuts (hasPrevAcceptSubs=false) or 16 cuts (hasPrevAcceptSubs=true).
    function _runRev010Migration(
        address diamond,
        address cutFacet,
        address loupeFacet,
        address adminFacet,
        address coreFacet,
        address auctionFacet,
        address acceptFacet,
        address evalFacet,
        address ratingFacet,
        address regFacet,
        bool hasPrevAcceptSubs
    ) private {
        uint256 cutCount = hasPrevAcceptSubs ? 16 : 14;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](cutCount);
        uint256 i = 0;

        cuts[i++] = _replaceCut(cutFacet, FacetSelectors.cutFacetSelectors());
        cuts[i++] = _replaceCut(loupeFacet, FacetSelectors.loupeFacetSelectors());

        // AdminFacet: Replace 13 existing, Add 2 rev010 + 2 rev011 (diamondVersion, setDiamondVersion).
        cuts[i++] = _replaceCut(adminFacet, _adminExistingSelectors());
        cuts[i++] = _addCut(adminFacet, _adminNewSelectors());
        cuts[i++] = _addCut(adminFacet, _diamondVersionSelectors());

        // CoreFacet: Remove old createTask, Replace 20 existing (without createTask), Add new createTask.
        bytes4[] memory oldCreateTask = new bytes4[](1);
        oldCreateTask[0] = OLD_CREATE_TASK;
        cuts[i++] = _removeCut(oldCreateTask);
        cuts[i++] = _replaceCut(coreFacet, _coreExistingSelectors());
        bytes4[] memory newCreateTask = new bytes4[](1);
        newCreateTask[0] = CoreFacet.createTask.selector;
        cuts[i++] = _addCut(coreFacet, newCreateTask);

        cuts[i++] = _replaceCut(auctionFacet, FacetSelectors.auctionFacetSelectors());

        if (hasPrevAcceptSubs) {
            // Replace acceptSubmission (selector unchanged), Remove PREV_ACCEPT_SUBMISSIONS, Add new acceptSubmissions.
            bytes4[] memory acceptUnchanged = new bytes4[](1);
            acceptUnchanged[0] = AcceptanceFacet.acceptSubmission.selector;
            cuts[i++] = _replaceCut(acceptFacet, acceptUnchanged);
            bytes4[] memory prevAccept = new bytes4[](1);
            prevAccept[0] = PREV_ACCEPT_SUBMISSIONS;
            cuts[i++] = _removeCut(prevAccept);
            bytes4[] memory newAcceptPlural = new bytes4[](1);
            newAcceptPlural[0] = AcceptanceFacet.acceptSubmissions.selector;
            cuts[i++] = _addCut(acceptFacet, newAcceptPlural);
        } else {
            // Both acceptance selectors are already at final signatures — Replace both together.
            bytes4[] memory acceptBoth = new bytes4[](2);
            acceptBoth[0] = AcceptanceFacet.acceptSubmission.selector;
            acceptBoth[1] = AcceptanceFacet.acceptSubmissions.selector;
            cuts[i++] = _replaceCut(acceptFacet, acceptBoth);
        }

        cuts[i++] = _replaceCut(evalFacet, FacetSelectors.evalFacetSelectors());
        cuts[i++] = _replaceCut(ratingFacet, FacetSelectors.ratingFacetSelectors());

        // RegistryFacet: Replace 22 existing (including taskSubmissionHashes), Add 7 new.
        cuts[i++] = _replaceCut(regFacet, _regRev009Selectors());
        cuts[i++] = _addCut(regFacet, _regRev010NewSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(CURRENT_VERSION);
        console.log(
            "Path B: applied rev010+rev011 migration (new createTask, admin hooks, registry views, version tracking)."
        );
    }

    // -------------------------------------------------------------------------
    // Path C: steady-state (post-rev010) — pure Replace
    // -------------------------------------------------------------------------

    /// @dev All pre-rev011 selectors at current signatures — Replace in 9 cuts, plus 2 Add cuts
    ///      for selectors absent on every diamond until their revision landed and which therefore
    ///      cannot be part of a Replace: rev011's diamondVersion/setDiamondVersion, and rev017's
    ///      minAppealWindowSecs/setMinAppealWindowSecs. Path C must always produce today's
    ///      complete steady-state selector set -- DiamondSelectorParityTest is what enforces
    ///      that, by comparing this path's output against a fresh deploy's.
    /// @dev internal (not private) so the rev011 selector-parity test can invoke Path C
    ///      directly against a diamond it deployed itself, without going through run()'s
    ///      env-var/loupe-based path detection.
    function _runReplace(
        address diamond,
        address cutFacet,
        address loupeFacet,
        address adminFacet,
        address coreFacet,
        address auctionFacet,
        address acceptFacet,
        address evalFacet,
        address ratingFacet,
        address regFacet
    ) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](13);
        // Running index rather than literals: a revision that appends a cut here and a revision
        // that appends another one merge cleanly into two `i++` lines, whereas two literal
        // `cuts[10] = ...` assignments merge into a silent overwrite of one by the other. Path B
        // above already uses this form for the same reason.
        uint256 i = 0;

        cuts[i++] = _replaceCut(cutFacet, FacetSelectors.cutFacetSelectors());
        cuts[i++] = _replaceCut(loupeFacet, FacetSelectors.loupeFacetSelectors());
        cuts[i++] = _replaceCut(adminFacet, _adminPreRev011Selectors());
        // CoreFacet: Replace the selectors an existing diamond already routes, then Add rev018's
        // evaluator-aware createTask, which no diamond routes until this cut lands and so cannot
        // be part of a Replace, then Remove the legacy nine-parameter selector (rev019). Path C
        // targets the current steady state, and no facet has served that selector since rev019
        // deleted the shim -- leaving it routed would point it at a CoreFacet without the
        // function, which is a silent 404 through the fallback rather than an honest one.
        cuts[i++] = _replaceCut(coreFacet, _corePreRev018Selectors());
        cuts[i++] = _addCut(coreFacet, _createTaskSelector());
        cuts[i++] = _removeCut(_legacyCreateTaskSelector());
        cuts[i++] = _replaceCut(auctionFacet, FacetSelectors.auctionFacetSelectors());
        cuts[i++] = _replaceCut(acceptFacet, FacetSelectors.acceptFacetSelectors());
        cuts[i++] = _replaceCut(evalFacet, FacetSelectors.evalFacetSelectors());
        cuts[i++] = _replaceCut(ratingFacet, FacetSelectors.ratingFacetSelectors());
        cuts[i++] = _replaceCut(regFacet, FacetSelectors.registryFacetSelectors());
        cuts[i++] = _addCut(adminFacet, _diamondVersionSelectors());
        cuts[i++] = _addCut(adminFacet, _minAppealWindowSelectors());

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        AdminFacet(diamond).setDiamondVersion(CURRENT_VERSION);
        console.log("Path C: steady-state replace, all facets updated in place, version tracking added.");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _replaceCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, selectors);
    }

    function _addCut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, selectors);
    }

    function _removeCut(bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, selectors);
    }

    /// @dev 13 AdminFacet selectors present before rev010.
    function _adminExistingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = AdminFacet.paused.selector;
        s[1] = AdminFacet.pause.selector;
        s[2] = AdminFacet.unpause.selector;
        s[3] = AdminFacet.transferOwnership.selector;
        s[4] = AdminFacet.acceptOwnership.selector;
        s[5] = AdminFacet.owner.selector;
        s[6] = AdminFacet.pendingOwner.selector;
        s[7] = AdminFacet.addForwarder.selector;
        s[8] = AdminFacet.removeForwarder.selector;
        s[9] = AdminFacet.isTrustedForwarder.selector;
        s[10] = AdminFacet.setDefaultFeeBps.selector;
        s[11] = AdminFacet.setFeeRecipient.selector;
        s[12] = AdminFacet.setReputationRegistry.selector;
    }

    /// @dev 2 new AdminFacet selectors added in rev010.
    function _adminNewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.setDefaultHooks.selector;
        s[1] = AdminFacet.getDefaultHooks.selector;
    }

    /// @dev All 15 AdminFacet selectors present on any diamond upgraded to at least rev010, i.e.
    ///      before rev011's diamondVersion/setDiamondVersion existed. Used as the Replace cut
    ///      in Path C -- distinct from FacetSelectors.adminFacetSelectors(), which is the
    ///      19-selector canonical set including the four added since (rev011's two and rev017's
    ///      two), appropriate for a fresh deploy but not for a Replace cut against a diamond that
    ///      does not have them yet.
    function _adminPreRev011Selectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](15);
        s[0] = AdminFacet.paused.selector;
        s[1] = AdminFacet.pause.selector;
        s[2] = AdminFacet.unpause.selector;
        s[3] = AdminFacet.transferOwnership.selector;
        s[4] = AdminFacet.acceptOwnership.selector;
        s[5] = AdminFacet.owner.selector;
        s[6] = AdminFacet.pendingOwner.selector;
        s[7] = AdminFacet.addForwarder.selector;
        s[8] = AdminFacet.removeForwarder.selector;
        s[9] = AdminFacet.isTrustedForwarder.selector;
        s[10] = AdminFacet.setDefaultFeeBps.selector;
        s[11] = AdminFacet.setFeeRecipient.selector;
        s[12] = AdminFacet.setReputationRegistry.selector;
        s[13] = AdminFacet.setDefaultHooks.selector;
        s[14] = AdminFacet.getDefaultHooks.selector;
    }

    /// @dev Rev011: diamondVersion/setDiamondVersion, absent on every diamond deployed before
    ///      this change regardless of which historical path (A/B/C) it is otherwise on. Always
    ///      an Add cut, never a Replace.
    function _diamondVersionSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.diamondVersion.selector;
        s[1] = AdminFacet.setDiamondVersion.selector;
    }

    /// @dev Rev017: minAppealWindowSecs/setMinAppealWindowSecs, absent on every diamond deployed
    ///      before the appeal-window floor became admin-settable state. Always an Add cut, never
    ///      a Replace.
    function _minAppealWindowSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.minAppealWindowSecs.selector;
        s[1] = AdminFacet.setMinAppealWindowSecs.selector;
    }

    /// @dev Rev018's evaluator-aware createTask on its own. Always an Add cut for an existing
    ///      diamond, never a Replace: no diamond routes this selector until the cut lands.
    function _createTaskSelector() private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = CoreFacet.createTask.selector;
    }

    /// @dev The pre-rev018 nine-parameter createTask, for Path C's Remove cut (rev019). Always a
    ///      Remove and never part of a Replace: no facet has served this signature since rev019
    ///      deleted the shim, so there is no address to point it at.
    function _legacyCreateTaskSelector() private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = FacetSelectors.LEGACY_CREATE_TASK;
    }

    /// @dev The 21 CoreFacet selectors a steady-state diamond routes before rev018 -- the current
    ///      set with the evaluator-aware createTask swapped back for the legacy one. Used as Path
    ///      C's Replace cut, since Replace requires every selector to already exist. The legacy
    ///      entry is Replaced and then Removed in the same cut sequence rather than being left
    ///      out of the Replace: an old diamond routes it, so omitting it would leave it pointing
    ///      at the previous CoreFacet.
    function _corePreRev018Selectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        s[0] = bytes4(keccak256("BOUNTY()"));
        s[1] = bytes4(keccak256("CLAIM()"));
        s[2] = bytes4(keccak256("PITCH()"));
        s[3] = bytes4(keccak256("BENCHMARK()"));
        s[4] = bytes4(keccak256("AUCTION()"));
        s[5] = bytes4(keccak256("AUCTION_DUTCH()"));
        s[6] = bytes4(keccak256("AUCTION_ENGLISH()"));
        s[7] = bytes4(keccak256("AUCTION_REVERSE_DUTCH()"));
        s[8] = bytes4(keccak256("AUCTION_REVERSE_ENGLISH()"));
        s[9] = bytes4(keccak256("MAX_BIDS_PER_TASK()"));
        s[10] = FacetSelectors.LEGACY_CREATE_TASK;
        s[11] = CoreFacet.claimTask.selector;
        s[12] = CoreFacet.selectWorker.selector;
        s[13] = CoreFacet.submitPitch.selector;
        s[14] = CoreFacet.submitProof.selector;
        s[15] = CoreFacet.submitWork.selector;
        s[16] = CoreFacet.forfeitAndReopen.selector;
        s[17] = CoreFacet.cancelTask.selector;
        s[18] = CoreFacet.updateTask.selector;
        s[19] = CoreFacet.refundExpired.selector;
        s[20] = CoreFacet.rejectSubmission.selector;
    }

    /// @dev 18 CoreFacet selectors unchanged across both rev007 and rev010.
    ///      Excludes cancelTask, refundExpired (changed in rev007) and createTask (changed in rev010).
    function _coreRevIntegrityUnchangedSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](18);
        s[0] = bytes4(keccak256("BOUNTY()"));
        s[1] = bytes4(keccak256("CLAIM()"));
        s[2] = bytes4(keccak256("PITCH()"));
        s[3] = bytes4(keccak256("BENCHMARK()"));
        s[4] = bytes4(keccak256("AUCTION()"));
        s[5] = bytes4(keccak256("AUCTION_DUTCH()"));
        s[6] = bytes4(keccak256("AUCTION_ENGLISH()"));
        s[7] = bytes4(keccak256("AUCTION_REVERSE_DUTCH()"));
        s[8] = bytes4(keccak256("AUCTION_REVERSE_ENGLISH()"));
        s[9] = bytes4(keccak256("MAX_BIDS_PER_TASK()"));
        s[10] = CoreFacet.claimTask.selector;
        s[11] = CoreFacet.selectWorker.selector;
        s[12] = CoreFacet.submitPitch.selector;
        s[13] = CoreFacet.submitProof.selector;
        s[14] = CoreFacet.submitWork.selector;
        s[15] = CoreFacet.forfeitAndReopen.selector;
        s[16] = CoreFacet.updateTask.selector;
        s[17] = CoreFacet.rejectSubmission.selector;
    }

    /// @dev 20 CoreFacet selectors present after rev007 but before rev010 (excludes createTask).
    ///      Used in the rev010 migration path Replace cut.
    function _coreExistingSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](20);
        s[0] = bytes4(keccak256("BOUNTY()"));
        s[1] = bytes4(keccak256("CLAIM()"));
        s[2] = bytes4(keccak256("PITCH()"));
        s[3] = bytes4(keccak256("BENCHMARK()"));
        s[4] = bytes4(keccak256("AUCTION()"));
        s[5] = bytes4(keccak256("AUCTION_DUTCH()"));
        s[6] = bytes4(keccak256("AUCTION_ENGLISH()"));
        s[7] = bytes4(keccak256("AUCTION_REVERSE_DUTCH()"));
        s[8] = bytes4(keccak256("AUCTION_REVERSE_ENGLISH()"));
        s[9] = bytes4(keccak256("MAX_BIDS_PER_TASK()"));
        s[10] = CoreFacet.claimTask.selector;
        s[11] = CoreFacet.selectWorker.selector;
        s[12] = CoreFacet.submitPitch.selector;
        s[13] = CoreFacet.submitProof.selector;
        s[14] = CoreFacet.submitWork.selector;
        s[15] = CoreFacet.forfeitAndReopen.selector;
        s[16] = CoreFacet.updateTask.selector;
        s[17] = CoreFacet.rejectSubmission.selector;
        s[18] = CoreFacet.cancelTask.selector;
        s[19] = CoreFacet.refundExpired.selector;
    }

    /// @dev 21 RegistryFacet selectors present before the submission-integrity upgrade (rev007).
    function _regPreIntegritySelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](21);
        s[0] = RegistryFacet.getTask.selector;
        s[1] = RegistryFacet.getWorkerStats.selector;
        s[2] = RegistryFacet.requesterNonce.selector;
        s[3] = RegistryFacet.getTaskState.selector;
        s[4] = RegistryFacet.getTaskContext.selector;
        s[5] = RegistryFacet.getTaskVerdict.selector;
        s[6] = RegistryFacet.evaluatorFor.selector;
        s[7] = RegistryFacet.taskMode.selector;
        s[8] = RegistryFacet.defaultFeeBps.selector;
        s[9] = RegistryFacet.feeRecipient.selector;
        s[10] = RegistryFacet.totalFeesCollected.selector;
        s[11] = RegistryFacet.feeForTask.selector;
        s[12] = RegistryFacet.reputationRegistry.selector;
        s[13] = RegistryFacet.getTaskEvaluatorConfig.selector;
        s[14] = RegistryFacet.getTaskAuctionConfig.selector;
        s[15] = RegistryFacet.getTaskMetadata.selector;
        s[16] = RegistryFacet.getTaskPitchConfig.selector;
        s[17] = RegistryFacet.getBids.selector;
        s[18] = RegistryFacet.usdcToken.selector;
        s[19] = RegistryFacet.taskPitchHashes.selector;
        s[20] = RegistryFacet.taskProofHashes.selector;
    }

    /// @dev 8 new RegistryFacet selectors added across rev007–rev010 (taskSubmissionHashes + 7 rev010 views).
    ///      Used in Path A to add everything new in one cut.
    function _regAllNewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = RegistryFacet.taskSubmissionHashes.selector;
        s[1] = RegistryFacet.hasWorkerRated.selector;
        s[2] = RegistryFacet.stakeForfeit.selector;
        s[3] = RegistryFacet.taskSubmissionHashExists.selector;
        s[4] = RegistryFacet.taskActiveSubmissionCount.selector;
        s[5] = RegistryFacet.taskHasSubmissions.selector;
        s[6] = RegistryFacet.taskRejectedWorkers.selector;
        s[7] = RegistryFacet.getTaskHooks.selector;
    }

    /// @dev 22 RegistryFacet selectors present after rev007 (includes taskSubmissionHashes).
    ///      Used in Path B as the Replace cut.
    function _regRev009Selectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](22);
        s[0] = RegistryFacet.getTask.selector;
        s[1] = RegistryFacet.getWorkerStats.selector;
        s[2] = RegistryFacet.requesterNonce.selector;
        s[3] = RegistryFacet.getTaskState.selector;
        s[4] = RegistryFacet.getTaskContext.selector;
        s[5] = RegistryFacet.getTaskVerdict.selector;
        s[6] = RegistryFacet.evaluatorFor.selector;
        s[7] = RegistryFacet.taskMode.selector;
        s[8] = RegistryFacet.defaultFeeBps.selector;
        s[9] = RegistryFacet.feeRecipient.selector;
        s[10] = RegistryFacet.totalFeesCollected.selector;
        s[11] = RegistryFacet.feeForTask.selector;
        s[12] = RegistryFacet.reputationRegistry.selector;
        s[13] = RegistryFacet.getTaskEvaluatorConfig.selector;
        s[14] = RegistryFacet.getTaskAuctionConfig.selector;
        s[15] = RegistryFacet.getTaskMetadata.selector;
        s[16] = RegistryFacet.getTaskPitchConfig.selector;
        s[17] = RegistryFacet.getBids.selector;
        s[18] = RegistryFacet.usdcToken.selector;
        s[19] = RegistryFacet.taskPitchHashes.selector;
        s[20] = RegistryFacet.taskProofHashes.selector;
        s[21] = RegistryFacet.taskSubmissionHashes.selector;
    }

    /// @dev 7 new RegistryFacet selectors added in rev010.
    ///      Used in Path B as the Add cut.
    function _regRev010NewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = RegistryFacet.hasWorkerRated.selector;
        s[1] = RegistryFacet.stakeForfeit.selector;
        s[2] = RegistryFacet.taskSubmissionHashExists.selector;
        s[3] = RegistryFacet.taskActiveSubmissionCount.selector;
        s[4] = RegistryFacet.taskHasSubmissions.selector;
        s[5] = RegistryFacet.taskRejectedWorkers.selector;
        s[6] = RegistryFacet.getTaskHooks.selector;
    }
}
