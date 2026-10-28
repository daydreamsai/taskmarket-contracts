// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";

/// @title ITMPProject -- rev027: a project, one budget spent on ordinary tasks
/// @notice A project holds a budget in the task payment stablecoin, an end date and an owner. The
///         owner spends the budget by creating tasks of any mode from it: one transaction moves
///         the reward (and any evaluator stake) from the budget into the new task's escrow, with
///         no transfer. Any money a project task would pay its requester (a refund, an unspent
///         auction or split remainder, a returned evaluator stake, a worker-stake penalty) is
///         credited back to the budget while the project is open and before its end date, and is
///         paid to the owner after that. The end date stops new tasks only: a task already funded
///         runs to its end. The unspent budget is an escrow liability, so the surplus sweep can
///         never take it.
interface ITMPProject {
    struct Project {
        address owner;
        uint64 endsAt;
        bool closed;
        // Everything the owner has paid in: the opening budget plus every top-up.
        uint256 funded;
        // Unspent and uncommitted: what the next project task can draw on.
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
    ///      requesterOfRecord is the address that is task.requester on the operator's tasks.
    ///      ownerOverride lets the owner act on the operator's tasks when the owner is not the
    ///      requester of record, or stops it when the owner is. revokeRemovesControl moves control
    ///      of the operator's tasks to the owner when the grant is revoked; otherwise the operator
    ///      finishes what it started.
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
    event ProjectToppedUp(uint256 indexed projectId, uint256 amount);
    /// @notice amount is what left the budget: the task's reward plus any evaluator stake.
    event ProjectTaskCreated(
        uint256 indexed projectId, bytes32 indexed taskId, address indexed createdBy, uint256 amount
    );
    /// @notice Money a project task paid its requester came back to the budget.
    event ProjectRefunded(uint256 indexed projectId, bytes32 indexed taskId, uint256 amount);
    /// @notice returned is the unspent budget paid to the owner.
    event ProjectClosed(uint256 indexed projectId, address indexed closedBy, uint256 returned);

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
    /// @notice Only the task payment stablecoin can fund a project.
    error ProjectTokenNotAllowed();
    error ProjectBudgetExceeded(uint256 available, uint256 needed);
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

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @notice Open a project funded with `budget` of `token`, which must be the task payment
    ///         stablecoin. The forwarder must have moved exactly `budget` into escrow. The caller
    ///         is the owner.
    function createProject(address token, uint256 budget, uint64 endsAt) external returns (uint256 projectId);

    /// @notice The owner adds `amount` to an open project. The forwarder must have moved exactly
    ///         `amount` into escrow.
    function topUpProject(uint256 projectId, uint256 amount) external;

    /// @notice Close the project and pay its unspent budget to the owner. The owner may close it
    ///         at any time, anyone once it is past its end date. Tasks already funded run on; what
    ///         they later pay their requester goes to the owner.
    function closeProject(uint256 projectId) external;

    /// @notice The owner, or an operator with an accepted, unrevoked grant, creates a task funded
    ///         from the project, as createTask with a reserved worker (zero for an ordinary
    ///         task). The forwarder must report no payment: the reward and any evaluator stake
    ///         come out of the project's available budget, and an operator's out of its cap too.
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
