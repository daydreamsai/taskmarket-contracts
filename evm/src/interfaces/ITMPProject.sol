// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";

/// @title ITMPProject -- rev027: a crowdfunded project, one budget spent on ordinary tasks
/// @notice A project holds a budget in the task payment stablecoin, an end date and an owner. The
///         budget is the project's funding pool (ITMPFundingPool, projectPoolId), which closes at
///         the end date: the owner's opening budget is the owner's contribution, and anyone may
///         back the project by funding the pool while it is open, buying shares at the pool's
///         current value. The owner spends the budget by creating tasks of any mode from it: one
///         transaction moves the reward (and any evaluator stake) from the pool into the new
///         task's escrow, with no transfer. A later reward increase or evaluator stake on a
///         project task is drawn from the pool the same way. Any money
///         a project task would pay its requester (a refund, an unspent auction or split
///         remainder, a returned evaluator stake, a worker-stake penalty) is refunded to the
///         pool. Once the project is closed or past its end date nothing can be spent from the
///         pool: what it holds, plus every later refund, is the backers' pot, which each backer
///         claims from the pool in proportion to its shares. The end date stops new tasks
///         and funding only: a task already funded runs to its end.
interface ITMPProject {
    /// @notice What the diamond stores for a project; the budget lives in its pool.
    struct ProjectRecord {
        address owner;
        uint64 endsAt;
        // How long after endsAt a project task's expiry may run, chosen at creation (at most
        // 90 days) and fixed. A backer's money is held at most until endsAt plus this.
        uint32 taskGraceSecs;
    }

    /// @notice A project as getProject reports it, with its pool's budget fields.
    struct Project {
        address owner;
        uint64 endsAt;
        // How long after endsAt a project task's expiry may run; fixed at creation.
        uint32 taskGraceSecs;
        // The pool is closed: the owner closed it, or anyone did after the end date.
        bool closed;
        // Every contribution to the pool: the owner's opening budget plus every backer's.
        uint256 funded;
        // While the project is open, what the next project task can draw on; once it is not,
        // the backers' unclaimed pot.
        uint256 available;
    }

    /// @notice Who the requester of record is on a task an operator creates.
    enum RequesterOfRecord {
        Owner,
        Operator
    }

    /// @notice What the owner and the operator agree on. The contract stores no defaults: the
    ///         caller states every term. Frozen when the operator calls acceptGrant.
    /// @dev cap is the most the operator's tasks may draw from the budget over the life of the
    ///      grant, net of what their refunds return (lifetime net spend, not what is held at
    ///      once); zero means no cap beyond the project's available budget.
    ///      requesterOfRecord decides only who is task.requester on the operator's tasks (and so
    ///      whom ratings and reputation follow); it does not decide who may act as requester.
    ///      On an operator's task the operator may act unless its grant was revoked with
    ///      revokeRemovesControl. ownerOverride lets the owner act too; when it is false, the
    ///      owner may not act until a revoke removes the operator's control. revokeRemovesControl
    ///      makes a revoke pass control of the operator's existing tasks to the owner, and the
    ///      operator loses it; when it is false, the operator finishes what it started. Nobody
    ///      else may act, whoever is task.requester.
    struct GrantTerms {
        uint256 cap;
        RequesterOfRecord requesterOfRecord;
        bool ownerOverride;
        bool revokeRemovesControl;
    }

    struct Grant {
        GrantTerms terms;
        // The operator's tasks' draw on the budget, net of refunds.
        uint256 committed;
        bool exists;
        bool accepted;
        bool revoked;
    }

    /// @notice rev029: what the owner sets on top of a grant's terms, per project and operator.
    ///         Kept outside GrantTerms because acceptGrant hashes the terms. Zero in every field
    ///         means no limit, so a grant that never had limits set behaves as before.
    /// @dev expiresAt: unix seconds after which the operator cannot draw. allowedModesMask: bit n
    ///      allows the nth mode of the MODE_* list in LibProject (bounty 0, claim 1, pitch 2,
    ///      benchmark 3, auction 4); zero allows every mode, bits beyond the last mode revert.
    ///      maxRewardPerTask: the most one task may hold from the budget, its reward plus any
    ///      evaluator stake, counting later top-ups. periodSecs/periodCap: the operator may draw at
    ///      most periodCap net of refunds in any period of periodSecs; zero periodSecs turns the
    ///      budget off, and a nonzero periodSecs needs a nonzero periodCap.
    struct GrantLimitsInput {
        uint64 expiresAt;
        uint32 allowedModesMask;
        uint128 maxRewardPerTask;
        uint64 periodSecs;
        uint128 periodCap;
    }

    /// @notice The limits as stored: the owner's input plus the period meter. periodStart is when
    ///         the current period began (zero before the first draw), periodSpent what the operator
    ///         drew in it, net of refunds.
    struct GrantLimits {
        uint64 expiresAt;
        uint32 allowedModesMask;
        uint64 periodSecs;
        uint64 periodStart;
        uint128 maxRewardPerTask;
        uint128 periodCap;
        uint128 periodSpent;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ProjectCreated(
        uint256 indexed projectId, address indexed owner, uint256 budget, uint64 endsAt, uint32 taskGraceSecs
    );
    /// @notice amount is what left the budget: the task's reward plus any evaluator stake.
    event ProjectTaskCreated(
        uint256 indexed projectId, bytes32 indexed taskId, address indexed createdBy, uint256 amount
    );
    /// @notice Money a project task paid its requester came back to the project's pool: budget
    ///         while the project is open, the backers' pot once it is not.
    /// @notice The project's pool paid `amount` out to the diamond for a task: at creation, or a
    ///         later reward increase or evaluator stake. The pool contract's PoolSpent carries no
    ///         task, so this is what ties the draw to it.
    event ProjectPoolDrawn(uint256 indexed projectId, bytes32 indexed taskId, uint256 amount);
    event ProjectRefunded(uint256 indexed projectId, bytes32 indexed taskId, uint256 amount);
    /// @notice leftover is what the pool held at closing, from now on the backers' pot: the
    ///         unspent budget, less anything already claimed if it closes after its end date.
    event ProjectClosed(uint256 indexed projectId, address indexed closedBy, uint256 leftover);

    event FundingPoolSet(address indexed pool);
    event OperatorGranted(uint256 indexed projectId, address indexed operator, GrantTerms terms);
    event GrantAccepted(uint256 indexed projectId, address indexed operator);
    event OperatorRevoked(uint256 indexed projectId, address indexed operator);
    /// @notice rev029: the owner raised a live grant's cap in place. The terms hash an operator
    ///         reviewed changes with it, so a pending grant must be accepted again against the
    ///         new terms.
    event GrantCapRaised(uint256 indexed projectId, address indexed operator, uint256 oldCap, uint256 newCap);
    /// @notice rev029: the owner lowered a live grant's lifetime cap, never below what the
    ///         operator's tasks still hold.
    event GrantCapLowered(uint256 indexed projectId, address indexed operator, uint256 oldCap, uint256 newCap);
    /// @notice rev029: the owner set the grant's limits (all of them, as stated).
    event GrantLimitsSet(
        uint256 indexed projectId,
        address indexed operator,
        uint64 expiresAt,
        uint32 allowedModesMask,
        uint128 maxRewardPerTask,
        uint64 periodSecs,
        uint128 periodCap
    );
    /// @notice rev029: the operator's committed (its tasks' net draw on the budget) after a draw
    ///         or a refund on one of its tasks. The one number a cap is measured against.
    event GrantCommitted(uint256 indexed projectId, address indexed operator, uint256 committed);

    /// @notice rev029: the owner named `pendingOwner` to take the project over. Nothing else
    ///         changes until it accepts. A new proposal replaces an earlier one.
    event ProjectOwnerProposed(uint256 indexed projectId, address indexed owner, address indexed pendingOwner);
    /// @notice rev029: the owner withdrew the pending proposal to `pendingOwner`.
    event ProjectOwnerProposalCancelled(uint256 indexed projectId, address indexed owner, address indexed pendingOwner);
    /// @notice rev029: the pending owner accepted. `previousOwner`'s own backing in the project's
    ///         pool moved to `newOwner` (`sharesMoved` shares; zero if it held none).
    event ProjectOwnerChanged(
        uint256 indexed projectId, address indexed previousOwner, address indexed newOwner, uint256 sharesMoved
    );
    /// @notice rev029: the owner moved the end date later, and the pool's closing date with it.
    event ProjectEndExtended(uint256 indexed projectId, uint64 previousEndsAt, uint64 newEndsAt);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ProjectNotFound();
    /// @notice rev029: the proposed owner is the zero address, the current owner, the diamond or
    ///         the funding pool.
    error InvalidProjectOwner();
    /// @notice rev029: acceptProjectOwner or cancelProjectOwner with no proposal pending.
    error NoPendingProjectOwner();
    /// @notice rev029: the caller is not the address the pending proposal names.
    error NotPendingProjectOwner();
    /// @notice rev029: the new end date is not after the current one.
    error ProjectEndNotExtended(uint64 currentEndsAt, uint64 requestedEndsAt);
    error NotProjectOwner();
    /// @notice The project is closed or past its end date.
    error ProjectNotOpen();
    error ProjectAlreadyClosed();
    error ProjectBudgetZero();
    error ProjectEndNotInFuture();
    /// @notice endsAt is more than 365 days after the block's timestamp.
    error ProjectEndTooFar();
    /// @notice taskGraceSecs is more than 90 days.
    error ProjectGraceTooLong();
    /// @notice A project task's expiry would run past the project's endsAt plus its task grace
    ///         period, or would be extended once the project's pool has settled.
    error ProjectTaskPastGrace();
    /// @notice Only the task payment stablecoin can fund a project.
    error ProjectTokenNotAllowed();
    /// @notice The caller is neither the owner nor an operator granted on this project.
    error NotProjectOperator();
    error InvalidOperator();
    /// @notice The operator has not accepted the grant.
    error GrantNotAccepted();
    /// @notice The grant was accepted, so its terms are frozen.
    error GrantAlreadyAccepted();
    error GrantRevoked();
    error GrantNotFound();
    error GrantTermsMismatch(bytes32 expected, bytes32 actual);
    /// @notice rev029: a grant's new cap is below what the operator's tasks still hold.
    error GrantCapBelowCommitted(uint256 cap, uint256 committed);
    /// @notice rev029: raiseGrantCap needs a cap strictly above a nonzero current cap.
    error GrantCapNotRaised(uint256 currentCap, uint256 requestedCap);
    /// @notice rev029: lowerGrantCap needs a nonzero cap below the current one (or any cap on a grant
    ///         that has none).
    error GrantCapNotLowered(uint256 currentCap, uint256 requestedCap);
    /// @notice rev029: the grant's expiry has passed.
    error GrantExpired(uint64 expiresAt);
    /// @notice rev029: the task's mode is not in the grant's allowed modes.
    error GrantModeNotAllowed(bytes4 mode);
    /// @notice rev029: the task would hold more than the grant's maxRewardPerTask.
    error GrantRewardTooHigh(uint256 maxReward, uint256 needed);
    /// @notice rev029: the draw would pass the grant's budget for the current period.
    error GrantPeriodCapExceeded(uint256 remaining, uint256 needed);
    /// @notice rev029: the limits are malformed (an unknown mode bit, a period without a cap, an
    ///         expiry in the past).
    error InvalidGrantLimits();
    error OperatorCapExceeded(uint256 remaining, uint256 needed);
    /// @notice Only the diamond itself may call this function.
    error NotDiamond();
    /// @notice The diamond has no funding pool contract yet: initFundingPool has not run.
    error FundingPoolNotSet();
    /// @notice initFundingPool has already run; the pool address is set once.
    error FundingPoolAlreadySet();
    /// @notice The address given to initFundingPool is not a pool that names this diamond manager.
    error FundingPoolInvalid();
    /// @notice The token transfer into the pool failed.
    error FundingTransferFailed();

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @notice Open a project funded with `budget` of `token`, which must be the task payment
    ///         stablecoin. The forwarder must have moved exactly `budget` into escrow. The caller
    ///         is the owner. `endsAt` must be in the future and at most 365 days away. Opens the
    ///         project's pool, closing at `endsAt`, with `budget` as the owner's contribution.
    ///         `taskGraceSecs`, at most 90 days and fixed from now on, is how long after `endsAt`
    ///         a project task's expiry may run: every project task must expire by
    ///         endsAt + taskGraceSecs, so a backer's money is held at most that long.
    function createProject(address token, uint256 budget, uint64 endsAt, uint32 taskGraceSecs)
        external
        returns (uint256 projectId);

    /// @notice Close the project and its pool: the unspent budget becomes the backers' pot. The owner may close
    ///         it at any time, anyone once it is past its end date. Tasks already funded run on;
    ///         what they later pay their requester goes into the pot too. A project past its end
    ///         date has a pot whether or not anyone closes it. Relayed, the forwarder must report
    ///         no payment.
    function closeProject(uint256 projectId) external;

    /// @notice The project's funding pool: fund it to back the project, claim from it once the
    ///         project is closed or past its end date.
    function projectPoolId(uint256 projectId) external view returns (bytes32);

    /// @notice Sets the funding pool contract the diamond calls. Owner only, and only once: there
    ///         is no setter. The pool must name this diamond as its manager.
    function initFundingPool(address pool) external;

    /// @notice The funding pool contract; zero before initFundingPool.
    function fundingPool() external view returns (address);

    /// @notice Pays `amount` into `poolId` for `onBehalfOf` (the funder when zero), relayed by a
    ///         trusted forwarder that moved the payment into the diamond and reports it. The
    ///         diamond forwards it to the pool and holds nothing after the call. Backers who pay
    ///         from their own wallet call the pool's fund directly.
    function fund(bytes32 poolId, uint256 amount, address onBehalfOf) external;

    /// @notice Pays `backer` its share of a settled pool, forwarded to the pool's claim.
    ///         Permissionless; a forwarder must report no payment.
    function claim(bytes32 poolId, address backer) external returns (uint256 amount);

    /// @notice The owner, or an operator with an accepted, unrevoked grant, creates a task funded
    ///         from the project, as createTask with a reserved worker (zero for an ordinary
    ///         task). The forwarder must report no payment: the reward and any evaluator stake
    ///         come out of the project's pool, and an operator's out of its cap too.
    ///         task.requester is the owner, or the operator when the grant says so.
    function createProjectTask(
        uint256 projectId,
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms,
        address reservedWorker
    ) external returns (bytes32 taskId);

    /// @notice A reward increase of `amount` on project task `taskId`, made by `caller`, drawn from
    ///         the project's pool under the same checks as creating a task. Callable only by the
    ///         diamond itself: updateTask calls it, which keeps CoreFacet under its size budget.
    function drawTopUp(bytes32 taskId, address caller, uint256 amount) external;

    /// @notice Pays `amount` owed to a project task's requester back to its project's pool.
    ///         Called by the diamond's own payout paths through the diamond, inside their pause
    ///         and reentrancy checks, so it takes neither itself. Reverts NotDiamond for any
    ///         other caller.
    function refundProjectTask(bytes32 taskId, uint256 amount) external;

    /// @notice The owner grants `operator` the right to spend the project's budget under `terms`,
    ///         or replaces the terms of a grant the operator has not accepted. Owner only.
    ///         rev029: also grants again after a revoke, which resets the grant to pending with the
    ///         new terms. `committed` carries over, so a nonzero cap below it reverts
    ///         GrantCapBelowCommitted. An accepted grant that is not revoked reverts
    ///         GrantAlreadyAccepted.
    function grantOperator(uint256 projectId, address operator, GrantTerms calldata terms) external;

    /// @notice rev029: the owner raises the cap of a pending or accepted grant that is not revoked.
    ///         `newCap` must be strictly above a nonzero current cap (GrantCapNotRaised otherwise;
    ///         a zero cap already means no cap). No other term changes. Owner only.
    function raiseGrantCap(uint256 projectId, address operator, uint256 newCap) external;

    /// @notice rev029: the owner lowers the lifetime cap of a pending or accepted grant that is not
    ///         revoked. `newCap` must be nonzero and below the current cap (any nonzero cap is a
    ///         tightening of a grant with none), and at least `committed`: GrantCapBelowCommitted
    ///         otherwise. Owner only.
    function lowerGrantCap(uint256 projectId, address operator, uint256 newCap) external;

    /// @notice rev029: the owner sets all of a grant's limits as stated. A pending grant is edited
    ///         freely. On an accepted grant the owner may tighten and may loosen: limits are not in
    ///         the terms hash, loosening only widens what the operator may do, and the owner can
    ///         revoke at any time anyway. A revoked grant reverts GrantRevoked. The period meter
    ///         restarts when periodSecs changes. Owner only.
    function setGrantLimits(uint256 projectId, address operator, GrantLimitsInput calldata limits) external;

    /// @notice rev029: the grant's limits and period meter as stored.
    function getGrantLimits(uint256 projectId, address operator) external view returns (GrantLimits memory);

    /// @notice The operator accepts its grant as recorded, which freezes the terms. The operator
    ///         can spend only after this. `termsHash` is `keccak256(abi.encode(terms))` of the
    ///         terms the operator reviewed; it must equal the stored terms, so terms the owner
    ///         replaced after the operator read them cannot be accepted by mistake.
    function acceptGrant(uint256 projectId, bytes32 termsHash) external;

    /// @notice The owner ends an operator's right to create tasks. What happens to the tasks it
    ///         already created follows the grant's revokeRemovesControl. Owner only.
    function revokeOperator(uint256 projectId, address operator) external;

    function getGrant(uint256 projectId, address operator) external view returns (Grant memory);

    /// @notice rev029: the owner proposes `newOwner` as the project's owner. Owner only, while the
    ///         project is open. Changes nothing until `newOwner` accepts; a later proposal replaces
    ///         this one. Reverts InvalidProjectOwner for the zero address, the current owner, the
    ///         diamond and the funding pool.
    function proposeProjectOwner(uint256 projectId, address newOwner) external;

    /// @notice rev029: the owner withdraws the pending proposal. Owner only; allowed at any time,
    ///         including once the project is closed.
    function cancelProjectOwner(uint256 projectId) external;

    /// @notice rev029: the pending owner takes the project over, while it is open. The owner
    ///         becomes the caller; the previous owner's own backing in the pool moves to it
    ///         (other backers' shares never move); a live grant the new owner held as an operator
    ///         is revoked, since it now acts as owner. Tasks already created keep their recorded
    ///         requester, but the project's current owner acts for them.
    function acceptProjectOwner(uint256 projectId) external;

    /// @notice rev029: the owner moves the end date later, to at most 365 days after this block,
    ///         while the project is open. The pool's closing date moves with it. Owner only.
    function extendProject(uint256 projectId, uint64 newEndsAt) external;

    /// @notice rev029: the address the pending ownership proposal names, zero when none.
    function pendingProjectOwner(uint256 projectId) external view returns (address);

    /// @notice The operator that created a task, zero for a task the owner created or no project.
    function taskOperator(bytes32 taskId) external view returns (address);

    function getProject(uint256 projectId) external view returns (Project memory);

    /// @notice The project a task belongs to, zero for none.
    function projectOf(bytes32 taskId) external view returns (uint256 projectId);

    /// @notice Who created a project task (the owner, or later an operator); zero for none.
    function taskCreatedBy(bytes32 taskId) external view returns (address);

    function projectTaskCount(uint256 projectId) external view returns (uint256);

    /// @notice Up to `limit` of the project's task IDs, in creation order, from `offset`.
    function projectTasks(uint256 projectId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory taskIds);

    /// @notice Projects created so far; IDs run from 1 to this number.
    function projectCount() external view returns (uint256);
}
