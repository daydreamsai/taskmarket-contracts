// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Diamond } from "../src/Diamond.sol";
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
import { FacetSelectors } from "../script/lib/FacetSelectors.sol";
import { DiamondFullUpgrade } from "../script/DiamondFullUpgrade.s.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";

/// @title DiamondSelectorParityTest
/// @dev rev011: asserts a freshly deployed diamond and a diamond brought to steady state via
///      DiamondFullUpgrade's Path C end up routing the exact same set of selectors. This is the
///      actual enforcement mechanism against DiamondDeploy.s.sol / DiamondFullUpgrade.s.sol
///      selector-list drift (the bug behind issue #160/#161) -- FacetSelectors.sol reduces the
///      chance of drift, but this test is what guarantees it cannot silently reoccur even if a
///      future edit reintroduces a second hand-written list.
contract DiamondSelectorParityTest is Test, DiamondTestHelper {
    address internal constant OWNER = address(0xABCD);
    address internal constant USDC = address(0xACDC);
    address internal constant FEE_RECIPIENT = address(0xFEE0);
    uint16 internal constant FEE_BPS = 500;

    function test_FreshDeploy_MatchesFullUpgradePathC() public {
        // "Fresh deploy" -- DiamondTestHelper shares FacetSelectors.sol with DiamondDeploy.s.sol,
        // so this is exactly what a real fresh deploy's cut looks like.
        address freshDiamond = address(deployDiamond(OWNER, USDC, FEE_RECIPIENT, FEE_BPS));

        // "Upgraded from old state" -- deploy a diamond at the pre-rev011 steady state (every
        // selector current except AdminFacet, which is missing diamondVersion/setDiamondVersion,
        // matching every diamond deployed before this change), then run Path C against it.
        UpgradeRunner runner = new UpgradeRunner();
        address oldStateDiamond = _deployPreRev011Diamond(address(runner));
        runner.upgrade(oldStateDiamond);

        _assertSameRoutedSelectors(freshDiamond, oldStateDiamond);
    }

    function _deployPreRev011Diamond(address _owner) private returns (address) {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        AdminFacet adminFacet = new AdminFacet();
        CoreFacet coreFacet = new CoreFacet();
        AuctionFacet auctionFacet = new AuctionFacet();
        AcceptanceFacet acceptFacet = new AcceptanceFacet();
        EvaluatorFacet evalFacet = new EvaluatorFacet();
        RatingFacet ratingFacet = new RatingFacet();
        RegistryFacet regFacet = new RegistryFacet();

        bytes4[] memory adminPreRev011 = new bytes4[](15);
        adminPreRev011[0] = AdminFacet.paused.selector;
        adminPreRev011[1] = AdminFacet.pause.selector;
        adminPreRev011[2] = AdminFacet.unpause.selector;
        adminPreRev011[3] = AdminFacet.transferOwnership.selector;
        adminPreRev011[4] = AdminFacet.acceptOwnership.selector;
        adminPreRev011[5] = AdminFacet.owner.selector;
        adminPreRev011[6] = AdminFacet.pendingOwner.selector;
        adminPreRev011[7] = AdminFacet.addForwarder.selector;
        adminPreRev011[8] = AdminFacet.removeForwarder.selector;
        adminPreRev011[9] = AdminFacet.isTrustedForwarder.selector;
        adminPreRev011[10] = AdminFacet.setDefaultFeeBps.selector;
        adminPreRev011[11] = AdminFacet.setFeeRecipient.selector;
        adminPreRev011[12] = AdminFacet.setReputationRegistry.selector;
        adminPreRev011[13] = AdminFacet.setDefaultHooks.selector;
        adminPreRev011[14] = AdminFacet.getDefaultHooks.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](9);
        cuts[0] =
            IDiamondCut.FacetCut(address(cutFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.cutFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(
            address(loupeFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.loupeFacetSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(address(adminFacet), IDiamondCut.FacetCutAction.Add, adminPreRev011);
        cuts[3] = IDiamondCut.FacetCut(address(coreFacet), IDiamondCut.FacetCutAction.Add, _corePreRev018Selectors());
        cuts[4] = IDiamondCut.FacetCut(
            address(auctionFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.auctionFacetSelectors()
        );
        cuts[5] = IDiamondCut.FacetCut(
            address(acceptFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.acceptFacetSelectors()
        );
        cuts[6] = IDiamondCut.FacetCut(
            address(evalFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.evalFacetSelectors()
        );
        cuts[7] = IDiamondCut.FacetCut(
            address(ratingFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.ratingFacetSelectors()
        );
        cuts[8] = IDiamondCut.FacetCut(
            address(regFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.registryFacetSelectors()
        );

        bytes memory initData = abi.encodeCall(AdminFacet.initialize, (USDC, FEE_RECIPIENT, FEE_BPS));
        Diamond diamond = new Diamond(_owner, cuts, address(adminFacet), initData);
        return address(diamond);
    }

    /// @dev CoreFacet's selectors as an old diamond routes them: everything in
    ///      FacetSelectors.coreFacetSelectors() except rev018's evaluator-aware createTask, which
    ///      no diamond routes until Path C adds it. Kept local to this test for the same reason
    ///      adminPreRev011 above is -- it describes a historical state, not the steady state that
    ///      FacetSelectors is the source of truth for. Path C ends by Adding the new selector, so
    ///      including it here would make that Add revert on an already-routed selector; omitting
    ///      the legacy one would instead make Path C's Replace revert on a selector that does not
    ///      exist. Either way the parity assertion never gets a chance to lie about drift.
    function _corePreRev018Selectors() private pure returns (bytes4[] memory s) {
        bytes4[] memory current = FacetSelectors.coreFacetSelectors();
        s = new bytes4[](current.length - 1);
        uint256 k;
        for (uint256 i = 0; i < current.length; i++) {
            if (current[i] == FacetSelectors.CREATE_TASK) continue;
            s[k++] = current[i];
        }
    }

    /// @dev Compares the total set of routable selectors, not per-facet groupings -- facet
    ///      addresses (and their array order in `facets()`) legitimately differ between two
    ///      independently deployed diamonds, even when every logical facet's interface matches.
    function _assertSameRoutedSelectors(address a, address b) private view {
        bytes4[] memory selA = _flattenSelectors(a);
        bytes4[] memory selB = _flattenSelectors(b);
        assertEq(selA.length, selB.length, "total selector count mismatch");

        _sort(selA);
        _sort(selB);
        for (uint256 i = 0; i < selA.length; i++) {
            assertEq(selA[i], selB[i], "selector set mismatch");
        }
    }

    function _flattenSelectors(address diamond) private view returns (bytes4[] memory flat) {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(diamond).facets();
        uint256 total;
        for (uint256 i = 0; i < facets.length; i++) {
            total += facets[i].functionSelectors.length;
        }
        flat = new bytes4[](total);
        uint256 k;
        for (uint256 i = 0; i < facets.length; i++) {
            bytes4[] memory sels = facets[i].functionSelectors;
            for (uint256 j = 0; j < sels.length; j++) {
                flat[k++] = sels[j];
            }
        }
    }

    function _sort(bytes4[] memory arr) private pure {
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
}

/// @dev Thin wrapper exposing DiamondFullUpgrade's internal Path C so the parity test can call
///      it directly against a diamond it deployed (and owns) itself, without env vars or
///      broadcast. Owning the target diamond avoids needing vm.prank -- calls made from within
///      _runReplace naturally have msg.sender == address(this).
contract UpgradeRunner is DiamondFullUpgrade {
    function upgrade(address diamond) external {
        address cutFacet = address(new DiamondCutFacet());
        address loupeFacet = address(new DiamondLoupeFacet());
        address adminFacet = address(new AdminFacet());
        address coreFacet = address(new CoreFacet());
        address auctionFacet = address(new AuctionFacet());
        address acceptFacet = address(new AcceptanceFacet());
        address evalFacet = address(new EvaluatorFacet());
        address ratingFacet = address(new RatingFacet());
        address regFacet = address(new RegistryFacet());

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
}
