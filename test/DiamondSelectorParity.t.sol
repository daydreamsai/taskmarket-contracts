// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { LibRevision } from "../src/libraries/LibRevision.sol";
import { Rev012Upgrade } from "../script/upgrades/Rev012Upgrade.s.sol";
import { Rev013Upgrade } from "../script/upgrades/Rev013Upgrade.s.sol";
import { Rev014Upgrade } from "../script/upgrades/Rev014Upgrade.s.sol";
import { Rev015Upgrade } from "../script/upgrades/Rev015Upgrade.s.sol";
import { Rev016Upgrade } from "../script/upgrades/Rev016Upgrade.s.sol";
import { Rev017Upgrade } from "../script/upgrades/Rev017Upgrade.s.sol";
import { Rev018Upgrade } from "../script/upgrades/Rev018Upgrade.s.sol";
import { Rev019Upgrade } from "../script/upgrades/Rev019Upgrade.s.sol";
import { Rev020Upgrade } from "../script/upgrades/Rev020Upgrade.s.sol";
import { Rev021Upgrade } from "../script/upgrades/Rev021Upgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title DiamondSelectorParityTest
/// @dev The two properties that keep `diamondVersion` and the diamond's routing honest:
///
///      1. A fresh deploy and a diamond carried forward by the whole RevNNNUpgrade sequence
///         converge on the same per-facet selector set. A fresh deploy is built from
///         FacetSelectors.sol; the step scripts hand-write their own cuts. This is what stops
///         those two descriptions of "the current selector set" from drifting apart.
///      2. A fresh deploy's diamondVersion equals the highest RevNNNUpgrade step present. This
///         is the guard on LibRevision.CURRENT_REVISION: add script/upgrades/Rev021Upgrade.s.sol
///         without bumping the constant and this test goes red, rather than a deploy quietly
///         stamping a revision it is not running.
contract DiamondSelectorParityTest is Test, DiamondTestHelper {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    /// @dev The step scripts resolve their diamond address by chain id, and rev016 onward reject
    ///      an unrecognised chain outright rather than falling back to the testnet address. The
    ///      sequence therefore has to be walked on a chain the scripts actually name, the same
    ///      way Rev016Upgrade.t.sol does it.
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    address internal constant USDC = address(0xACDC);
    address internal constant FEE_RECIPIENT = address(0xFEE0);
    uint16 internal constant FEE_BPS = 500;

    /// @dev The nine-parameter createTask selector a pre-rev014 diamond routed, mirroring
    ///      Rev014Upgrade's own OLD_CREATE_TASK constant. Kept local to this test because it
    ///      describes a historical state, not the steady state FacetSelectors owns.
    bytes4 internal constant PRE_REV014_CREATE_TASK = 0x6025c050;

    address internal owner;

    function setUp() public {
        owner = vm.addr(OWNER_KEY);
    }

    // -------------------------------------------------------------------------
    // 1. Fresh deploy vs the full upgrade sequence
    // -------------------------------------------------------------------------

    /// @dev Deploys two diamonds: one fresh, one placed at rev011 and walked forward by every
    ///      RevNNNUpgrade step in order, then asserts their per-facet selector sets match.
    function test_FreshDeploy_MatchesFullUpgradeSequence() public {
        address freshDiamond = address(deployDiamond(owner, USDC, FEE_RECIPIENT, FEE_BPS));

        address steppedDiamond = address(deployDiamond(owner, USDC, FEE_RECIPIENT, FEE_BPS));
        _rewindToRev011(steppedDiamond);
        _runFullSequence(steppedDiamond);

        assertEq(
            AdminFacet(steppedDiamond).diamondVersion(),
            AdminFacet(freshDiamond).diamondVersion(),
            "upgrade sequence and fresh deploy must report the same revision"
        );
        _assertSameFacetSelectorSets(freshDiamond, steppedDiamond);
    }

    /// @dev Reconstructs rev011-era *routing* on a diamond that was built from current
    ///      FacetSelectors:
    ///        - the pre-rev014 nine-parameter createTask selector is added back (rev014 Removes
    ///          it);
    ///        - rev017's two AdminFacet selectors are removed (rev017 Adds them).
    ///
    ///      Only routing is reconstructed, never bytecode: this repo contains no historical facet
    ///      source, so every facet here is built from current code. That limitation is inherent
    ///      to running the sequence in-tree. What this test proves is that the cuts compose to
    ///      the right selector set, not that the historical implementations behaved as they did.
    ///
    ///      Note what is NOT removed: the current `createTask` selector stays routed, because
    ///      rev012, rev013 and rev016 each Replace the current
    ///      `FacetSelectors.coreFacetSelectors()` list and a Replace on an unrouted selector
    ///      reverts. See _runFullSequence for the consequence.
    function _rewindToRev011(address diamond) internal {
        address coreFacet = IDiamondLoupe(diamond).facetAddress(CoreFacet.createTask.selector);

        bytes4[] memory preRev014CreateTask = new bytes4[](1);
        preRev014CreateTask[0] = PRE_REV014_CREATE_TASK;

        bytes4[] memory rev017AdminSelectors = new bytes4[](2);
        rev017AdminSelectors[0] = AdminFacet.minAppealWindowSecs.selector;
        rev017AdminSelectors[1] = AdminFacet.setMinAppealWindowSecs.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(coreFacet, IDiamondCut.FacetCutAction.Add, preRev014CreateTask);
        cuts[1] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, rev017AdminSelectors);

        vm.prank(owner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        placeAtVersion(diamond, 11);
    }

    /// @dev Runs every step script from rev012 to the head of the sequence.
    ///
    ///      One honest gap, stated plainly rather than hidden: the sequence is not internally
    ///      consistent about `createTask`, so no single starting routing state satisfies all of
    ///      it. Rev012, rev013 and rev016 Replace `FacetSelectors.coreFacetSelectors()` -- the
    ///      list as it stands today, which includes rev018's evaluator-aware selector -- so that
    ///      selector has to be routed for them to run. Rev018 then Adds the same selector, which
    ///      requires it to be absent. Both cannot hold, because rev012 and rev013 were written
    ///      against a `coreFacetSelectors()` that has since changed under them. The single
    ///      reconstruction below unroutes that selector between rev017 and rev018.
    ///
    ///      Every other step runs for real, including rev014, whose Remove/Replace/Add is
    ///      exercised against the reconstructed pre-rev014 routing rather than skipped by nudging
    ///      the version counter past it.
    function _runFullSequence(address diamond) internal {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        vm.setEnv("FORGE_DEV_PRIVATE_KEY", vm.toString(OWNER_KEY));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_TESTNET", vm.toString(diamond));
        vm.setEnv("FORGE_DIAMOND_ADDRESS_MAINNET", vm.toString(diamond));

        new Rev012Upgrade().run();
        new Rev013Upgrade().run();
        new Rev014Upgrade().run();
        new Rev015Upgrade().run();
        new Rev016Upgrade().run();
        new Rev017Upgrade().run();

        _dropCurrentCreateTaskSelector(diamond);

        new Rev018Upgrade().run();
        new Rev019Upgrade().run();
        new Rev020Upgrade().run();
        new Rev021Upgrade().run();
    }

    /// @dev The one reconstruction _runFullSequence documents: unroute the evaluator-aware
    ///      createTask selector so rev018 can Add it, as it did on a real rev017 diamond.
    function _dropCurrentCreateTaskSelector(address diamond) internal {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = CoreFacet.createTask.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, sel);
        vm.prank(owner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
    }

    // -------------------------------------------------------------------------
    // 2. Fresh-deploy version seed vs the highest upgrade step
    // -------------------------------------------------------------------------

    /// @dev The tripwire for LibRevision.CURRENT_REVISION. The highest step is discovered by
    ///      listing script/upgrades/ rather than hardcoded here, so adding Rev021Upgrade.s.sol is
    ///      by itself enough to trip it -- nobody has to remember to update this test as well,
    ///      which is the failure mode a hardcoded expectation would have.
    function test_FreshDeployVersion_MatchesHighestUpgradeStep() public {
        address diamond = address(deployDiamond(owner, USDC, FEE_RECIPIENT, FEE_BPS));

        uint256 highest = _highestUpgradeStepTarget();
        assertGt(highest, 0, "no RevNNNUpgrade step scripts found -- is the fs_permissions path right?");
        assertEq(
            AdminFacet(diamond).diamondVersion(),
            highest,
            "fresh deploy diamondVersion must equal the highest RevNNNUpgrade step -- bump LibRevision.CURRENT_REVISION"
        );
        assertEq(
            AdminFacet(diamond).diamondVersion(),
            LibRevision.CURRENT_REVISION,
            "fresh deploy must seed diamondVersion from LibRevision.CURRENT_REVISION"
        );
    }

    function _highestUpgradeStepTarget() internal view returns (uint256 highest) {
        VmSafe.DirEntry[] memory entries = vm.readDir("script/upgrades");
        for (uint256 i = 0; i < entries.length; i++) {
            uint256 target = _revisionFromPath(entries[i].path);
            if (target > highest) highest = target;
        }
    }

    /// @dev Parses NNN out of a `.../RevNNNUpgrade.s.sol` path. Returns 0 for anything else.
    ///      Digits appear nowhere else in these filenames, so collecting every digit after the
    ///      last path separator is sufficient and does not need to anchor on "Rev".
    function _revisionFromPath(string memory path) internal pure returns (uint256) {
        bytes memory b = bytes(path);
        uint256 start;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == "/") start = i + 1;
        }
        uint256 value;
        bool sawDigit;
        for (uint256 i = start; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 0x30 && c <= 0x39) {
                value = value * 10 + (c - 0x30);
                sawDigit = true;
            }
        }
        return sawDigit ? value : 0;
    }

    // -------------------------------------------------------------------------
    // Comparison helpers
    // -------------------------------------------------------------------------

    /// @dev Compares the two diamonds facet by facet, not just as one flat selector set: a
    ///      selector that migrated from one facet to another would leave the flat set identical
    ///      while changing what actually executes.
    ///
    ///      Facets are matched by their canonical (sorted) selector list rather than by address
    ///      or by position in `facets()`, both of which legitimately differ between two
    ///      independently deployed diamonds even when every logical facet matches.
    function _assertSameFacetSelectorSets(address a, address b) private view {
        IDiamondLoupe.Facet[] memory fa = IDiamondLoupe(a).facets();
        IDiamondLoupe.Facet[] memory fb = IDiamondLoupe(b).facets();
        assertEq(fa.length, fb.length, "facet count mismatch");

        bytes32[] memory ha = _facetFingerprints(fa);
        bytes32[] memory hb = _facetFingerprints(fb);
        _sortBytes32(ha);
        _sortBytes32(hb);
        for (uint256 i = 0; i < ha.length; i++) {
            assertEq(ha[i], hb[i], "per-facet selector set mismatch");
        }
    }

    function _facetFingerprints(IDiamondLoupe.Facet[] memory facets) private pure returns (bytes32[] memory out) {
        out = new bytes32[](facets.length);
        for (uint256 i = 0; i < facets.length; i++) {
            bytes4[] memory sels = facets[i].functionSelectors;
            _sortBytes4(sels);
            out[i] = keccak256(abi.encodePacked(sels));
        }
    }

    function _sortBytes4(bytes4[] memory arr) private pure {
        for (uint256 i = 1; i < arr.length; i++) {
            bytes4 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }

    function _sortBytes32(bytes32[] memory arr) private pure {
        for (uint256 i = 1; i < arr.length; i++) {
            bytes32 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }
}
