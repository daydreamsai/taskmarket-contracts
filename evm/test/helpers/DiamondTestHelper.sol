// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { Diamond } from "../../src/Diamond.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { DiamondCutFacet } from "../../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../../src/facets/AdminFacet.sol";
import { CoreFacet } from "../../src/facets/CoreFacet.sol";
import { AuctionFacet } from "../../src/facets/AuctionFacet.sol";
import { AcceptanceFacet } from "../../src/facets/AcceptanceFacet.sol";
import { EvaluatorFacet } from "../../src/facets/EvaluatorFacet.sol";
import { RatingFacet } from "../../src/facets/RatingFacet.sol";
import { RegistryFacet } from "../../src/facets/RegistryFacet.sol";
import { SettlementFacet } from "../../src/facets/SettlementFacet.sol";
import { FeedbackFacet } from "../../src/facets/FeedbackFacet.sol";
import { WorkerFacet } from "../../src/facets/WorkerFacet.sol";
import { ProjectFacet } from "../../src/facets/ProjectFacet.sol";
import { FundingPool } from "../../src/FundingPool.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITMPProject } from "../../src/interfaces/ITMPProject.sol";
import { ITMPDiamond } from "../../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../../src/interfaces/ITMPTerms.sol";
import { FacetSelectors } from "../../script/lib/FacetSelectors.sol";

/// @dev Shared Diamond deploy helper for test setUp functions.
///      Call deployDiamond(owner, usdc, feeRecipient, feeBps) and get back
///      an ITMPDiamond-typed proxy that routes all calls to the correct facet.
abstract contract DiamondTestHelper is Test {
    function deployDiamond(address _owner, address _usdc, address _feeRecipient, uint16 _feeBps)
        internal
        returns (ITMPDiamond)
    {
        IDiamondCut.FacetCut[] memory cuts = _facetCuts();
        address adminFacet = cuts[2].facetAddress;

        bytes memory initData = abi.encodeCall(AdminFacet.initialize, (_usdc, _feeRecipient, _feeBps));
        Diamond diamond = new Diamond(_owner, cuts, adminFacet, initData);
        return ITMPDiamond(address(diamond));
    }

    /// @dev Deploys the real funding pool behind a proxy and sets it on `diamond` as `_owner`. Not part of
    ///      deployDiamond: the rev027 upgrade script calls initFundingPool after its cut, and a
    ///      second call would revert. Tests that open projects call this after deploying.
    function initMockPool(address diamond, address _owner) internal returns (FundingPool pool) {
        address token = ITMPDiamond(diamond).usdcToken();
        pool = FundingPool(
            address(
                new ERC1967Proxy(address(new FundingPool()), abi.encodeCall(FundingPool.initialize, (diamond, token)))
            )
        );
        vm.prank(_owner);
        ITMPProject(diamond).initFundingPool(address(pool));
    }

    /// @dev Deploys every facet and returns the full Add cut. Separate from deployDiamond so the
    ///      ten facet cuts do not share one stack frame with the deploy.
    function _facetCuts() internal returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](13);
        cuts[0] = IDiamondCut.FacetCut(
            address(new DiamondCutFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.cutFacetSelectors()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new DiamondLoupeFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.loupeFacetSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(new AdminFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.adminFacetSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(new CoreFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.coreFacetSelectors()
        );
        cuts[4] = IDiamondCut.FacetCut(
            address(new AuctionFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.auctionFacetSelectors()
        );
        cuts[5] = IDiamondCut.FacetCut(
            address(new AcceptanceFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.acceptFacetSelectors()
        );
        cuts[6] = IDiamondCut.FacetCut(
            address(new EvaluatorFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.evalFacetSelectors()
        );
        cuts[7] = IDiamondCut.FacetCut(
            address(new RatingFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.ratingFacetSelectors()
        );
        cuts[8] = IDiamondCut.FacetCut(
            address(new RegistryFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.registryFacetSelectors()
        );
        cuts[9] = IDiamondCut.FacetCut(
            address(new SettlementFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.settlementFacetSelectors()
        );
        cuts[10] = IDiamondCut.FacetCut(
            address(new FeedbackFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.feedbackFacetSelectors()
        );
        cuts[11] = IDiamondCut.FacetCut(
            address(new WorkerFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.workerFacetSelectors()
        );
        cuts[12] = IDiamondCut.FacetCut(
            address(new ProjectFacet()), IDiamondCut.FacetCutAction.Add, FacetSelectors.projectFacetSelectors()
        );
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
        if (_version < 26) _routeRemovedRev026(diamond, _owner);
        placeAtVersion(diamond, _version);
    }

    /// @dev Route the selectors rev026 Removes, so an earlier step's Replace and rev026's Remove
    ///      find them. The current facets no longer implement them: a call reverts, as on a
    ///      diamond with no route.
    function _routeRemovedRev026(address diamond, address _owner) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        bytes4[] memory core = new bytes4[](1);
        core[0] = FacetSelectors.REV018_CREATE_TASK;
        bytes4[] memory settlement = new bytes4[](1);
        settlement[0] = FacetSelectors.NORMALIZE_TERMS;
        cuts[0] = IDiamondCut.FacetCut(
            IDiamondLoupe(diamond).facetAddress(ITMPTerms.createTask.selector), IDiamondCut.FacetCutAction.Add, core
        );
        cuts[1] = IDiamondCut.FacetCut(
            IDiamondLoupe(diamond).facetAddress(FacetSelectors.settlementFacetSelectorsFromCore()[0]),
            IDiamondCut.FacetCutAction.Add,
            settlement
        );
        vm.prank(_owner);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
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
