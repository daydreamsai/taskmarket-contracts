// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { IDiamondLoupe } from "../interfaces/IDiamondLoupe.sol";
import { IDiamondCut } from "../interfaces/IDiamondCut.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { ITMPRegistry } from "../interfaces/ITMPRegistry.sol";
import { ITMPReputation } from "../interfaces/ITMPReputation.sol";
import { ITMPFees } from "../interfaces/ITMPFees.sol";
import { ITMPModes } from "../interfaces/ITMPModes.sol";

/// @title DiamondLoupeFacet — EIP-2535 introspection + ERC-165
/// @notice Provides facet and selector enumeration for off-chain tooling and
///         ERC-165 interface detection for all supported TMP interfaces.
contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    /// @notice Gets all facets and their selectors.
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddr = ds.facetAddresses[i];
            facets_[i].facetAddress = facetAddr;
            facets_[i].functionSelectors = ds.facetFunctionSelectors[facetAddr].functionSelectors;
        }
    }

    /// @notice Gets all function selectors for a given facet.
    function facetFunctionSelectors(address _facet)
        external
        view
        override
        returns (bytes4[] memory facetFunctionSelectors_)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetFunctionSelectors_ = ds.facetFunctionSelectors[_facet].functionSelectors;
    }

    /// @notice Gets all facet addresses.
    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddresses_ = ds.facetAddresses;
    }

    /// @notice Gets the facet address for a given selector.
    function facetAddress(bytes4 _functionSelector) external view override returns (address facetAddress_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddress_ = ds.selectorToFacetAndPosition[_functionSelector].facetAddress;
    }

    /// @notice ERC-165 interface detection.
    ///         Returns true for all interfaces advertised by the Diamond.
    /// @dev The ITMP interface IDs are hardcoded rather than derived from the selector registry
    ///      because the registry maps selectors to facet addresses, not interface memberships.
    ///      Trade-off: if a facet implementing one of these interfaces is removed via diamondCut
    ///      without updating this function, supportsInterface will return a false positive.
    ///      Operators must keep this list in sync with the deployed facet set. The
    ///      ds.supportedInterfaces mapping provides an escape hatch for dynamic overrides.
    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.supportedInterfaces[interfaceId] || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IDiamondCut).interfaceId || interfaceId == type(IDiamondLoupe).interfaceId
            || interfaceId == type(ITMPCore).interfaceId || interfaceId == type(ITMPEvaluator).interfaceId
            || interfaceId == type(ITMPRegistry).interfaceId || interfaceId == type(ITMPReputation).interfaceId
            || interfaceId == type(ITMPFees).interfaceId || interfaceId == type(ITMPModes).interfaceId;
    }
}
