// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibDiamond } from "./libraries/LibDiamond.sol";
import { IDiamondCut } from "./interfaces/IDiamondCut.sol";

/// @title Diamond — EIP-2535 proxy contract
/// @notice Permanent proxy address. All logic lives in upgradeable facets.
///         Function calls are routed to the correct facet via the fallback.
///
/// @dev The constructor takes all facets + init calldata to wire up the Diamond
///      atomically in a single transaction. Ownership is set before the cuts run.
///
///      slither-disable: delegatecall-to-arbitrary-address — the fallback routes
///      to facets registered by the owner via diamondCut. The arbitrary-address
///      detector is a false positive here; routing is owner-controlled.
contract Diamond {
    constructor(address _owner, IDiamondCut.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) {
        LibDiamond.setContractOwner(_owner);
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }

    // Receive ETH (no function matched, no calldata)
    receive() external payable { }

    // Route all calls to the appropriate facet via delegatecall.
    // slither-disable-next-line delegatecall-loop
    // solhint-disable-next-line no-complex-fallback
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: function not found");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
