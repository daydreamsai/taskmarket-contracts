// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage, LibAppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../interfaces/ITMPEvaluator.sol";
import { LibGuards } from "./LibGuards.sol";
import { TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title LibTaskMarket — evaluator configuration, appeal window and feedback gas helpers
/// @dev Call guards live in LibGuards and hook dispatch in LibHooks.
library LibTaskMarket {
    // Minimum gas that must remain when a swallowed ERC-8004 giveFeedback call is about to run.
    // The call sits in a try/catch, so eth_estimateGas would otherwise settle on a limit where it
    // runs out of gas unnoticed; giveFeedback itself needs about 220k.
    // Rev024: this is the default and the lowest value AdminFacet.setMinFeedbackGas accepts;
    // the effective floor is s.minFeedbackGas once the owner has set it (see _minFeedbackGas).
    uint256 internal constant MIN_FEEDBACK_GAS = 450_000;
    // Rev024: highest floor setMinFeedbackGas accepts. Every settlement path that reaches a
    // giveFeedback call needs at least this much gas left, so a floor near a chain's transaction
    // gas cap would make acceptance unreachable; 5M is well above the worst measured registry
    // cost (about 1.8M on Tempo) and well below any supported chain's cap.
    uint256 internal constant MAX_FEEDBACK_GAS = 5_000_000;

    // Rev025: most winners one Bounty or Benchmark settlement may pay. 50 winners measured about
    // 3.6M gas on Base and 9M on Tempo, under the 16M relay ceiling; 100 would exceed it on Tempo.
    uint256 internal constant MAX_SUBMISSION_WINNERS = 50;

    // Rev017: default floor for assignEvaluator's appealWindowSecs, used whenever
    // s.minAppealWindowSecs has never been set. Five minutes is sized for a worker that
    // discovers an adverse verdict by polling on a bounded schedule rather than by watching
    // the chain continuously: a minute is barely distinguishable from zero for such a worker,
    // which would leave the degenerate case this guard exists to close only nominally closed.
    // It is not an opinion on how long a dispute window ought to be -- that stays the
    // requester's choice, same as evaluationWindowSecs -- and it is admin-settable precisely
    // so it can be corrected in either direction without a facet upgrade.
    uint32 internal constant DEFAULT_MIN_APPEAL_WINDOW_SECS = 5 minutes;

    // Rev025: default floor for an evaluator's evaluationWindow, used whenever
    // s.minEvaluationWindowSecs has never been set.
    uint32 internal constant DEFAULT_MIN_EVALUATION_WINDOW_SECS = 24 hours;

    // -------------------------------------------------------------------------
    // Evaluator configuration — shared by the two entry points that may write it
    // -------------------------------------------------------------------------

    /// @notice Writes a task's evaluator configuration and pulls any evaluator stake.
    /// @dev Two entry points may configure an evaluator: CoreFacet.createTask, which takes the
    ///      configuration atomically with the task itself, and EvaluatorFacet.assignEvaluator,
    ///      which appoints one to an already-live task. They share this body deliberately. If
    ///      each kept its own copy, the creation path would sooner or later validate less than
    ///      the assignment path and become the way to bypass the difference -- the guard that is
    ///      cheapest to skip is the one nobody has written yet. Every check on the evaluator
    ///      terms themselves belongs here, so a later revision tightening one of them tightens
    ///      both paths without having to know both paths exist.
    ///
    ///      Only the checks that depend on the caller's own context stay with the caller, because
    ///      they genuinely differ: on creation the requester is the authenticated sender by
    ///      construction and the task is Open by construction, so `NotRequester` and
    ///      `TaskNotOpen` have nothing to test.
    /// @param taskId    Task identifier
    /// @param requester Authenticated requester; the address any stake is pulled from
    /// @param cfg       Evaluator terms to store
    /// @param s         AppStorage
    function _applyEvaluatorConfig(
        bytes32 taskId,
        address requester,
        ITMPCore.TaskEvaluatorConfig memory cfg,
        uint256 otherForwardedFunds,
        AppStorage storage s
    ) internal {
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        if (cfg.evaluator == address(0)) revert ITMPCore.InvalidEvaluator();
        if (cfg.evaluator == requester) revert ITMPCore.EvaluatorCannotBeRequester();
        if (cfg.disputeResolver == requester) revert ITMPCore.DisputeResolverCannotBeRequester();
        if (evalCfg.evaluator != address(0)) revert ITMPCore.EvaluatorAlreadyAssigned();
        if (cfg.evaluatorFeeBps > 10000) revert ITMPCore.FeeBpsTooHigh();
        if (cfg.appealWindow < _minAppealWindowSecs(s)) revert ITMPCore.AppealWindowTooShort();
        // Rev025: evaluatorTimeout is permissionless, so a very short window would let the worker
        // submit and time out the evaluator a block later, forfeiting the evaluator stake and
        // skipping evaluation. The floor is per chain and separate from termsBounds, which bounds
        // the review and decision windows. See the rev025 spec.
        uint32 minWindow = _minEvaluationWindowSecs(s);
        if (cfg.evaluationWindow < minWindow) {
            revert ITMPCore.EvaluationWindowTooShort(cfg.evaluationWindow, minWindow);
        }

        evalCfg.evaluator = cfg.evaluator;
        evalCfg.evaluatorStake = cfg.evaluatorStake;
        evalCfg.evaluatorFeeBps = cfg.evaluatorFeeBps;
        evalCfg.evaluationWindow = cfg.evaluationWindow;
        evalCfg.appealWindow = cfg.appealWindow;
        evalCfg.disputeResolver = cfg.disputeResolver;

        // A paying forwarder (v2) has already moved the stake into escrow as part of the relayed
        // payment, alongside otherForwardedFunds (the reward on createTask). A v1 forwarder
        // reports no payment, so the stake is still pulled from the requester's allowance.
        if (!LibGuards._requireReportedPayment(otherForwardedFunds + cfg.evaluatorStake) && cfg.evaluatorStake > 0) {
            // requester = _effectiveSender(s) = authenticated PGTR forwarder caller; not arbitrary
            // slither-disable-next-line arbitrary-send-erc20
            if (!s.usdcToken.transferFrom(requester, address(this), cfg.evaluatorStake)) {
                revert ITMPCore.StakeTransferFailed();
            }
        }

        // Emitted identically whichever entry point wrote the config, so an indexer sees one
        // event vocabulary for "this task has an evaluator" rather than having to infer it from
        // TaskCreated on the creation path.
        emit ITMPEvaluator.EvaluatorAssigned(taskId, cfg.evaluator, cfg.evaluatorStake);
    }

    /// @notice The evaluator fee on a task: basis points of what the task actually pays. An
    ///         auction escrows its price cap in task.reward and settles at the accepted price,
    ///         which selectLowestBidder and acceptAuction record in task.stakeAmount. evaluate()
    ///         charges this and every later settlement deducts the same amount, so the base must
    ///         be computed in one place.
    function _evaluatorFee(ITMPCore.Task storage task, uint16 feeBps) internal view returns (uint256) {
        uint256 base = task.mode == TMP_AUCTION ? task.stakeAmount : task.reward;
        return (base * feeBps) / 10000;
    }

    /// @notice The effective minimum appeal window: the admin-configured value, or the compiled
    ///         default when it has never been set. A stored zero is treated as unset rather than
    ///         as "no minimum", because a zero floor is exactly the hole this guard exists to
    ///         close -- and every diamond upgraded into rev017 starts with a zero in this slot.
    ///         AdminFacet's setter rejects zero for the same reason, so unset and
    ///         deliberately-zero are not states that can be confused.
    function _minAppealWindowSecs(AppStorage storage s) internal view returns (uint32) {
        uint32 configured = s.minAppealWindowSecs;
        return configured == 0 ? DEFAULT_MIN_APPEAL_WINDOW_SECS : configured;
    }

    /// @notice The effective minimum evaluation window: the owner-set value, or 24 hours when it
    ///         has never been set. AdminFacet's setter rejects zero, so zero always means unset.
    function _minEvaluationWindowSecs(AppStorage storage s) internal view returns (uint32) {
        uint32 configured = s.minEvaluationWindowSecs;
        return configured == 0 ? DEFAULT_MIN_EVALUATION_WINDOW_SECS : configured;
    }

    /// @dev Reverts when too little gas is left for a reputation-registry call that failures
    ///      are swallowed around, so an under-funded limit cannot succeed with the call dropped.
    ///      The floor is per chain: the owner-set s.minFeedbackGas, or MIN_FEEDBACK_GAS if unset.
    function _requireFeedbackGas() internal view {
        if (gasleft() < _minFeedbackGas(LibAppStorage.appStorage())) {
            revert ITMPCore.InsufficientGasForFeedback();
        }
    }

    /// @notice The effective feedback gas floor: the owner-configured value, or MIN_FEEDBACK_GAS
    ///         when it has never been set (every diamond upgraded into rev024 reads zero here).
    function _minFeedbackGas(AppStorage storage s) internal view returns (uint256) {
        uint256 configured = s.minFeedbackGas;
        return configured == 0 ? MIN_FEEDBACK_GAS : configured;
    }
}
