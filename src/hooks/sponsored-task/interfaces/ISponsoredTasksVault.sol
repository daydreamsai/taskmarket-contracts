// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SponsoredTaskTypes } from "../SponsoredTaskTypes.sol";

interface ISponsoredTasksVault {
    function initialize(bytes32 vaultId, address token, address vaultOwner, address controller, address feePolicy)
        external;

    function vaultId() external view returns (bytes32);

    function token() external view returns (address);

    /// @return The EIP-155 chain ID where the vault settles project-token accounting.
    function settlementChain() external view returns (uint256);

    function owner() external view returns (address);

    function controller() external view returns (address);

    function epoch() external view returns (uint64);

    function status() external view returns (SponsoredTaskTypes.VaultStatus);

    /// @dev Split into two getters rather than one returning the full 16-field `Allocation` --
    ///      a single external function returning the whole struct trips `forge coverage
    ///      --ir-minimum`'s stack-too-deep limit purely on its own ABI-encoded return.
    function allocationTerms(bytes32 allocationId)
        external
        view
        returns (
            bytes32 taskId,
            bytes32 termsHash,
            address manager,
            uint64 epoch,
            uint16 feeBps,
            address feeRecipient,
            uint256 grossAmount,
            uint256 distributedGross
        );

    function allocationSettlement(bytes32 allocationId)
        external
        view
        returns (
            uint256 sponsoredTaskOutstanding,
            uint256 sponsoredTaskPaid,
            uint256 feeOutstanding,
            uint256 feePaid,
            uint256 releasedAmount,
            bytes32 rewardsRoot,
            uint32 leafCount,
            SponsoredTaskTypes.AllocationStatus status
        );

    function effectiveAllocationStatus(bytes32 allocationId) external view returns (SponsoredTaskTypes.AllocationStatus);

    function reserveTask(
        bytes32 allocationId,
        bytes32 taskId,
        address manager,
        uint256 grossAmount,
        uint64 expectedEpoch,
        uint16 expectedFeeBps,
        address expectedFeeRecipient,
        bytes32 termsHash
    ) external;

    function bindTask(bytes32 allocationId, bytes32 taskId) external returns (bool changed);

    function releaseTask(bytes32 allocationId) external returns (bool changed);

    function installSettlement(
        bytes32 allocationId,
        bytes32 taskId,
        bytes32 rewardsRoot,
        uint32 leafCount,
        uint256 sponsoredTaskTotal,
        uint256 feeTotal,
        uint256 distributedGross
    ) external returns (bool changed);
}
