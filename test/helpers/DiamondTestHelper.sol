// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Diamond } from "../../src/Diamond.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { DiamondCutFacet } from "../../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";
import { ITMPDiamond } from "../../src/interfaces/ITMPDiamond.sol";
import { FacetSelectors } from "../../script/lib/FacetSelectors.sol";

/// @dev Shared Diamond deploy helper for test setUp functions.
///      Call deployDiamond(owner, usdc, feeRecipient, feeBps) and get back
///      an ITMPDiamond-typed proxy that routes all calls to the correct facet.
abstract contract DiamondTestHelper is Test {
    function deployDiamond(address _owner, address _usdc, address _feeRecipient, uint16 _feeBps)
        internal
        returns (ITMPDiamond)
    {
        // Deploy facet implementations
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        AdminFacet adminFacet = new AdminFacet();
        CoreFacet coreFacet = new CoreFacet();
        AuctionFacet auctionFacet = new AuctionFacet();
        AcceptanceFacet acceptFacet = new AcceptanceFacet();
        EvaluatorFacet evalFacet = new EvaluatorFacet();
        RatingFacet ratingFacet = new RatingFacet();
        RegistryFacet regFacet = new RegistryFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](9);
        cuts[0] =
            IDiamondCut.FacetCut(address(cutFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.cutFacetSelectors());
        cuts[1] = IDiamondCut.FacetCut(
            address(loupeFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.loupeFacetSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(adminFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.adminFacetSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(coreFacet), IDiamondCut.FacetCutAction.Add, FacetSelectors.coreFacetSelectors()
        );
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

        bytes memory initData = abi.encodeCall(AdminFacet.initialize, (_usdc, _feeRecipient, _feeBps));
        Diamond diamond = new Diamond(_owner, cuts, address(adminFacet), initData);
        return ITMPDiamond(address(diamond));
    }

    /// @dev A fresh deploy placed at an earlier revision, for the RevNNNUpgrade step tests.
    ///      Routing and bytecode are the current build's; only the counter is moved. See
    ///      placeAtVersion for why this cannot go through setDiamondVersion.
    function deployDiamondAtVersion(
        address _owner,
        address _usdc,
        address _feeRecipient,
        uint16 _feeBps,
        uint256 _version
    ) internal returns (address diamond) {
        diamond = address(deployDiamond(_owner, _usdc, _feeRecipient, _feeBps));
        placeAtVersion(diamond, _version);
    }

    /// @dev Storage slot of AppStorage.diamondVersion: the struct's base slot plus the field's
    ///      index in the packed layout. Every field before it occupies a full slot of its own
    ///      except defaultFeeBps/feeRecipient, which pack together (2 + 20 bytes), putting
    ///      diamondVersion at offset 29 rather than 30. AppStorage is append-only per the
    ///      repository's storage-layout rule, so appending a field cannot move this -- but
    ///      inserting one would, which is what placeAtVersion's read-back assertion catches.
    uint256 internal constant DIAMOND_VERSION_SLOT = uint256(keccak256("taskmarket.appstorage.v1")) + 29;

    /// @dev Places a diamond's diamondVersion at an arbitrary revision, including a lower one.
    ///
    ///      A fresh deploy seeds LibRevision.CURRENT_REVISION, so every RevNNNUpgrade step test
    ///      has to rewind before it can exercise a step whose precondition is an earlier
    ///      revision. `setDiamondVersion` deliberately refuses to decrease
    ///      (DiamondVersionNotIncreasing) and that guard is not relaxed for tests, so the counter
    ///      is written directly instead.
    ///
    ///      Only the counter moves. The diamond's selector routing and facet bytecode are
    ///      untouched and remain those of the current build -- these fixtures reconstruct
    ///      historical *routing* where a step's cut depends on it, never historical bytecode,
    ///      which this repo no longer contains.
    function placeAtVersion(address diamond, uint256 version) internal {
        vm.store(diamond, bytes32(DIAMOND_VERSION_SLOT), bytes32(version));
        assertEq(
            AdminFacet(diamond).diamondVersion(),
            version,
            "placeAtVersion: DIAMOND_VERSION_SLOT no longer points at AppStorage.diamondVersion"
        );
    }
}
