// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Rev026 escrow accounting: what the pooled USDC balance owes, per task and in total.
///         See docs/specs/erc8195/rev026-escrow-liabilities-and-solvency.md.
interface ITMPEscrow {
    /// @notice What a funding call booked.
    enum Component {
        Task,
        RewardIncrease,
        WorkerStake,
        EvaluatorStake
    }

    /// @notice A task's booked amount. `tracked` is false for a task created before rev026 that
    ///         the upgrade's initialisation has not booked; its funding and payouts book nothing.
    struct EscrowRecord {
        uint128 booked;
        bool tracked;
    }

    event EscrowFunded(bytes32 indexed taskId, address indexed payer, uint256 amount, Component component);
    event EscrowReleased(bytes32 indexed taskId, uint256 amount);
    event UnbookedFunding(bytes32 indexed taskId, address indexed payer, Component component);
    event UnbookedRelease(bytes32 indexed taskId, uint256 amount);
    event SurplusSwept(address indexed to, uint256 amount);
    event EscrowBackfilled(bytes32 indexed taskId, uint256 amount);
    event LiabilitiesInitialised(uint256 totalLiabilities, uint256 surplus);

    error EscrowInsolvent(uint256 balance, uint256 liabilities);
    error EscrowOverdrawn(bytes32 taskId, uint256 paidOut, uint256 released);
    error EscrowMismatch(bytes32 taskId, uint256 owed, uint256 booked);
    error LiabilitiesNotInitialised();
    error LiabilitiesAlreadyInitialised();

    function totalLiabilities() external view returns (uint256);
    function escrowRecord(bytes32 taskId) external view returns (uint256 booked, bool tracked);
    function liabilitiesInitialised() external view returns (bool);
    function sweepSurplus() external;
    function backfillLiabilities(bytes32[] calldata taskIds) external returns (uint256 booked);
    function completeLiabilities() external;
}
