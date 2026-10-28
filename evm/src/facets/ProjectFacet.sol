// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { LibProject } from "../libraries/LibProject.sol";
import { LibTaskCreation } from "../libraries/LibTaskCreation.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPProject } from "../interfaces/ITMPProject.sol";

/// @title ProjectFacet -- rev027: projects, one budget spent on ordinary tasks
/// @notice See ITMPProject. A project's available budget is an escrow liability from the moment it
///         is paid in until it funds a task, comes back as a refund, or is returned on close.
contract ProjectFacet {
    /// @notice See ITMPProject.
    function createProject(address token, uint256 budget, uint64 endsAt) external returns (uint256 projectId) {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        if (token != address(s.usdcToken)) revert ITMPProject.ProjectTokenNotAllowed();
        if (budget == 0) revert ITMPProject.ProjectBudgetZero();
        if (endsAt <= block.timestamp) revert ITMPProject.ProjectEndNotInFuture();
        LibGuards._requireReportedPayment(budget);

        address owner = LibGuards._effectiveSender(s);
        projectId = ++s.projectCount;
        s.projects[projectId] =
            ITMPProject.Project({ owner: owner, endsAt: endsAt, closed: false, funded: budget, available: budget });
        _bookIn(s, budget);
        emit ITMPProject.ProjectCreated(projectId, owner, budget, endsAt);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPProject.
    function topUpProject(uint256 projectId, uint256 amount) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        ITMPProject.Project storage p = _ownedOpenProject(s, projectId);
        if (amount == 0) revert ITMPProject.ProjectBudgetZero();
        LibGuards._requireReportedPayment(amount);

        p.funded += amount;
        p.available += amount;
        _bookIn(s, amount);
        emit ITMPProject.ProjectToppedUp(projectId, amount);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPProject.
    function closeProject(uint256 projectId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        ITMPProject.Project storage p = _project(s, projectId);
        if (p.closed) revert ITMPProject.ProjectAlreadyClosed();
        address caller = LibGuards._effectiveSender(s);
        if (caller != p.owner && block.timestamp < p.endsAt) revert ITMPProject.NotProjectOwner();

        uint256 returned = p.available;
        p.closed = true;
        p.available = 0;
        s.totalLiabilities -= returned;
        if (returned > 0 && !s.usdcToken.transfer(p.owner, returned)) revert ITMPCore.RefundFailed();
        LibEscrow.requireSolvent(s);
        emit ITMPProject.ProjectClosed(projectId, caller, returned);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPProject.
    function createProjectTask(
        uint256 projectId,
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms,
        address reservedWorker
    ) external returns (bytes32 taskId) {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireForwarder(s);
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        address requester = _authorizeSpend(s, projectId, config.reward + evaluatorConfig.evaluatorStake);
        taskId =
            LibTaskCreation.create(s, requester, config, hookConfig, content, evaluatorConfig, terms, reservedWorker);
        _link(s, projectId, taskId);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPProject.
    function grantOperator(uint256 projectId, address operator, ITMPProject.GrantTerms calldata terms) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        ITMPProject.Project storage p = _project(s, projectId);
        if (LibGuards._effectiveSender(s) != p.owner) revert ITMPProject.NotProjectOwner();
        if (operator == address(0) || operator == p.owner) revert ITMPProject.InvalidOperator();
        ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
        if (g.revoked) revert ITMPProject.GrantRevoked();
        if (g.accepted) revert ITMPProject.GrantAlreadyAccepted();
        g.terms = terms;
        g.exists = true;
        emit ITMPProject.OperatorGranted(projectId, operator, terms);
    }

    /// @notice See ITMPProject.
    function acceptGrant(uint256 projectId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        _project(s, projectId);
        address operator = LibGuards._effectiveSender(s);
        ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
        if (!g.exists) revert ITMPProject.GrantNotFound();
        if (g.revoked) revert ITMPProject.GrantRevoked();
        if (g.accepted) revert ITMPProject.GrantAlreadyAccepted();
        g.accepted = true;
        emit ITMPProject.GrantAccepted(projectId, operator);
    }

    /// @notice See ITMPProject.
    function revokeOperator(uint256 projectId, address operator) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        ITMPProject.Project storage p = _project(s, projectId);
        if (LibGuards._effectiveSender(s) != p.owner) revert ITMPProject.NotProjectOwner();
        ITMPProject.Grant storage g = s.projectGrants[projectId][operator];
        if (!g.exists) revert ITMPProject.GrantNotFound();
        if (g.revoked) revert ITMPProject.GrantRevoked();
        g.revoked = true;
        emit ITMPProject.OperatorRevoked(projectId, operator);
    }

    /// @notice See ITMPProject.
    function getGrant(uint256 projectId, address operator) external view returns (ITMPProject.Grant memory) {
        return LibAppStorage.appStorage().projectGrants[projectId][operator];
    }

    /// @notice See ITMPProject.
    function taskOperator(bytes32 taskId) external view returns (address) {
        return LibAppStorage.appStorage().taskOperators[taskId];
    }

    /// @notice See ITMPProject.
    function getProject(uint256 projectId) external view returns (ITMPProject.Project memory) {
        return _project(LibAppStorage.appStorage(), projectId);
    }

    /// @notice See ITMPProject.
    function projectOf(bytes32 taskId) external view returns (uint256) {
        return LibAppStorage.appStorage().taskProjects[taskId];
    }

    /// @notice See ITMPProject.
    function taskCreatedBy(bytes32 taskId) external view returns (address) {
        return LibAppStorage.appStorage().taskCreators[taskId];
    }

    /// @notice See ITMPProject.
    function projectTaskCount(uint256 projectId) external view returns (uint256) {
        return LibAppStorage.appStorage().projectTaskIds[projectId].length;
    }

    /// @notice See ITMPProject.
    function projectTasks(uint256 projectId, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory taskIds)
    {
        bytes32[] storage all = LibAppStorage.appStorage().projectTaskIds[projectId];
        uint256 len = all.length;
        if (offset >= len) return new bytes32[](0);
        uint256 end = len - offset < limit ? len : offset + limit;
        taskIds = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            taskIds[i - offset] = all[i];
        }
    }

    /// @notice See ITMPProject.
    function projectCount() external view returns (uint256) {
        return LibAppStorage.appStorage().projectCount;
    }

    /// @dev Checks the caller may spend `amount` of the project's budget, takes it out and unbooks it,
    ///      so the task's own booking in LibTaskCreation finds it as surplus. projectPrepaid tells the
    ///      creation payment checks the task is already paid for. Returns the task's requester: the
    ///      owner, or the operator when its grant says so. An operator needs an accepted, unrevoked
    ///      grant and stays within its cap.
    function _authorizeSpend(AppStorage storage s, uint256 projectId, uint256 amount)
        private
        returns (address requester)
    {
        ITMPProject.Project storage p = _project(s, projectId);
        if (!LibProject.isOpen(p)) revert ITMPProject.ProjectNotOpen();
        address caller = LibGuards._effectiveSender(s);
        requester = p.owner;
        if (caller != requester) {
            ITMPProject.Grant storage g = s.projectGrants[projectId][caller];
            if (!g.exists) revert ITMPProject.NotProjectOperator();
            if (g.revoked) revert ITMPProject.GrantRevoked();
            if (!g.accepted) revert ITMPProject.GrantNotAccepted();
            uint256 cap = g.terms.cap;
            if (cap != 0 && g.committed + amount > cap) {
                revert ITMPProject.OperatorCapExceeded(cap > g.committed ? cap - g.committed : 0, amount);
            }
            g.committed += amount;
            if (g.terms.requesterOfRecord == ITMPProject.RequesterOfRecord.Operator) requester = caller;
        }
        uint256 available = p.available;
        if (amount > available) revert ITMPProject.ProjectBudgetExceeded(available, amount);
        p.available = available - amount;
        s.totalLiabilities -= amount;
        s.projectPrepaid = amount;
    }

    function _link(AppStorage storage s, uint256 projectId, bytes32 taskId) private {
        uint256 amount = s.projectPrepaid;
        s.projectPrepaid = 0;
        address creator = LibGuards._effectiveSender(s);
        s.taskProjects[taskId] = projectId;
        s.taskCreators[taskId] = creator;
        if (creator != s.projects[projectId].owner) s.taskOperators[taskId] = creator;
        s.projectTaskIds[projectId].push(taskId);
        emit ITMPProject.ProjectTaskCreated(projectId, taskId, creator, amount);
    }

    /// @dev Books money just paid into a project. The forwarder moved it in before the call, so the
    ///      unbooked surplus must cover it.
    function _bookIn(AppStorage storage s, uint256 amount) private {
        s.totalLiabilities += amount;
        LibEscrow.requireSolvent(s);
    }

    function _project(AppStorage storage s, uint256 projectId) private view returns (ITMPProject.Project storage p) {
        p = s.projects[projectId];
        if (p.owner == address(0)) revert ITMPProject.ProjectNotFound();
    }

    function _ownedOpenProject(AppStorage storage s, uint256 projectId)
        private
        view
        returns (ITMPProject.Project storage p)
    {
        p = _project(s, projectId);
        if (LibGuards._effectiveSender(s) != p.owner) revert ITMPProject.NotProjectOwner();
        if (!LibProject.isOpen(p)) revert ITMPProject.ProjectNotOpen();
    }
}
