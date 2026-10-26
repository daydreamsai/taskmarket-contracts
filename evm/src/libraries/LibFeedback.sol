// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { LibGuards } from "./LibGuards.sol";
import { LibTaskMarket } from "./LibTaskMarket.sol";
import { IReputationRegistry } from "../interfaces/IReputationRegistry.sol";
import { ITMPReputation } from "../interfaces/ITMPReputation.sol";
import { ITMPFeedback } from "../interfaces/ITMPFeedback.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title LibFeedback -- rev025: the only caller of the ERC-8004 reputation registry's giveFeedback
/// @notice Every requester and worker feedback value is looked up here: the owner-set value for
///         its event key, or the default below while the owner has not set one. A value of 0
///         sends nothing. Requester feedback goes to the requester's bound agent ID.
library LibFeedback {
    // Event keys. The requester keys are the RequesterReputation event_ values.
    bytes32 internal constant COMPLETED = keccak256("completed");
    bytes32 internal constant CANCELLED_CLEAN = keccak256("cancelled_clean");
    bytes32 internal constant CANCELLED_AFTER_SUBMISSIONS = keccak256("cancelled_after_submissions");
    bytes32 internal constant EXPIRED_NO_ACTION = keccak256("expired_no_action");
    bytes32 internal constant EXPIRED_AFTER_REJECTIONS = keccak256("expired_after_rejections");
    // Worker feedback is the requester's 0-100 rating scaled by this value in percent, so the
    // default of 100 sends the rating unchanged and 0 turns worker feedback off.
    bytes32 internal constant WORKER_RATING = keccak256("worker_rating");

    /// @notice The compiled-in default for an event key, used while the owner has not set one.
    function defaultValue(bytes32 key) internal pure returns (int128) {
        if (key == COMPLETED || key == WORKER_RATING) return 100;
        if (key == CANCELLED_AFTER_SUBMISSIONS || key == EXPIRED_AFTER_REJECTIONS) return -25;
        return 0;
    }

    /// @notice The effective value for an event key: the owner-set value, or the default.
    function value(AppStorage storage s, bytes32 key) internal view returns (int128) {
        ITMPFeedback.FeedbackValue storage v = s.feedbackValues[key];
        return v.isSet ? v.value : defaultValue(key);
    }

    /// @notice Send the requester feedback for an event key, resolving the requester's agent ID
    ///         and binding a forwarder-supplied `passedAgentId` (see resolveRequester).
    function requester(
        AppStorage storage s,
        bytes32 taskId,
        address requesterAddr,
        uint256 passedAgentId,
        bytes32 key,
        bytes4 mode
    ) internal {
        uint256 agentId = resolveRequester(s, requesterAddr, passedAgentId);
        int128 v = value(s, key);
        if (agentId == 0 || v == 0) return;
        _send(s, taskId, agentId, v, "tmp.task.requester", mode, "", bytes32(0));
    }

    /// @notice Send worker feedback for a rating: the rating scaled by the WORKER_RATING value.
    function worker(
        AppStorage storage s,
        bytes32 taskId,
        uint256 workerAgentId,
        uint8 rating,
        bytes4 mode,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) internal {
        if (workerAgentId == 0) return;
        int128 v = int128((int256(uint256(rating)) * int256(value(s, WORKER_RATING))) / 100);
        if (v == 0) return;
        _send(s, taskId, workerAgentId, v, "tmp.task.rating", mode, feedbackURI, feedbackHash);
    }

    /// @notice The agent ID requester feedback goes to: the requester's stored binding.
    /// @dev The binding is set only by a trusted forwarder relaying the requester itself: a nonzero
    ///      `passedAgentId` on such a call is stored (and replaces a different stored ID). The
    ///      forwarder supplies it from the platform's own identity records. A passed ID on any
    ///      other call, including a permissionless refundExpired from a third party, is ignored, and
    ///      a passed 0 never unbinds.
    function resolveRequester(AppStorage storage s, address requesterAddr, uint256 passedAgentId)
        internal
        returns (uint256 bound)
    {
        bound = s.requesterAgentIds[requesterAddr];
        if (passedAgentId == 0 || passedAgentId == bound) return bound;
        if (!s.trustedForwarders[msg.sender] || LibGuards._effectiveSender(s) != requesterAddr) return bound;
        s.requesterAgentIds[requesterAddr] = passedAgentId;
        emit ITMPFeedback.RequesterAgentBound(requesterAddr, passedAgentId);
        return passedAgentId;
    }

    function _send(
        AppStorage storage s,
        bytes32 taskId,
        uint256 agentId,
        int128 v,
        string memory tag1,
        bytes4 mode,
        string memory feedbackURI,
        bytes32 feedbackHash
    ) private {
        if (s.reputationRegistry == address(0)) return;
        LibTaskMarket._requireFeedbackGas();
        try IReputationRegistry(s.reputationRegistry)
            .giveFeedback(agentId, v, 0, tag1, modeName(mode), "", feedbackURI, feedbackHash) { }
        catch {
            emit ITMPReputation.ReputationFeedbackFailed(taskId, agentId);
        }
    }

    /// @notice The canonical ERC-8004 tag2 string for a mode selector.
    function modeName(bytes4 mode) internal pure returns (string memory) {
        if (mode == TMP_BOUNTY) return "tmp.mode.bounty";
        if (mode == TMP_CLAIM) return "tmp.mode.claim";
        if (mode == TMP_PITCH) return "tmp.mode.pitch";
        if (mode == TMP_BENCHMARK) return "tmp.mode.benchmark";
        if (mode == TMP_AUCTION) return "tmp.mode.auction";
        return "";
    }
}
