// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDiamondLoupe — EIP-2535 diamond loupe interface
interface IDiamondLoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice Gets all facets and their selectors.
    function facets() external view returns (Facet[] memory facets_);

    /// @notice Gets all function selectors provided by a facet.
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_);

    /// @notice Get all the facet addresses used by a diamond.
    function facetAddresses() external view returns (address[] memory facetAddresses_);

    /// @notice Gets the facet that supports the given selector.
    ///         Returns address(0) if not found.
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}
