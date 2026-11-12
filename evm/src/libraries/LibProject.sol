// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibSettlement } from "./LibSettlement.sol";
import { LibEscrow } from "./LibEscrow.sol";
import { AppStorage } from "./LibAppStorage.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPProject } from "../interfaces/ITMPProject.sol";
import { ITMPFundingPool } from "../interfaces/ITMPFundingPool.sol";
import { IFundingPoolManager } from "../interfaces/IFundingPoolManager.sol";
import { TMP_BOUNTY, TMP_CLAIM, TMP_PITCH, TMP_BENCHMARK, TMP_AUCTION } from "../interfaces/ITMPModes.sol";

/// @title LibProject -- rev027: what a project task draws from its pool and where its money goes
/// @dev A project's budget lives in the funding pool contract (IFundingPoolManager), which the
///      diamond calls as its only manager; the diamond stores the pool's address once
///      (AppStorage.fundingPool). Every facet that pays a task's requester calls payRequester
///      instead of transferring to task.requester. For a project task the diamond transfers the
///      amount to the pool and calls refund: budget the next task can draw on while the project is
///      open, the backers' pot once it is closed or past its end date. The transfer is an ordinary
///      payout to LibEscrow.release, which releases the task's whole liability, so the escrow
///      bookkeeping needs no special case and the diamond's balance no longer carries any pool money.
///
///      What the pool spends on a task (its reward and evaluator stake at creation, and any later
///      reward increase or evaluator stake) arrives in the diamond with the pool's spend call and is
///      booked as the task's escrow in the same transaction. It is recorded in taskPoolDraws and
///      counted in the pool's outstanding. LibEscrow.release calls finishDraw after every payout,
///      which lowers the record to the pool money the task still holds (what it owes, less a Claim
///      worker's stake) and passes the pool the difference only; a terminal task owes nothing, so
///      its whole draw leaves outstanding then. taskPoolDraws is the source of truth for this.
library LibProject {
    /// @notice The module ID projects open their funding pools under.
    bytes32 internal constant PROJECT_MODULE = keccak256("taskmarket.project");

    /// @notice The latest end date createProject accepts, from the block's timestamp.
    uint256 internal constant MAX_LIFETIME = 365 days;

    /// @notice The longest task grace period createProject accepts: how long after its end date
    ///         a project's tasks may run. A backer's money is held at most
    ///         until the project's current end date plus this grace plus the evaluation and decision
    ///         windows of a task running to its expiry. The owner can move the end date later
    ///         repeatedly with extendProject (each time to at most MAX_LIFETIME from that moment),
    ///         so there is no fixed bound from creation.
    uint32 internal constant MAX_TASK_GRACE = 90 days;

    /// @notice Rev029: the bits of GrantLimits.allowedModesMask, one per built-in mode (bounty 0,
    ///         claim 1, pitch 2, benchmark 3, auction 4). Any higher bit is unknown.
    uint32 internal constant KNOWN_MODES_MASK = 0x1F;

    /// @notice The latest expiry a task of `projectId` may have: its end date plus its task
    ///         grace period.
    function latestExpiry(AppStorage storage s, uint256 projectId) internal view returns (uint256) {
        ITMPProject.ProjectRecord storage p = s.projects[projectId];
        return uint256(p.endsAt) + p.taskGraceSecs;
    }

    /// @notice Rev030: `wanted` held to the latest expiry of the task's project (end date plus task
    ///         grace), the bound extendExpiry clamps a project task's expiry to; `wanted` unchanged
    ///         for a task in no project. Used for a phase deadline set with an expiry extension,
    ///         so the phase cannot end after the latest time the task may run.
    function boundDeadline(AppStorage storage s, bytes32 taskId, uint256 wanted) internal view returns (uint256) {
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return wanted;
        uint256 latest = latestExpiry(s, projectId);
        return wanted > latest ? latest : wanted;
    }

    /// @notice Refuses updateTask's extension of a project task's expiry to `newExpiry` past the
    ///         project's end date plus its task grace period, or at all once the project's pool
    ///         has settled. Nothing for a task in no project.
    function requireExtensionAllowed(AppStorage storage s, bytes32 taskId, uint256 newExpiry) internal view {
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return;
        if (newExpiry > latestExpiry(s, projectId) || !isOpen(s, poolOf(projectId))) {
            revert ITMPProject.ProjectTaskPastGrace();
        }
    }

    /// @notice The one place a task's expiry is raised by a lifecycle step (reserved acceptance,
    ///         reopen, review, revision request, evaluation, appeal). Raises expiryTime to `wanted`
    ///         if it is later than the current expiry, but a project task is held to the project's
    ///         latest expiry (end date plus task grace) and is not raised at all once the project's
    ///         pool has settled. The step still happens; only the extension is clamped.
    function extendExpiry(AppStorage storage s, bytes32 taskId, uint256 wanted) internal {
        ITMPCore.Task storage task = s.tasks[taskId];
        uint256 current = task.expiryTime;
        if (wanted <= current) return;
        uint256 projectId = s.taskProjects[taskId];
        if (projectId != 0) {
            if (!isOpen(s, poolOf(projectId))) return;
            uint256 latest = latestExpiry(s, projectId);
            if (wanted > latest) wanted = latest;
            if (wanted <= current) return;
        }
        task.expiryTime = wanted;
        emit ITMPCore.TaskExpiryExtended(taskId, wanted);
    }

    /// @notice Pays `amount` owed to the task's requester, or refunds it to the task's project.
    ///         Returns the token transfer's result, true for a refund to the project.
    function payRequester(AppStorage storage s, bytes32 taskId, uint256 amount) internal returns (bool) {
        // Rev028: every payment back to the requester's side counts toward the settlement record.
        LibSettlement.add(taskId, LibSettlement.REFUND, amount);
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return s.usdcToken.transfer(s.tasks[taskId].requester, amount);
        return _refund(taskId, amount);
    }

    /// @dev The call into the diamond, kept out of payRequester so the optimizer does not inline
    ///      it at every payout site.
    function _refund(bytes32 taskId, uint256 amount) private returns (bool) {
        ITMPProject(address(this)).refundProjectTask(taskId, amount);
        return true;
    }

    /// @notice A project's funding pool ID: the pool contract's derivation, keccak256 of the
    ///         module and the key.
    function poolOf(uint256 projectId) internal pure returns (bytes32) {
        return poolIdOf(PROJECT_MODULE, projectId);
    }

    function poolIdOf(bytes32 module, uint256 key) internal pure returns (bytes32) {
        return keccak256(abi.encode(module, key));
    }

    /// @notice The funding pool contract as its manager.
    function pool(AppStorage storage s) internal view returns (IFundingPoolManager) {
        return IFundingPoolManager(s.fundingPool);
    }

    /// @notice Whether `poolId` is open: not closed and before its end date. Reads only the
    ///         `settled` word of the pool's getPool result (PoolInfo is a static struct, `settled`
    ///         its fifth word), because decoding the whole struct at every call site costs
    ///         CoreFacet and SettlementFacet bytes they do not have. The pool's revert, such as
    ///         PoolNotFound, bubbles up.
    function isOpen(AppStorage storage s, bytes32 poolId) internal view returns (bool open) {
        address fundingPool = s.fundingPool;
        bytes4 selector = ITMPFundingPool.getPool.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 4), poolId)
            if iszero(staticcall(gas(), fundingPool, m, 36, 0, 0)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x180) { revert(0, 0) }
            returndatacopy(m, 128, 32)
            open := iszero(mload(m))
        }
    }

    /// @notice Refunds a project task's payout to its project's pool: the transfer, then the
    ///         pool's refund. Runs inside ProjectFacet.refundProjectTask, which payRequester
    ///         reaches by a call to the diamond itself, so the transfer, the pool call and the
    ///         event cost CoreFacet and SettlementFacet one call instead of being compiled into
    ///         each.
    function refund(AppStorage storage s, bytes32 taskId, uint256 amount) internal {
        uint256 projectId = s.taskProjects[taskId];
        if (amount == 0) {
            _release(s, projectId, taskId, 0);
            return;
        }
        address fundingPool = s.fundingPool;
        if (!s.usdcToken.transfer(fundingPool, amount)) revert ITMPProject.FundingTransferFailed();
        bytes32 poolId = poolOf(projectId);
        IFundingPoolManager(fundingPool).refund(poolId, amount);
        // The refunded money is available again, so it leaves outstanding in the same call. Hooks
        // run before LibEscrow.release, and would otherwise see it counted in both and mint or
        // price shares against the doubled value. The rest of the task's draw leaves at release.
        // Rev030: only pool money the task no longer holds leaves: the draw is lowered at most to
        // what the task still holds of it (LibEscrow.owedParts, read after the caller has already
        // updated the task for this payout), never below. A refund that includes money the pool
        // never paid, such as a worker's stake forfeited on a task that reopens with its reward
        // still in escrow, then lowers nothing for that part and only adds to available. Lowering
        // the draw by it would leave outstanding reading less than the live tasks hold, and a pool
        // worth nothing on paper starts a new share generation on the next credit.
        uint256 drawn = s.taskPoolDraws[taskId];
        (uint256 held,) = LibEscrow.owedParts(s, taskId);
        uint256 gone = drawn > held ? drawn - held : 0;
        uint256 applied = amount > gone ? gone : amount;
        // Rev030: the operator's cap and period meter get back the same `applied`, project money
        // coming back and nothing else. The forfeited stake still goes to the pool, but it was
        // never counted against the operator, so it must not raise the operator's cap.
        _release(s, projectId, taskId, applied);
        if (applied != 0) {
            s.taskPoolDraws[taskId] = drawn - applied;
            IFundingPoolManager(fundingPool).finish(poolId, applied);
        }
        emit ITMPProject.ProjectRefunded(projectId, taskId, amount);
    }

    /// @notice Spends `amount` of the project's open pool on a task (the pool pays it to the diamond) that `caller` creates or tops
    ///         up. `operator` is the task's operator, zero for the owner's task. When the operator
    ///         is the caller it needs an accepted, unrevoked grant and stays within its cap; the
    ///         amount counts toward the operator's committed whoever spends it, so the task's
    ///         refunds give back what was counted.
    function draw(AppStorage storage s, uint256 projectId, address caller, address operator, uint256 amount) internal {
        bytes32 poolId = poolOf(projectId);
        if (!isOpen(s, poolId)) revert ITMPProject.ProjectNotOpen();
        if (operator != address(0)) {
            ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
            ITMPProject.GrantLimits storage lim = s.projectGrantLimits[projectId][operator];
            uint256 committed = g.committed;
            if (caller == operator) {
                if (!g.exists) revert ITMPProject.NotProjectOperator();
                if (g.revoked) revert ITMPProject.GrantRevoked();
                if (!g.accepted) revert ITMPProject.GrantNotAccepted();
                uint256 cap = g.terms.cap;
                if (cap != 0 && committed + amount > cap) {
                    revert ITMPProject.OperatorCapExceeded(cap > committed ? cap - committed : 0, amount);
                }
                _requireWithinLimits(lim, amount);
            }
            g.committed = committed + amount;
            _meterDraw(lim, amount);
            emit ITMPProject.GrantCommitted(projectId, operator, committed + amount);
        }
        pool(s).spend(poolId, amount);
    }

    /// @dev Rev029: the operator's own draw must be inside the owner's limits: before the expiry,
    ///      and inside the budget of the current period.
    function _requireWithinLimits(ITMPProject.GrantLimits storage lim, uint256 amount) private view {
        uint64 expiresAt = lim.expiresAt;
        if (expiresAt != 0 && block.timestamp >= expiresAt) revert ITMPProject.GrantExpired(expiresAt);
        uint64 periodSecs = lim.periodSecs;
        if (periodSecs == 0) return;
        uint256 spent = block.timestamp >= uint256(lim.periodStart) + periodSecs ? 0 : lim.periodSpent;
        uint256 periodCap = lim.periodCap;
        if (spent + amount > periodCap) {
            revert ITMPProject.GrantPeriodCapExceeded(periodCap > spent ? periodCap - spent : 0, amount);
        }
    }

    /// @dev Rev029: adds a draw to the period meter, starting a new period when none is running or
    ///      the last one is over. The meter counts every draw on the operator's tasks, the owner's
    ///      top-ups included, as committed does; only the operator's own draws are refused.
    function _meterDraw(ITMPProject.GrantLimits storage lim, uint256 amount) private {
        if (lim.periodSecs == 0) return;
        if (lim.periodStart == 0 || block.timestamp >= uint256(lim.periodStart) + lim.periodSecs) {
            lim.periodStart = uint64(block.timestamp);
            lim.periodSpent = 0;
        }
        lim.periodSpent += uint128(amount);
    }

    /// @notice Rev029: the checks on a new project task by an operator that need the task's
    ///         configuration: its mode must be allowed and what it holds must not pass the
    ///         grant's maxRewardPerTask. Zero limits allow everything.
    function requireTaskAllowed(AppStorage storage s, uint256 projectId, address operator, bytes4 mode, uint256 amount)
        internal
        view
    {
        ITMPProject.GrantLimits storage lim = s.projectGrantLimits[projectId][operator];
        uint32 mask = lim.allowedModesMask;
        if (mask != 0 && mask & modeBit(mode) == 0) revert ITMPProject.GrantModeNotAllowed(mode);
        _requireRewardWithin(lim, amount);
    }

    function _requireRewardWithin(ITMPProject.GrantLimits storage lim, uint256 held) private view {
        uint256 maxReward = lim.maxRewardPerTask;
        if (maxReward != 0 && held > maxReward) revert ITMPProject.GrantRewardTooHigh(maxReward, held);
    }

    /// @notice Rev029: the mask bit of a built-in mode; zero for any other mode, which a grant with
    ///         a nonzero mask therefore refuses.
    function modeBit(bytes4 mode) internal pure returns (uint32) {
        if (mode == TMP_BOUNTY) return 1;
        if (mode == TMP_CLAIM) return 2;
        if (mode == TMP_PITCH) return 4;
        if (mode == TMP_BENCHMARK) return 8;
        if (mode == TMP_AUCTION) return 16;
        return 0;
    }

    /// @notice Rev029: stores a grant's limits after checking them, and restarts the period meter
    ///         when the period length changes.
    function setLimits(
        AppStorage storage s,
        uint256 projectId,
        address operator,
        ITMPProject.GrantLimitsInput calldata l
    ) internal {
        if (
            l.allowedModesMask & ~KNOWN_MODES_MASK != 0 || (l.periodSecs == 0) != (l.periodCap == 0)
                || (l.expiresAt != 0 && l.expiresAt <= block.timestamp)
        ) revert ITMPProject.InvalidGrantLimits();
        ITMPProject.GrantLimits storage lim = s.projectGrantLimits[projectId][operator];
        if (lim.periodSecs != l.periodSecs) {
            lim.periodStart = 0;
            lim.periodSpent = 0;
        }
        lim.expiresAt = l.expiresAt;
        lim.allowedModesMask = l.allowedModesMask;
        lim.maxRewardPerTask = l.maxRewardPerTask;
        lim.periodSecs = l.periodSecs;
        lim.periodCap = l.periodCap;
        emit ITMPProject.GrantLimitsSet(
            projectId, operator, l.expiresAt, l.allowedModesMask, l.maxRewardPerTask, l.periodSecs, l.periodCap
        );
    }

    /// @notice A reward increase or an evaluator stake added to a live task by `caller`. A project
    ///         task draws it from its pool, under the same checks as creating a task, and the
    ///         forwarder must report no payment; any other task is paid by the forwarder. Returns
    ///         the payment the forwarder must report.
    function topUp(AppStorage storage s, bytes32 taskId, address caller, uint256 amount)
        internal
        returns (uint256 forwarded)
    {
        if (s.taskProjects[taskId] == 0 || amount == 0) return amount;
        drawForTask(s, taskId, caller, amount);
    }

    /// @notice Draws `amount` for project task `taskId` from its project's pool, made by `caller`,
    ///         and books it as held by the task.
    function drawForTask(AppStorage storage s, bytes32 taskId, address caller, uint256 amount) internal {
        uint256 projectId = s.taskProjects[taskId];
        address operator = s.taskOperators[taskId];
        // Rev030: a caller that is now the project's owner is not held to the operator's grant,
        // whether or not it is also the task's operator: acceptProjectOwner revoked the promoted
        // owner's old grant, and the owner tops up its own tasks from the pool all the same.
        if (caller == s.projects[projectId].owner) caller = address(0);
        // Rev029: an operator topping up its own task keeps the task inside maxRewardPerTask.
        if (operator != address(0) && caller == operator) {
            _requireRewardWithin(s.projectGrantLimits[projectId][operator], s.taskPoolDraws[taskId] + amount);
        }
        draw(s, projectId, caller, operator, amount);
        s.taskPoolDraws[taskId] += amount;
        emit ITMPProject.ProjectPoolDrawn(projectId, taskId, amount);
    }

    /// @notice Lowers a project task's draw to `heldNow`, the pool money it still holds after a
    ///         payout, and takes the difference out of its pool's outstanding: spent if a worker
    ///         or an evaluator was paid, back in available if it was refunded. Called by
    ///         LibEscrow.release with what the task owes in escrow less a Claim worker's stake
    ///         (LibEscrow.owedParts). The stake is the worker's money, not the pool's: counting it
    ///         would leave the evaluator stake in outstanding after evaluate pays it to the
    ///         evaluator or evaluatorTimeout to the protocol while the worker's stake is still
    ///         held, and a backer would then buy shares at a value the pool does not have. The
    ///         draw never grows, so a forfeited stake refunded to the pool is a windfall in
    ///         available; refund never lowers the draw for it (rev030).
    function finishDraw(AppStorage storage s, bytes32 taskId, uint256 heldNow) internal {
        uint256 drawn = s.taskPoolDraws[taskId];
        if (drawn > heldNow) _finish(s, taskId, drawn - heldNow, heldNow);
    }

    /// @dev Kept out of finishDraw so the optimizer does not inline it into every facet's
    ///      LibEscrow.release.
    function _finish(AppStorage storage s, bytes32 taskId, uint256 amount, uint256 heldNow) private {
        s.taskPoolDraws[taskId] = heldNow;
        pool(s).finish(poolOf(s.taskProjects[taskId]), amount);
    }

    /// @dev Gives back to the operator's cap the project money a refund returns (refund passes
    ///      `applied`, never the full amount, so a worker's forfeited stake is not credited). The
    ///      amount still floors at zero against committed.
    function _release(AppStorage storage s, uint256 projectId, bytes32 taskId, uint256 amount) private {
        address operator = s.taskOperators[taskId];
        if (operator == address(0)) return;
        ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
        uint256 committed = g.committed > amount ? g.committed - amount : 0;
        g.committed = committed;
        // Rev029: a refund gives back to the current period, floored at zero. A period that is over
        // is not touched: what it spent stays spent, and the next draw starts a fresh one.
        ITMPProject.GrantLimits storage lim = s.projectGrantLimits[projectId][operator];
        if (lim.periodSecs != 0 && lim.periodStart != 0 && block.timestamp < uint256(lim.periodStart) + lim.periodSecs)
        {
            lim.periodSpent = lim.periodSpent > amount ? lim.periodSpent - uint128(amount) : 0;
        }
        emit ITMPProject.GrantCommitted(projectId, operator, committed);
    }

    /// @notice Rev028: whether `who` is a party that may act as the requester of `taskId`: the
    ///         requester of record, and for a project task also its operator and the project's
    ///         owner. The self-dealing guards (evaluator, dispute resolver, reserved worker) test
    ///         against all of them, because the requester of record alone is not who acts. The zero
    ///         address is never a party.
    function isActingParty(AppStorage storage s, bytes32 taskId, address who) internal view returns (bool) {
        if (who == address(0)) return false;
        if (who == s.tasks[taskId].requester) return true;
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return false;
        return who == s.taskOperators[taskId] || who == s.projects[projectId].owner;
    }

    /// @notice Reverts InvalidWorker when `worker` is the requester of record, the operator or the owner
    ///         of a project task: whoever acts for a project task cannot also be its worker, or they
    ///         could accept their own work and draw on the backers' pool. A task outside a project is
    ///         unchanged.
    function requireNotActingParty(AppStorage storage s, bytes32 taskId, address worker) internal view {
        if (s.taskProjects[taskId] != 0 && isActingParty(s, taskId, worker)) revert ITMPCore.InvalidWorker();
    }

    /// @notice Whether `caller` may act as the requester of an operator-created project task. The
    ///         operator acts unless its grant was revoked with revokeRemovesControl. The owner
    ///         acts when ownerOverride is set, and always once a revoke removed the operator's
    ///         control. Any other caller may not, whoever is task.requester.
    function mayAct(AppStorage storage s, bytes32 taskId, address caller) internal view returns (bool) {
        address operator = s.taskOperators[taskId];
        uint256 projectId = s.taskProjects[taskId];
        ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
        bool removed = g.revoked && g.terms.revokeRemovesControl;
        // Rev029: after an owner transfer the owner can be the operator of a task it created
        // earlier, so the owner is tested first and keeps control of it.
        if (caller == s.projects[projectId].owner) return g.terms.ownerOverride || removed || caller == operator;
        return caller == operator && !removed;
    }
}
