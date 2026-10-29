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
    }

    /// @notice A project as getProject reports it, with its pool's budget fields.
    struct Project {
        address owner;
        uint64 endsAt;
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
    /// @dev cap is the most the operator's tasks may hold from the budget at once (net of what
    ///      their refunds return); zero means no cap beyond the project's available budget.
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

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ProjectCreated(uint256 indexed projectId, address indexed owner, uint256 budget, uint64 endsAt);
    /// @notice amount is what left the budget: the task's reward plus any evaluator stake.
    event ProjectTaskCreated(
        uint256 indexed projectId, bytes32 indexed taskId, address indexed createdBy, uint256 amount
    );
    /// @notice Money a project task paid its requester came back to the project's pool: budget
    ///         while the project is open, the backers' pot once it is not.
    event ProjectRefunded(uint256 indexed projectId, bytes32 indexed taskId, uint256 amount);
    /// @notice leftover is what the pool held at closing, from now on the backers' pot: the
    ///         unspent budget, less anything already claimed if it closes after its end date.
    event ProjectClosed(uint256 indexed projectId, address indexed closedBy, uint256 leftover);

    event OperatorGranted(uint256 indexed projectId, address indexed operator, GrantTerms terms);
    event GrantAccepted(uint256 indexed projectId, address indexed operator);
    event OperatorRevoked(uint256 indexed projectId, address indexed operator);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ProjectNotFound();
    error NotProjectOwner();
    /// @notice The project is closed or past its end date.
    error ProjectNotOpen();
    error ProjectAlreadyClosed();
    error ProjectBudgetZero();
    error ProjectEndNotInFuture();
    /// @notice endsAt is more than 365 days after the block's timestamp.
    error ProjectEndTooFar();
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
    error OperatorCapExceeded(uint256 remaining, uint256 needed);
    /// @notice Only the diamond itself may call this function.
    error NotDiamond();

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @notice Open a project funded with `budget` of `token`, which must be the task payment
    ///         stablecoin. The forwarder must have moved exactly `budget` into escrow. The caller
    ///         is the owner. `endsAt` must be in the future and at most 365 days away. Opens the
    ///         project's pool, closing at `endsAt`, with `budget` as the owner's contribution.
    function createProject(address token, uint256 budget, uint64 endsAt) external returns (uint256 projectId);

    /// @notice Close the project and its pool: the unspent budget becomes the backers' pot. The owner may close
    ///         it at any time, anyone once it is past its end date. Tasks already funded run on;
    ///         what they later pay their requester goes into the pot too. A project past its end
    ///         date has a pot whether or not anyone closes it. Relayed, the forwarder must report
    ///         no payment.
    function closeProject(uint256 projectId) external;

    /// @notice The project's funding pool: fund it to back the project, claim from it once the
    ///         project is closed or past its end date.
    function projectPoolId(uint256 projectId) external view returns (bytes32);

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

    /// @notice The owner grants `operator` the right to spend the project's budget under `terms`,
    ///         or replaces the terms of a grant the operator has not accepted. Owner only.
    function grantOperator(uint256 projectId, address operator, GrantTerms calldata terms) external;

    /// @notice The operator accepts its grant as recorded, which freezes the terms. The operator
    ///         can spend only after this.
    function acceptGrant(uint256 projectId) external;

    /// @notice The owner ends an operator's right to create tasks. What happens to the tasks it
    ///         already created follows the grant's revokeRemovesControl. Owner only.
    function revokeOperator(uint256 projectId, address operator) external;

    function getGrant(uint256 projectId, address operator) external view returns (Grant memory);

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
