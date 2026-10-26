// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Always reverts on giveFeedback -- simulates a misconfigured or broken
///         reputation registry (see ITMPReputation.ReputationFeedbackFailed).
contract MockRevertingReputationRegistry {
    error AlwaysReverts();

    function giveFeedback(
        uint256,
        int128,
        uint8,
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        bytes32
    ) external pure {
        revert AlwaysReverts();
    }
}
