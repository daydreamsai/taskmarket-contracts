// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibFeedback } from "../libraries/LibFeedback.sol";
import { ITMPFeedback } from "../interfaces/ITMPFeedback.sol";

/// @title FeedbackFacet -- rev025 owner-configurable feedback values and the requester binding view
/// @notice The owner sets the ERC-8004 feedback value sent for each event key (LibFeedback lists
///         the keys and their defaults). The requester binding is written by LibFeedback on
///         forwarder-relayed accept, cancel and refund calls; this facet only reads it.
contract FeedbackFacet {
    /// @notice Set the feedback value for an event key (owner only), within [-100, 100], or
    ///         [0, 100] for the worker_rating key: that value scales a 0-100 rating, so a
    ///         negative one would invert ratings. 0 sends no feedback for it.
    function setFeedbackValue(bytes32 eventKey, int128 value) external {
        LibDiamond.enforceIsContractOwner();
        int128 min = eventKey == LibFeedback.WORKER_RATING ? int128(0) : int128(-100);
        if (value < min || value > 100) revert ITMPFeedback.FeedbackValueOutOfRange(value);
        LibAppStorage.appStorage().feedbackValues[eventKey] = ITMPFeedback.FeedbackValue({ value: value, isSet: true });
        emit ITMPFeedback.FeedbackValueUpdated(eventKey, value);
    }

    /// @notice The effective feedback value for an event key and whether the owner has set it.
    function feedbackValue(bytes32 eventKey) external view returns (int128 value, bool isSet) {
        AppStorage storage s = LibAppStorage.appStorage();
        return (LibFeedback.value(s, eventKey), s.feedbackValues[eventKey].isSet);
    }

    /// @notice The agent ID bound to a requester address, or 0 when unbound.
    function requesterAgentOf(address requester) external view returns (uint256) {
        return LibAppStorage.appStorage().requesterAgentIds[requester];
    }

    /// @notice Rev027: the agent ID bound to a worker address for reservation feedback, or 0 when
    ///         unbound. Written by LibFeedback on the worker's own relayed declineReservation.
    function workerAgentOf(address worker) external view returns (uint256) {
        return LibAppStorage.appStorage().workerAgentIds[worker];
    }
}
