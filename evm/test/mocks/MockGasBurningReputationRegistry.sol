// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Burns every unit of gas it is given on giveFeedback, as a hostile or broken registry might.
contract MockGasBurningReputationRegistry {
    uint256 public sink;

    function giveFeedback(
        uint256,
        int128,
        uint8,
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        bytes32
    ) external {
        while (true) {
            sink++;
        }
    }
}
