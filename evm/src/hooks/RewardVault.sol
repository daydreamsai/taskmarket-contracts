// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IRewardVault } from "../interfaces/IRewardVault.sol";

/// @title RewardVault
/// @notice Holds protocol tokens and manages per-task reservations.
///         Only the authorised hook contract may call mutating functions.
contract RewardVault is IRewardVault, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public hook;

    uint256 public totalReserved;
    mapping(bytes32 => uint256) public taskReserve;

    event HookSet(address indexed hook);
    event Reserved(bytes32 indexed taskId, uint256 amount);
    event Released(bytes32 indexed taskId, uint256 amount);
    event Paid(bytes32 indexed taskId, address indexed worker, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event EmergencyWithdrawn(address indexed to, uint256 amount);

    error OnlyHook();
    error InsufficientAvailable(uint256 requested, uint256 available);
    error InsufficientReserve(bytes32 taskId, uint256 requested, uint256 reserved);

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address _token, address _owner) Ownable(_owner) {
        token = IERC20(_token);
    }

    function setHook(address _hook) external onlyOwner {
        hook = _hook;
        emit HookSet(_hook);
    }

    /// @notice Available = balance - totalReserved
    function available() public view returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        return balance > totalReserved ? balance - totalReserved : 0;
    }

    /// @notice Reserve tokens for a specific task. Reverts if insufficient available balance.
    function reserve(bytes32 taskId, uint256 amount) external onlyHook {
        uint256 avail = available();
        if (amount > avail) revert InsufficientAvailable(amount, avail);
        totalReserved += amount;
        taskReserve[taskId] += amount;
        emit Reserved(taskId, amount);
    }

    /// @notice Release reserved tokens back to the available pool (e.g. on cancel/expire).
    function release(bytes32 taskId, uint256 amount) external onlyHook {
        uint256 reserved = taskReserve[taskId];
        if (amount > reserved) revert InsufficientReserve(taskId, amount, reserved);
        taskReserve[taskId] -= amount;
        totalReserved -= amount;
        emit Released(taskId, amount);
    }

    /// @notice Release reserve and transfer tokens to worker atomically.
    function pay(bytes32 taskId, address worker, uint256 amount) external onlyHook {
        uint256 reserved = taskReserve[taskId];
        if (amount > reserved) revert InsufficientReserve(taskId, amount, reserved);
        taskReserve[taskId] -= amount;
        totalReserved -= amount;
        token.safeTransfer(worker, amount);
        emit Paid(taskId, worker, amount);
    }

    /// @notice Direct pay without reserve (used for Bounty path).
    function payDirect(address worker, uint256 amount) external onlyHook {
        uint256 avail = available();
        if (amount > avail) revert InsufficientAvailable(amount, avail);
        token.safeTransfer(worker, amount);
        emit Paid(bytes32(0), worker, amount);
    }

    /// @notice Owner can withdraw unallocated (non-reserved) tokens.
    function withdraw(address to, uint256 amount) external onlyOwner {
        uint256 avail = available();
        if (amount > avail) revert InsufficientAvailable(amount, avail);
        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    /// @notice Sweeps the full balance, bypassing totalReserved.
    function emergencyWithdraw(address to) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer(to, balance);
        emit EmergencyWithdrawn(to, balance);
    }
}
