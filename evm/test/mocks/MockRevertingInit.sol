// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockRevertingInit {
    function initialize() external pure {
        revert("MockRevertingInit: intentional revert");
    }
}
