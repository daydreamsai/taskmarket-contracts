// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockReputationRegistry {
    uint256 public calls;
    string public lastTag2;

    function giveFeedback(
        uint256,
        int128,
        uint8,
        string calldata,
        string calldata tag2,
        string calldata,
        string calldata,
        bytes32
    ) external {
        calls++;
        lastTag2 = tag2;
    }
}
