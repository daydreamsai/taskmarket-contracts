// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibTaskLimits } from "./LibTaskLimits.sol";
import { AppStorage } from "./LibAppStorage.sol";
import { LibGuards } from "./LibGuards.sol";
import { LibEscrow } from "./LibEscrow.sol";
import { LibHooks } from "./LibHooks.sol";
import { LibTaskMarket } from "./LibTaskMarket.sol";
import { LibTerms } from "./LibTerms.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import {
    TMP_BOUNTY,
    TMP_CLAIM,
    TMP_PITCH,
    TMP_BENCHMARK,
    TMP_AUCTION,
    TMP_AUCTION_DUTCH,
    TMP_AUCTION_ENGLISH,
    TMP_AUCTION_REVERSE_DUTCH,
    TMP_AUCTION_REVERSE_ENGLISH
} from "../interfaces/ITMPModes.sol";

/// @title LibTaskCreation -- validates, records and funds a new task
/// @notice Rev027: the body of createTask, moved out of CoreFacet so that any facet can create a
///         task through the one path, with one set of checks, hooks and escrow booking.
/// @dev The caller holds the forwarder, pause and reentrancy guards around `create`; this library
///      only records the task and books its escrow.
library LibTaskCreation {
    /// @notice Validates and records a task for `requester`, applies its evaluator terms, builds
    ///         and checks its hooks, emits its creation events and books its escrow.
    /// @param reservedWorker rev027: the only worker who may claim the task, or zero for none.
    function create(
        AppStorage storage s,
        address requester,
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms memory terms,
        address reservedWorker
    ) internal returns (bytes32 taskId) {
        taskId = _record(s, requester, config, content, terms, reservedWorker);

        // Applied before the hooks so a checkFund hook observes a fully configured task rather
        // than one that only becomes evaluator-gated a moment later.
        _applyCreationEvaluatorConfig(taskId, requester, evaluatorConfig, s);

        _buildAndCheckHooks(taskId, hookConfig, s);
        _announceAndBook(s, taskId, requester, reservedWorker);
    }

    /// @dev Records the task and, for a reserved worker, the reservation. Split from create to
    ///      keep the unoptimised (coverage) build within the stack limit.
    function _record(
        AppStorage storage s,
        address requester,
        ITMPCore.TaskConfig calldata config,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskTerms memory terms,
        address reservedWorker
    ) private returns (bytes32 taskId) {
        taskId = _initTask(requester, config, content, terms, reservedWorker != address(0), s);
        if (reservedWorker != address(0)) _reserve(taskId, requester, reservedWorker, config.duration, terms, s);
    }

    /// @dev Emits the creation events and books the task's escrow.
    function _announceAndBook(AppStorage storage s, bytes32 taskId, address requester, address reservedWorker) private {
        ITMPCore.Task storage t = s.tasks[taskId];
        emit ITMPCore.TaskCreated(taskId, requester, t.reward, t.mode, t.expiryTime, t.stakeRequired, t.stakeBps);
        emit ITMPCore.TaskTermsSet(taskId, s.taskTerms[taskId]);
        if (reservedWorker != address(0)) {
            emit ITMPCore.TaskReserved(taskId, reservedWorker, LibTerms.acceptBy(s, taskId));
        }
        LibEscrow.book(s, taskId, requester, ITMPEscrow.Component.Task, true);
    }

    /// @dev Validates the task and records it, its terms and its content.
    // solhint-disable-next-line code-complexity
    function _initTask(
        address requester,
        ITMPCore.TaskConfig calldata config,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskTerms memory terms,
        bool reserved,
        AppStorage storage s
    ) private returns (bytes32 taskId) {
        if (requester == address(0)) revert ITMPCore.InvalidRequester();
        if (config.reward == 0) revert ITMPCore.RewardMustBeGreaterThanZero();
        if (config.duration == 0) revert ITMPCore.DurationMustBeGreaterThanZero();
        if (!(config.mode == TMP_BOUNTY || config.mode == TMP_CLAIM || config.mode == TMP_PITCH
                    || config.mode == TMP_BENCHMARK || config.mode == TMP_AUCTION)) {
            revert ITMPCore.InvalidMode();
        }
        if (config.mode == TMP_AUCTION) {
            if (!(config.auctionSubtype == TMP_AUCTION_DUTCH || config.auctionSubtype == TMP_AUCTION_ENGLISH
                        || config.auctionSubtype == TMP_AUCTION_REVERSE_DUTCH
                        || config.auctionSubtype == TMP_AUCTION_REVERSE_ENGLISH)) {
                revert ITMPCore.InvalidAuctionSubtype();
            }
        }
        LibTerms.validate(s, terms, config.mode, reserved);

        taskId = keccak256(abi.encode(block.chainid, address(this), requester, s.requesterNonce[requester]++));

        ITMPCore.Task storage t = s.tasks[taskId];
        t.id = taskId;
        t.requester = requester;
        t.reward = config.reward;
        t.expiryTime = block.timestamp + config.duration;
        t.status = ITMPCore.TaskStatus.Open;
        t.mode = config.mode;
        t.feeBps = s.defaultFeeBps;
        t.stakeRequired = terms.stakeRequired;
        t.stakeBps = terms.stakeBps;
        terms.version = LibTerms.TERMS_VERSION;
        s.taskTerms[taskId] = terms;

        ITMPCore.TaskMetadata storage meta = s.taskMetadata[taskId];
        meta.createdAt = block.timestamp;
        meta.contentHash = content.contentHash;
        meta.contentURI = content.contentURI;

        if (config.mode == TMP_PITCH) {
            if (config.pitchDeadline == 0) revert ITMPCore.PitchDeadlineMustBeGreaterThanZero();
            s.taskPitchConfigs[taskId].pitchDeadline = block.timestamp + config.pitchDeadline;
        }
        if (config.mode == TMP_AUCTION) {
            if (config.bidDeadline == 0) revert ITMPCore.BidDeadlineMustBeGreaterThanZero();
            ITMPCore.TaskAuctionConfig storage ac = s.taskAuctionConfigs[taskId];
            ac.bidDeadline = block.timestamp + config.bidDeadline;
            ac.maxPrice = config.reward;
            ac.auctionSubtype = config.auctionSubtype;
        }

        if (content.tags.length > LibTaskLimits.maxTags(s)) revert ITMPCore.TooManyTags();
        if (content.tags.length > 0) {
            s.taskTags[taskId] = content.tags;
        }
    }

    /// @dev Rev027: records the reserved worker. The worker may not be the requester, and the
    ///      delivery period may not be shorter than the accept window, so the task's expiry is
    ///      never before its accept-by time and the worker always has the whole window.
    function _reserve(
        bytes32 taskId,
        address requester,
        address worker,
        uint256 duration,
        ITMPCore.TaskTerms memory terms,
        AppStorage storage s
    ) private {
        if (worker == requester) revert ITMPCore.InvalidWorker();
        if (duration < LibTerms.acceptWindow(terms)) revert ITMPCore.InvalidTerms();
        s.reservedWorkers[taskId] = worker;
    }

    /// @dev Creation-side wrapper around the shared evaluator-config body. Kept in its own frame
    ///      so the struct copy and stake-pull locals do not add to create's already-deep stack. A
    ///      zero `evaluator` means the task has no evaluator, which is the common case.
    function _applyCreationEvaluatorConfig(
        bytes32 taskId,
        address requester,
        ITMPCore.TaskEvaluatorConfig memory evaluatorConfig,
        AppStorage storage s
    ) private {
        if (evaluatorConfig.evaluator != address(0)) {
            LibTaskMarket._applyEvaluatorConfig(taskId, requester, evaluatorConfig, s.tasks[taskId].reward, s);
            return;
        }
        // Evaluator terms with no evaluator to apply them to would be silently dropped, leaving
        // the requester believing the task is evaluator-gated when it is not -- and believing it
        // for the whole life of the task, since nothing ever reports the discarded fields.
        // A malformed request is worth a revert here; a misconfigured escrow is not recoverable.
        if (
            evaluatorConfig.evaluatorStake != 0 || evaluatorConfig.evaluatorFeeBps != 0
                || evaluatorConfig.evaluationWindow != 0 || evaluatorConfig.appealWindow != 0
                || evaluatorConfig.disputeResolver != address(0)
        ) {
            revert ITMPCore.InvalidEvaluator();
        }
        // The reward is the whole payment of an evaluator-less create.
        LibGuards._requireReportedPayment(s.tasks[taskId].reward);
    }

    function _buildAndCheckHooks(bytes32 taskId, ITMPCore.HookConfig calldata hookConfig, AppStorage storage s)
        private
    {
        uint256 defaultLen = s.defaultHooks.length;
        uint256 reqLen = hookConfig.contracts.length;
        if (defaultLen == 0 && reqLen == 0) return;
        if (defaultLen + reqLen > LibTaskLimits.maxHooks(s)) revert ITMPCore.TooManyHooks();
        address[] storage th = s.taskHooks[taskId];
        for (uint256 i; i < defaultLen; i++) {
            th.push(s.defaultHooks[i]);
        }
        for (uint256 i; i < reqLen; i++) {
            address h = hookConfig.contracts[i];
            if (h == address(0)) revert ITMPCore.InvalidHookAddress();
            if (h.code.length == 0) revert ITMPCore.InvalidHookAddress();
            for (uint256 j; j < defaultLen; j++) {
                if (s.defaultHooks[j] == h) revert ITMPCore.DuplicateHookAddress();
            }
            for (uint256 j; j < i; j++) {
                if (hookConfig.contracts[j] == h) revert ITMPCore.DuplicateHookAddress();
            }
            th.push(h);
        }
        LibHooks._checkFundHooks(taskId, th, hookConfig.data, s);
    }
}
