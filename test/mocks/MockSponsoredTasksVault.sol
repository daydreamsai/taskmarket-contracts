// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SponsoredTaskTypes } from "../../src/hooks/sponsored-task/SponsoredTaskTypes.sol";

/// @notice A lookalike whose economic methods deliberately do nothing. It proves official
///         vault attestation is required instead of trusting an ABI-compatible address.
contract MockSponsoredTasksVault {
    bytes32 public vaultId;
    address public token;
    address public owner;
    address public controller;
    uint256 public settlementChain;
    uint64 public epoch = 1;

    constructor(bytes32 vaultId_, address token_, address owner_, address controller_) {
        vaultId = vaultId_;
        token = token_;
        owner = owner_;
        controller = controller_;
        settlementChain = block.chainid;
    }

    function status() external pure returns (SponsoredTaskTypes.VaultStatus) {
        return SponsoredTaskTypes.VaultStatus.Active;
    }

    function reserveTask(bytes32, bytes32, address, uint256, uint64, uint16, address, bytes32) external { }

    function bindTask(bytes32, bytes32) external pure returns (bool) {
        return true;
    }

    function releaseTask(bytes32) external pure returns (bool) {
        return true;
    }

    function installSettlement(bytes32, bytes32, bytes32, uint32, uint256, uint256, uint256)
        external
        pure
        returns (bool)
    {
        return true;
    }
}
