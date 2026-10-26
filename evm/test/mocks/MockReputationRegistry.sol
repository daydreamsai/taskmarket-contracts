// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockReputationRegistry {
    uint256 public calls;
    string public lastTag2;
    uint256 public lastAgentId;
    int128 public lastValue;

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8,
        string calldata,
        string calldata tag2,
        string calldata,
        string calldata,
        bytes32
    ) external {
        calls++;
        lastTag2 = tag2;
        lastAgentId = agentId;
        lastValue = value;
    }
}
