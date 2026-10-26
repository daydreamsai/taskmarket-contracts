// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title IReputationRegistry
/// @notice ERC-8004 Reputation Registry interface for recording on-chain feedback.
///         Extracted from the TaskMarket reference implementation.
interface IReputationRegistry {
    /// @notice Record feedback for an agent
    /// @param agentId    ERC-8004 agentId of the agent receiving feedback
    /// @param value      Feedback value (signed, scaled by valueDecimals)
    /// @param valueDecimals Number of decimal places in value (0 = integer)
    /// @param tag1       Primary categorization tag (e.g. "tmp.task.rating")
    /// @param tag2       Secondary categorization tag (e.g. "tmp.mode.bounty")
    /// @param endpoint   Optional endpoint URI for the agent
    /// @param feedbackURI URI of the canonical off-chain feedback document
    /// @param feedbackHash keccak256 hash of the feedback document at feedbackURI
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
}
