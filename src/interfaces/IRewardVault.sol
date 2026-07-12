// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardVault {
    function reserve(bytes32 taskId, uint256 amount) external;
    function release(bytes32 taskId, uint256 amount) external;
    function pay(bytes32 taskId, address worker, uint256 amount) external;
    function payDirect(address worker, uint256 amount) external;
    function available() external view returns (uint256);
    function taskReserve(bytes32 taskId) external view returns (uint256);
}
