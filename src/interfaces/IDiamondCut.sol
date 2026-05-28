// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDiamondCut — EIP-2535 diamond cut interface
interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Emitted when diamondCut is called.
    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);

    /// @notice Add/replace/remove any number of functions and optionally execute
    ///         a function with delegatecall.
    /// @param _diamondCut Contains facet addresses and function selectors
    /// @param _init Address to delegatecall for initialization (address(0) = skip)
    /// @param _calldata Calldata for the _init delegatecall
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external;
}
