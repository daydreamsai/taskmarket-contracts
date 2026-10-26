// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IDiamondCut } from "../interfaces/IDiamondCut.sol";

/// @title LibDiamond — EIP-2535 core storage, routing, and ownership
/// @dev DiamondStorage is stored at a fixed keccak256 slot separate from AppStorage.
///      Ownership uses a custom 2-step transfer; no OZ Ownable dependency.
library LibDiamond {
    bytes32 internal constant DIAMOND_STORAGE_SLOT = keccak256("eip2535.diamond.storage");

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        mapping(bytes4 => bool) supportedInterfaces;
        address contractOwner;
        address pendingOwner;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotContractOwner(address caller, address owner);
    error NotPendingOwner(address caller, address pendingOwner);
    error InitFunctionReverted(address initAddress, bytes data);
    error IncorrectFacetCutAction();
    error NoSelectorsGiven();
    error FunctionAlreadyExists(bytes4 selector);
    error FacetHasNoCode(address facet);
    error FunctionNotFound(bytes4 selector);

    // -------------------------------------------------------------------------
    // Storage getter
    // -------------------------------------------------------------------------

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 slot = DIAMOND_STORAGE_SLOT;
        assembly {
            ds.slot := slot
        }
    }

    // -------------------------------------------------------------------------
    // Ownership
    // -------------------------------------------------------------------------

    function setContractOwner(address newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        emit OwnershipTransferred(address(0), newOwner);
        ds.contractOwner = newOwner;
    }

    function enforceIsContractOwner() internal view {
        DiamondStorage storage ds = diamondStorage();
        if (msg.sender != ds.contractOwner) {
            revert NotContractOwner(msg.sender, ds.contractOwner);
        }
    }

    /// @notice Initiate 2-step ownership transfer. Only callable by current owner.
    function transferOwnership(address newOwner) internal {
        enforceIsContractOwner();
        DiamondStorage storage ds = diamondStorage();
        ds.pendingOwner = newOwner;
        emit OwnershipTransferStarted(ds.contractOwner, newOwner);
    }

    /// @notice Accept pending ownership transfer. Only callable by pendingOwner.
    function acceptOwnership() internal {
        DiamondStorage storage ds = diamondStorage();
        if (msg.sender != ds.pendingOwner) {
            revert NotPendingOwner(msg.sender, ds.pendingOwner);
        }
        address old = ds.contractOwner;
        ds.contractOwner = msg.sender;
        ds.pendingOwner = address(0);
        emit OwnershipTransferred(old, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Diamond cut
    // -------------------------------------------------------------------------

    function diamondCut(IDiamondCut.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) internal {
        for (uint256 facetIndex; facetIndex < _diamondCut.length; facetIndex++) {
            IDiamondCut.FacetCutAction action = _diamondCut[facetIndex].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                _addFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                _replaceFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                _removeFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else {
                revert IncorrectFacetCutAction();
            }
        }
        emit IDiamondCut.DiamondCut(_diamondCut, _init, _calldata);
        _initializeDiamondCut(_init, _calldata);
    }

    function _addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) revert NoSelectorsGiven();
        DiamondStorage storage ds = diamondStorage();
        enforceHasContractCode(_facetAddress);
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        if (selectorPosition == 0) {
            _addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            if (ds.selectorToFacetAndPosition[selector].facetAddress != address(0)) {
                revert FunctionAlreadyExists(selector);
            }
            _addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function _replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) revert NoSelectorsGiven();
        DiamondStorage storage ds = diamondStorage();
        enforceHasContractCode(_facetAddress);
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        if (selectorPosition == 0) {
            _addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacetAddress == _facetAddress) revert FunctionAlreadyExists(selector);
            _removeFunction(ds, oldFacetAddress, selector);
            _addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function _removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length == 0) revert NoSelectorsGiven();
        // remove address is always address(0) for Remove action
        if (_facetAddress != address(0)) revert IncorrectFacetCutAction();
        DiamondStorage storage ds = diamondStorage();
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            _removeFunction(ds, oldFacetAddress, selector);
        }
    }

    function _addFacet(DiamondStorage storage ds, address _facetAddress) internal {
        ds.facetFunctionSelectors[_facetAddress].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(_facetAddress);
    }

    function _addFunction(DiamondStorage storage ds, bytes4 _selector, uint96 _selectorPosition, address _facetAddress)
        internal
    {
        ds.selectorToFacetAndPosition[_selector].functionSelectorPosition = _selectorPosition;
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.push(_selector);
        ds.selectorToFacetAndPosition[_selector].facetAddress = _facetAddress;
    }

    function _removeFunction(DiamondStorage storage ds, address _facetAddress, bytes4 _selector) internal {
        if (_facetAddress == address(0)) revert FunctionNotFound(_selector);
        uint256 selectorPosition = ds.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[_facetAddress].functionSelectors.length - 1;
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[_facetAddress].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[_facetAddress].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[_selector];
        if (lastSelectorPosition == 0) {
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[_facetAddress];
        }
    }

    function _initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) return;
        enforceHasContractCode(_init);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        if (!success) {
            if (error.length > 0) {
                assembly {
                    let returndata_size := mload(error)
                    revert(add(32, error), returndata_size)
                }
            } else {
                revert InitFunctionReverted(_init, _calldata);
            }
        }
    }

    function enforceHasContractCode(address _contract) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        if (contractSize == 0) revert FacetHasNoCode(_contract);
    }
}
