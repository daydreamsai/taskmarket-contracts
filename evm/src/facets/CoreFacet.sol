// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibProject } from "../libraries/LibProject.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { ITMPEscrow } from "../interfaces/ITMPEscrow.sol";
import { LibTaskCreation } from "../libraries/LibTaskCreation.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
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

/// @title CoreFacet — task creation and updates
/// @notice Creates and updates tasks. Claiming, worker selection and submission are in WorkerFacet
///         (rev027), acceptance in AcceptanceFacet, evaluation in EvaluatorFacet, and rejection,
///         forfeit, cancel and refund in SettlementFacet.
contract CoreFacet {
    bytes4 public constant BOUNTY = TMP_BOUNTY;
    bytes4 public constant CLAIM = TMP_CLAIM;
    bytes4 public constant PITCH = TMP_PITCH;
    bytes4 public constant BENCHMARK = TMP_BENCHMARK;
    bytes4 public constant AUCTION = TMP_AUCTION;
    bytes4 public constant AUCTION_DUTCH = TMP_AUCTION_DUTCH;
    bytes4 public constant AUCTION_ENGLISH = TMP_AUCTION_ENGLISH;
    bytes4 public constant AUCTION_REVERSE_DUTCH = TMP_AUCTION_REVERSE_DUTCH;
    bytes4 public constant AUCTION_REVERSE_ENGLISH = TMP_AUCTION_REVERSE_ENGLISH;

    uint256 public constant MAX_BIDS_PER_TASK = 500;

    /// @notice Create a new task with USDC escrow.
    ///         Task ID is contract-generated:
    ///           keccak256(abi.encode(block.chainid, address(this), requester, nonce))
    ///         The USDC reward MUST be transferred to this contract by the forwarder before calling.
    /// @param config          Reward (6-decimal USDC; for Auction = max price), duration, mode,
    ///                        and the mode-specific pitch/bid deadlines and auction subtype.
    /// @param hookConfig      Hook contracts + hookData packed into one calldata pointer (Rev008).
    /// @param content         Content hash, URI, and tags (packed to reduce stack depth).
    /// @param evaluatorConfig Evaluator terms, applied in this same transaction. Pass the zero
    ///                        struct for a task with no evaluator. Configuring an evaluator here
    ///                        rather than via a following `assignEvaluator` call is the only way
    ///                        to do it without a race: the task is Open, and so claimable, the
    ///                        instant this transaction mines, and `assignEvaluator` reverts
    ///                        `TaskNotOpen` once a worker has claimed.
    /// @param terms           Settlement terms (rev025), the stake requirement included. Zero
    ///                        fields take the protocol defaults; see ITMPCore.TaskTerms for the
    ///                        encodings. Reverts InvalidTerms outside the owner-set bounds, or for
    ///                        a Reopen reject outcome on an auction. `terms.version` is ignored.
    /// @dev The rev018 overload taking a StakeConfig and recording default terms was removed in
    ///      rev026; its selector no longer routes.
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms
    ) external returns (bytes32) {
        return _createTask(config, hookConfig, content, evaluatorConfig, terms, address(0));
    }

    /// @notice Rev027: create a Claim task with a reserved worker. As createTask, and only that
    ///         worker may claim (accept) or decline it, up to and including the accept-by time:
    ///         creation plus terms.acceptWindowSecs (0 = 72 hours; otherwise 1 hour to 30 days).
    ///         config.duration is the delivery period, counted from the claim, and must be at
    ///         least the accept window. A rejected delivery refunds the requester, so
    ///         terms.rejectOutcome may not be Reopen. reservedWorker zero creates an ordinary task.
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms,
        address reservedWorker
    ) external returns (bytes32) {
        return _createTask(config, hookConfig, content, evaluatorConfig, terms, reservedWorker);
    }

    /// @notice The rev025 createTask taking version 1 terms (no acceptWindowSecs), kept routed by
    ///         rev027 so callers can move to the version 2 encoding after the cut. It creates a task
    ///         with no reserved worker and records version 2 terms. A later revision removes it.
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTermsV1 calldata terms
    ) external returns (bytes32) {
        ITMPCore.TaskTerms memory t = ITMPCore.TaskTerms({
            version: terms.version,
            stakeRequired: terms.stakeRequired,
            stakeBps: terms.stakeBps,
            penaltyTo: terms.penaltyTo,
            reviewWindowSecs: terms.reviewWindowSecs,
            decisionWindowSecs: terms.decisionWindowSecs,
            reopenExtensionSecs: terms.reopenExtensionSecs,
            releaseAllowed: terms.releaseAllowed,
            releaseGraceBps: terms.releaseGraceBps,
            rejectOutcome: terms.rejectOutcome,
            rejectFeeBps: terms.rejectFeeBps,
            maxRevisions: terms.maxRevisions,
            resolutionWindowSecs: terms.resolutionWindowSecs,
            acceptWindowSecs: 0
        });
        return _createTask(config, hookConfig, content, evaluatorConfig, t, address(0));
    }

    function _createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms memory terms,
        address reservedWorker
    ) private returns (bytes32 taskId) {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        taskId =
            LibTaskCreation.create(s, requester, config, hookConfig, content, evaluatorConfig, terms, reservedWorker);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice Update an open task's parameters. Pass 0 for any field to leave unchanged.
    ///         The requester is the authenticated actor (pgtrSender).
    // Complexity is inherent: each optional field requires independent validation and transfer branches.
    // solhint-disable-next-line code-complexity
    function updateTask(
        bytes32 taskId,
        uint256 newReward,
        uint256 newExpiryTime,
        uint256 newBidDeadline,
        uint256 newPitchDeadline
    ) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = LibGuards._effectiveSender(s);
        ITMPCore.Task storage task = s.tasks[taskId];
        if (task.requester == address(0)) revert ITMPCore.TaskDoesNotExist();
        LibGuards._requireRequester(s, taskId, requester);
        LibTerms.requireTermsOpen(s, taskId, task);
        if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
        if (task.mode == AUCTION && s.taskBids[taskId].length != 0) revert ITMPCore.BidsExist();
        // Rev027: a claimTask carries no expected terms, so a pending offer must not change under
        // the worker's answer. The requester withdraws it (cancelTask) and makes a new one.
        if (s.reservedWorkers[taskId] != address(0) && block.timestamp <= LibTerms.acceptBy(s, taskId)) {
            revert ITMPCore.ReservationPending();
        }

        uint256 originalReward = task.reward;
        uint256 originalExpiryTime = task.expiryTime;
        uint256 originalBidDeadline = s.taskAuctionConfigs[taskId].bidDeadline;
        uint256 originalPitchDeadline = s.taskPitchConfigs[taskId].pitchDeadline;

        // A reward that is named but unchanged must revert, not no-op. The USDC for a reward
        // increase is pulled by the forwarder BEFORE this call runs, and the Diamond has no way
        // to hand it back -- so a silent no-op here keeps money that corresponds to no liability,
        // and a duplicate relay of the same increase (a retry with a fresh receipt nonce, which
        // the forwarder's replay guard does not and cannot catch) charges the requester twice for
        // one increase. Reverting is the only mechanism available on this side of the forwarder
        // boundary that unwinds the transfer, because the whole transaction unwinds with it.
        // Callers leave a field unchanged by passing 0, so this rejects nothing legitimate.
        if (newReward != 0 && newReward == task.reward) revert ITMPCore.NoRewardChange();

        uint256 refund = 0;
        // The forwarder must have moved exactly the increase into escrow, and nothing on an update
        // that raises no reward. LibEscrow.book below checks the increase is covered by the
        // unbooked balance for a booked task.
        LibGuards._requireReportedPayment(newReward > task.reward ? newReward - task.reward : 0);
        if (newReward != 0 && newReward != task.reward) {
            if (newReward < task.reward) {
                refund = task.reward - newReward;
            }
            task.reward = newReward;
            if (task.mode == AUCTION) s.taskAuctionConfigs[taskId].maxPrice = newReward;
        }
        if (newExpiryTime != 0) {
            if (newExpiryTime <= block.timestamp) revert ITMPCore.ExpiryMustBeInFuture();
            task.expiryTime = newExpiryTime;
        }
        if (newBidDeadline != 0 && task.mode == AUCTION) {
            if (newBidDeadline <= block.timestamp) revert ITMPCore.BidDeadlineMustBeInFuture();
            s.taskAuctionConfigs[taskId].bidDeadline = newBidDeadline;
        }
        if (newPitchDeadline != 0 && task.mode == PITCH) {
            if (newPitchDeadline <= block.timestamp) revert ITMPCore.PitchDeadlineMustBeInFuture();
            s.taskPitchConfigs[taskId].pitchDeadline = newPitchDeadline;
        }
        if (refund > 0) {
            uint256 balanceBefore = LibEscrow.balance(s);
            if (!LibProject.payRequester(s, taskId, refund)) revert ITMPCore.USDCRefundFailed();
            LibEscrow.release(s, taskId, balanceBefore);
        } else if (newReward > originalReward) {
            LibEscrow.book(s, taskId, requester, ITMPEscrow.Component.RewardIncrease, false);
        }

        bool changed = (newReward != 0 && newReward != originalReward)
            || (newExpiryTime != 0 && newExpiryTime != originalExpiryTime)
            || (newBidDeadline != 0 && newBidDeadline != originalBidDeadline && task.mode == AUCTION)
            || (newPitchDeadline != 0 && newPitchDeadline != originalPitchDeadline && task.mode == PITCH);

        if (changed) emit ITMPCore.TaskUpdated(taskId, task.reward, task.expiryTime);
        LibGuards._nonReentrantAfter(s);
    }
}
