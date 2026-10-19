// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title ITMPFeedback
/// @notice Rev025: owner-configurable ERC-8004 feedback values and the per-requester agent binding.
interface ITMPFeedback {
    /// @notice An owner-set feedback value. `isSet` tells an explicit 0 ("send nothing") apart
    ///         from "never set" ("use the compiled-in default").
    struct FeedbackValue {
        int128 value;
        bool isSet;
    }

    /// @notice Emitted when the owner sets the feedback value for an event key.
    event FeedbackValueUpdated(bytes32 indexed eventKey, int128 value);

    /// @notice Emitted when a requester address is bound, or rebound, to an ERC-8004 agent ID
    ///         supplied by a trusted forwarder on an accept, cancel or refund.
    event RequesterAgentBound(address indexed requester, uint256 indexed agentId);

    /// @notice A configured feedback value is outside [-100, 100].
    error FeedbackValueOutOfRange(int128 value);

    /// @notice Set the feedback value for an event key (owner only). 0 sends no feedback.
    function setFeedbackValue(bytes32 eventKey, int128 value) external;

    /// @notice The effective feedback value for an event key (the default while unset) and
    ///         whether the owner has set it.
    function feedbackValue(bytes32 eventKey) external view returns (int128 value, bool isSet);

    /// @notice The agent ID bound to a requester address, or 0 when unbound.
    function requesterAgentOf(address requester) external view returns (uint256);
}
