// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev ERC-721-style ownerOf: reverts for an agent ID that was never minted.
contract MockIdentityRegistry {
    mapping(uint256 => address) public owners;

    function mint(uint256 agentId, address owner) external {
        owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address owner) {
        owner = owners[agentId];
        require(owner != address(0), "ERC721NonexistentToken");
    }
}

/// @dev An identity registry whose every call reverts.
contract MockRevertingIdentityRegistry {
    fallback() external {
        revert("registry down");
    }
}
