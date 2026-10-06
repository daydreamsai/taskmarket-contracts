// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SponsoredTaskTypes
/// @notice Shared data types for a single-token Sponsored Task vault.
library SponsoredTaskTypes {
    enum VaultStatus {
        Uninitialized,
        Active,
        Exited
    }

    enum AllocationStatus {
        None,
        Reserved,
        Claimable,
        Settled,
        Released,
        DefaultedByOwner
    }

    struct FeeTerms {
        uint16 bps;
        address recipient;
    }

    /// @dev `cap` is a lifetime cap. An owner grants more capacity by increasing it.
    struct ManagerAccount {
        uint256 cap;
        uint256 reserved;
        uint256 spent;
        bool active;
    }

    /// @dev For a Robinhood Chain vault, allocationId is the reservation intent ID and
    ///      taskId is bound later. For a Base-local vault they may be identical.
    struct Allocation {
        bytes32 taskId;
        bytes32 termsHash;
        address manager;
        uint64 epoch;
        uint16 feeBps;
        address feeRecipient;
        uint256 grossAmount;
        uint256 distributedGross;
        uint256 sponsoredTaskOutstanding;
        uint256 sponsoredTaskPaid;
        uint256 feeOutstanding;
        uint256 feePaid;
        uint256 releasedAmount;
        bytes32 rewardsRoot;
        uint32 leafCount;
        AllocationStatus status;
    }
}
