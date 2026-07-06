// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./helpers/DiamondTestHelper.sol";
import "../src/interfaces/ITMPDiamond.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { Diamond } from "../src/Diamond.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../src/facets/DiamondLoupeFacet.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPRegistry } from "../src/interfaces/ITMPRegistry.sol";
import { ITMPEvaluator } from "../src/interfaces/ITMPEvaluator.sol";
import { ITMPModes } from "../src/interfaces/ITMPModes.sol";
import { ITMPFees } from "../src/interfaces/ITMPFees.sol";
import { ITMPReputation } from "../src/interfaces/ITMPReputation.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./mocks/MockUSDC.sol";

contract MockPingFacet {
    function ping() external pure returns (bytes32) {
        return keccak256("pong");
    }
}

contract MockRevertingInit {
    function initialize() external pure {
        revert("MockRevertingInit: intentional revert");
    }
}

/// @title DiamondTest — tests for Diamond proxy routing, diamondCut, ownership, and ERC-165.
contract DiamondTest is DiamondTestHelper {
    ITMPDiamond public diamond;
    MockUSDC public usdc;

    address public owner = address(0x1);
    address public nonOwner = address(0x2);
    address public feeRecipient = address(0x3);

    uint16 public constant FEE_BPS = 500;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        diamond = deployDiamond(owner, address(usdc), feeRecipient, FEE_BPS);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // diamondCut ADD: new selector routes to new facet
    // -------------------------------------------------------------------------

    function test_DiamondCut_Add_NewSelectorRoutes() public {
        MockPingFacet mockPing = new MockPingFacet();

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = MockPingFacet.ping.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(mockPing), IDiamondCut.FacetCutAction.Add, sels);

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        // The loupe must report the mock facet address for the new selector.
        address registered = IDiamondLoupe(address(diamond)).facetAddress(MockPingFacet.ping.selector);
        assertEq(registered, address(mockPing));

        // A low-level call through the diamond proxy must succeed and return keccak256("pong").
        (bool ok, bytes memory ret) = address(diamond).call(abi.encodeWithSelector(MockPingFacet.ping.selector));
        assertTrue(ok, "ping call through diamond must succeed");
        bytes32 result = abi.decode(ret, (bytes32));
        assertEq(result, keccak256("pong"));
    }

    function test_DiamondCut_Add_DuplicateSelectorReverts() public {
        CoreFacet newCore = new CoreFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CoreFacet.createTask.selector; // already registered

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newCore), IDiamondCut.FacetCutAction.Add, sels);

        vm.prank(owner);
        vm.expectRevert(); // CannotAddFunctionToDiamondThatAlreadyExists
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    // -------------------------------------------------------------------------
    // diamondCut REPLACE: selector reroutes to new implementation
    // -------------------------------------------------------------------------

    function test_DiamondCut_Replace_SelectorReroutesToNewImpl() public {
        // Deploy a new RegistryFacet (same bytecode, new address).
        RegistryFacet newRegistry = new RegistryFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = RegistryFacet.getTask.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newRegistry), IDiamondCut.FacetCutAction.Replace, sels);

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        // After REPLACE, the loupe should report the new facet address for getTask.
        address facetAddr = IDiamondLoupe(address(diamond)).facetAddress(RegistryFacet.getTask.selector);
        assertEq(facetAddr, address(newRegistry));
    }

    function test_DiamondCut_Replace_SameAddressReverts() public {
        // REPLACE with the same implementation address should revert.
        address existingFacet = IDiamondLoupe(address(diamond)).facetAddress(RegistryFacet.getTask.selector);
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = RegistryFacet.getTask.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(existingFacet, IDiamondCut.FacetCutAction.Replace, sels);

        vm.prank(owner);
        vm.expectRevert(); // CannotReplaceFunctionWithTheSameFunctionFromTheSameFacet
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    // -------------------------------------------------------------------------
    // diamondCut REMOVE: selector reverts after removal
    // -------------------------------------------------------------------------

    function test_DiamondCut_Remove_SelectorRevertsAfterRemoval() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = RegistryFacet.totalFeesCollected.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, sels);

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        // After removal, calling the selector should revert with "Diamond: function not found".
        (bool ok,) = address(diamond).call(abi.encodeWithSelector(RegistryFacet.totalFeesCollected.selector));
        assertFalse(ok, "Removed selector must revert");
    }

    // -------------------------------------------------------------------------
    // supportsInterface — ERC-165 for all advertised interfaces
    // -------------------------------------------------------------------------

    function test_SupportsInterface_IERC165() public view {
        assertTrue(diamond.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterface_IDiamondCut() public view {
        assertTrue(diamond.supportsInterface(type(IDiamondCut).interfaceId));
    }

    function test_SupportsInterface_IDiamondLoupe() public view {
        assertTrue(diamond.supportsInterface(type(IDiamondLoupe).interfaceId));
    }

    function test_SupportsInterface_ITMPCore() public view {
        assertTrue(diamond.supportsInterface(type(ITMPCore).interfaceId));
    }

    function test_SupportsInterface_ITMPEvaluator() public view {
        assertTrue(diamond.supportsInterface(type(ITMPEvaluator).interfaceId));
    }

    function test_SupportsInterface_ITMPRegistry() public view {
        assertTrue(diamond.supportsInterface(type(ITMPRegistry).interfaceId));
    }

    function test_SupportsInterface_ITMPModes() public view {
        assertTrue(diamond.supportsInterface(type(ITMPModes).interfaceId));
    }

    function test_SupportsInterface_ITMPFees() public view {
        assertTrue(diamond.supportsInterface(type(ITMPFees).interfaceId));
    }

    function test_SupportsInterface_ITMPReputation() public view {
        assertTrue(diamond.supportsInterface(type(ITMPReputation).interfaceId));
    }

    function test_SupportsInterface_Unknown_False() public view {
        assertFalse(diamond.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_SupportsInterface_AllFFs_False() public view {
        assertFalse(diamond.supportsInterface(0xffffffff));
    }

    // -------------------------------------------------------------------------
    // Ownership — only owner can call diamondCut
    // -------------------------------------------------------------------------

    function test_DiamondCut_OnlyOwner_NonOwnerReverts() public {
        CoreFacet newCore = new CoreFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CoreFacet.claimTask.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newCore), IDiamondCut.FacetCutAction.Replace, sels);

        vm.prank(nonOwner);
        vm.expectRevert();
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    function test_DiamondCut_OwnerSucceeds() public {
        RegistryFacet newReg = new RegistryFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = RegistryFacet.getTask.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newReg), IDiamondCut.FacetCutAction.Replace, sels);

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), ""); // must not revert
    }

    // -------------------------------------------------------------------------
    // Ownership — 2-step transfer
    // -------------------------------------------------------------------------

    function test_Ownership_Owner() public view {
        assertEq(diamond.owner(), owner);
    }

    function test_Ownership_PendingOwner_InitiallyZero() public view {
        assertEq(diamond.pendingOwner(), address(0));
    }

    function test_Ownership_TransferAndAccept() public {
        vm.prank(owner);
        diamond.transferOwnership(nonOwner);
        assertEq(diamond.pendingOwner(), nonOwner);
        assertEq(diamond.owner(), owner); // not yet accepted

        vm.prank(nonOwner);
        diamond.acceptOwnership();
        assertEq(diamond.owner(), nonOwner);
        assertEq(diamond.pendingOwner(), address(0));
    }

    function test_Ownership_AcceptOwnership_NonPendingReverts() public {
        vm.prank(owner);
        diamond.transferOwnership(nonOwner);

        vm.prank(address(0x99));
        vm.expectRevert();
        diamond.acceptOwnership();
    }

    // -------------------------------------------------------------------------
    // DiamondLoupe — facets() and facetAddresses() completeness
    // -------------------------------------------------------------------------

    function test_Loupe_FacetAddresses_NonEmpty() public view {
        address[] memory addrs = IDiamondLoupe(address(diamond)).facetAddresses();
        assertGt(addrs.length, 0, "Must have at least one facet registered");
        assertEq(addrs.length, 9, "Exactly 9 facets expected");
    }

    function test_Loupe_FacetAddress_CreateTask() public view {
        address facet = IDiamondLoupe(address(diamond)).facetAddress(CoreFacet.createTask.selector);
        assertNotEq(facet, address(0), "createTask must route to a facet");
    }

    function test_Loupe_UnregisteredSelector_ZeroAddress() public view {
        address facet = IDiamondLoupe(address(diamond)).facetAddress(bytes4(0xdeadbeef));
        assertEq(facet, address(0));
    }

    function test_Loupe_Facets_ReturnsAllFacetsWithSelectors() public view {
        IDiamondLoupe.Facet[] memory allFacets = IDiamondLoupe(address(diamond)).facets();
        assertEq(allFacets.length, 9, "Exactly 9 facets expected");
        for (uint256 i = 0; i < allFacets.length; i++) {
            assertNotEq(allFacets[i].facetAddress, address(0), "Facet address must be non-zero");
            assertGt(allFacets[i].functionSelectors.length, 0, "Each facet must expose at least one selector");
        }
    }

    function test_Loupe_FacetFunctionSelectors_ReturnsSelectorsForLoupe() public view {
        address loupeAddr = IDiamondLoupe(address(diamond)).facetAddress(DiamondLoupeFacet.facets.selector);
        bytes4[] memory sels = IDiamondLoupe(address(diamond)).facetFunctionSelectors(loupeAddr);
        assertEq(sels.length, 5, "DiamondLoupeFacet exposes exactly 5 selectors");
    }

    function test_Loupe_FacetFunctionSelectors_UnknownAddress_Empty() public view {
        bytes4[] memory sels = IDiamondLoupe(address(diamond)).facetFunctionSelectors(address(0x9999));
        assertEq(sels.length, 0, "Unknown facet address must return empty selector list");
    }

    // -------------------------------------------------------------------------
    // State preservation across upgrade
    // -------------------------------------------------------------------------

    function test_DiamondCut_StatePreservedAfterReplace() public {
        // Verify a view function returns expected post-init value before upgrade.
        assertEq(diamond.feeRecipient(), feeRecipient);

        // Replace RegistryFacet.
        RegistryFacet newReg = new RegistryFacet();
        bytes4[] memory sels = _registrySelectors();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newReg), IDiamondCut.FacetCutAction.Replace, sels);

        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        // AppStorage state must be unchanged after facet replacement.
        assertEq(diamond.feeRecipient(), feeRecipient);
        assertEq(diamond.defaultFeeBps(), FEE_BPS);
        assertEq(diamond.usdcToken(), address(usdc));
    }

    // -------------------------------------------------------------------------
    // LibDiamond: _initializeDiamondCut failure propagates revert data
    // -------------------------------------------------------------------------

    function test_DiamondCut_InitFunctionReverts_PropagatesError() public {
        MockPingFacet mockPing = new MockPingFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = MockPingFacet.ping.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(mockPing), IDiamondCut.FacetCutAction.Add, sels);

        vm.prank(owner);
        vm.expectRevert();
        IDiamondCut(address(diamond)).diamondCut(cuts, address(mockPing), abi.encodeWithSignature("nonExistentFn()"));
    }

    function test_DiamondCut_InitFunctionReverts_WithData_PropagatesRevertData() public {
        MockRevertingInit revertInit = new MockRevertingInit();
        MockPingFacet mockPing = new MockPingFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = MockPingFacet.ping.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(mockPing), IDiamondCut.FacetCutAction.Add, sels);

        vm.prank(owner);
        vm.expectRevert("MockRevertingInit: intentional revert");
        IDiamondCut(address(diamond)).diamondCut(cuts, address(revertInit), abi.encodeWithSignature("initialize()"));
    }
}
