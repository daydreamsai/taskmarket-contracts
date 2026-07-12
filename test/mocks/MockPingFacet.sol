// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockPingFacet {
    function ping() external pure returns (bytes32) {
        return keccak256("pong");
    }
}
