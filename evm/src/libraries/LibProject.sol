// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { ITMPProject } from "../interfaces/ITMPProject.sol";
import { LibFundingPool } from "./LibFundingPool.sol";

/// @title LibProject -- rev027: what a project task draws from its pool and where its money goes
/// @dev Every facet that pays a task's requester calls payRequester instead of transferring to
///      task.requester. For a project task the money stays in the diamond and is refunded to the
///      project's funding pool: budget the next task can draw on while the project is open, the
///      backers' pot once it is closed or past its end date. Either way it is the same single
///      write, booked in totalLiabilities before the calling entrypoint's LibEscrow.release, which
///      then releases the task's whole liability: the booking moves from the task to the pool and
///      the solvency check still holds.
///
///      What the pool spends on a task (its reward and evaluator stake at creation, and any later
///      reward increase or evaluator stake) is recorded in taskPoolDraws and counted in the pool's
///      outstanding. LibEscrow.release calls finishDraw after every payout, which lowers the record
///      to the pool money the task still holds (what it owes, less a Claim worker's stake) and
///      takes the difference out of outstanding; a terminal task owes nothing, so its whole draw
///      leaves outstanding then.
library LibProject {
    /// @notice The module ID projects open their funding pools under.
    bytes32 internal constant PROJECT_MODULE = keccak256("taskmarket.project");

    /// @notice The latest end date createProject accepts, from the block's timestamp.
    uint256 internal constant MAX_LIFETIME = 365 days;

    /// @notice The longest task grace period createProject accepts: how long after its end date
    ///         a project's tasks may run. A backer's money is held at most
    ///         MAX_LIFETIME + MAX_TASK_GRACE after the project is created.
    uint32 internal constant MAX_TASK_GRACE = 90 days;

    /// @notice The latest expiry a task of `projectId` may have: its end date plus its task
    ///         grace period.
    function latestExpiry(AppStorage storage s, uint256 projectId) internal view returns (uint256) {
        ITMPProject.ProjectRecord storage p = s.projects[projectId];
        return uint256(p.endsAt) + p.taskGraceSecs;
    }

    /// @notice Refuses updateTask's extension of a project task's expiry to `newExpiry` past the
    ///         project's end date plus its task grace period, or at all once the project's pool
    ///         has settled. Nothing for a task in no project.
    function requireExtensionAllowed(AppStorage storage s, bytes32 taskId, uint256 newExpiry) internal view {
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return;
        if (newExpiry > latestExpiry(s, projectId) || !LibFundingPool.isOpen(s.fundingPools[poolOf(projectId)])) {
            revert ITMPProject.ProjectTaskPastGrace();
        }
    }

    /// @notice Pays `amount` owed to the task's requester, or refunds it to the task's project.
    ///         Returns the token transfer's result, true for a refund to the project.
    function payRequester(AppStorage storage s, bytes32 taskId, uint256 amount) internal returns (bool) {
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return s.usdcToken.transfer(s.tasks[taskId].requester, amount);
        _credit(s, projectId, taskId, amount);
        return true;
    }

    /// @notice A project's funding pool.
    function poolOf(uint256 projectId) internal pure returns (bytes32) {
        return LibFundingPool.poolIdOf(PROJECT_MODULE, projectId);
    }

    /// @dev Refunds a project task's payout to its project's pool. Kept out of payRequester so
    ///      the optimizer does not inline it at every payout site, which costs SettlementFacet
    ///      bytes it does not have.
    function _credit(AppStorage storage s, uint256 projectId, bytes32 taskId, uint256 amount) private {
        _release(s, projectId, taskId, amount);
        if (amount == 0) return;
        LibFundingPool.refund(s, poolOf(projectId), amount);
        emit ITMPProject.ProjectRefunded(projectId, taskId, amount);
    }

    /// @notice Spends `amount` of the project's open pool on a task that `caller` creates or tops
    ///         up. `operator` is the task's operator, zero for the owner's task. When the operator
    ///         is the caller it needs an accepted, unrevoked grant and stays within its cap; the
    ///         amount counts toward the operator's committed whoever spends it, so the task's
    ///         refunds give back what was counted.
    function draw(AppStorage storage s, uint256 projectId, address caller, address operator, uint256 amount) internal {
        bytes32 poolId = poolOf(projectId);
        if (!LibFundingPool.isOpen(s.fundingPools[poolId])) revert ITMPProject.ProjectNotOpen();
        if (operator != address(0)) {
            ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
            uint256 committed = g.committed;
            if (caller == operator) {
                if (!g.exists) revert ITMPProject.NotProjectOperator();
                if (g.revoked) revert ITMPProject.GrantRevoked();
                if (!g.accepted) revert ITMPProject.GrantNotAccepted();
                uint256 cap = g.terms.cap;
                if (cap != 0 && committed + amount > cap) {
                    revert ITMPProject.OperatorCapExceeded(cap > committed ? cap - committed : 0, amount);
                }
            }
            g.committed = committed + amount;
        }
        LibFundingPool.spend(s, poolId, amount);
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
        draw(s, s.taskProjects[taskId], caller, s.taskOperators[taskId], amount);
        s.taskPoolDraws[taskId] += amount;
    }

    /// @notice Lowers a project task's draw to `heldNow`, the pool money it still holds after a
    ///         payout, and takes the difference out of its pool's outstanding: spent if a worker
    ///         or an evaluator was paid, back in available if it was refunded. Called by
    ///         LibEscrow.release with what the task owes in escrow less a Claim worker's stake
    ///         (LibEscrow.owedParts). The stake is the worker's money, not the pool's: counting it
    ///         would leave the evaluator stake in outstanding after evaluate pays it to the
    ///         evaluator or evaluatorTimeout to the protocol while the worker's stake is still
    ///         held, and a backer would then buy shares at a value the pool does not have. The
    ///         draw never grows, so a forfeited stake refunded to the pool is still a windfall.
    function finishDraw(AppStorage storage s, bytes32 taskId, uint256 heldNow) internal {
        uint256 drawn = s.taskPoolDraws[taskId];
        if (drawn > heldNow) _finish(s, taskId, drawn - heldNow, heldNow);
    }

    /// @dev Kept out of finishDraw so the optimizer does not inline it into every facet's
    ///      LibEscrow.release.
    function _finish(AppStorage storage s, bytes32 taskId, uint256 amount, uint256 heldNow) private {
        s.taskPoolDraws[taskId] = heldNow;
        LibFundingPool.finish(s, poolOf(s.taskProjects[taskId]), amount);
    }

    /// @dev Gives back to the operator's cap what a refund returns. An amount that was not drawn
    ///      from the budget, such as a worker's forfeited stake, can exceed the draw, so it floors
    ///      at zero.
    function _release(AppStorage storage s, uint256 projectId, bytes32 taskId, uint256 amount) private {
        address operator = s.taskOperators[taskId];
        if (operator == address(0)) return;
        ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
        g.committed = g.committed > amount ? g.committed - amount : 0;
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
        if (caller == operator) return !removed;
        if (caller == s.projects[projectId].owner) return g.terms.ownerOverride || removed;
        return false;
    }
}
