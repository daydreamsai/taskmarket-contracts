// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibGuards } from "../libraries/LibGuards.sol";
import { LibEscrow } from "../libraries/LibEscrow.sol";
import { LibProject } from "../libraries/LibProject.sol";
import { LibFundingPool } from "../libraries/LibFundingPool.sol";
import { LibTaskCreation } from "../libraries/LibTaskCreation.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPProject } from "../interfaces/ITMPProject.sol";
import { ITMPFundingPool } from "../interfaces/ITMPFundingPool.sol";

/// @title ProjectFacet -- rev027: crowdfunded projects, one budget spent on ordinary tasks
/// @notice See ITMPProject. A project's budget is its funding pool (LibFundingPool), opened with
///         the project and closing at its end date. Backers fund and claim through
///         FundingPoolFacet; this facet spends the pool on tasks and closes it.
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
        if (endsAt > block.timestamp + LibProject.MAX_LIFETIME) revert ITMPProject.ProjectEndTooFar();
        LibGuards._requireReportedPayment(budget);

        address owner = LibGuards._effectiveSender(s);
        projectId = ++s.projectCount;
        s.projects[projectId] = ITMPProject.ProjectRecord({ owner: owner, endsAt: endsAt });
        bytes32 poolId = LibProject.poolOf(projectId);
        LibFundingPool.open(s, poolId, token, LibProject.PROJECT_MODULE, endsAt);
        LibFundingPool.credit(s, poolId, owner, owner, budget);
        // The forwarder moved the budget in before the call, so the unbooked surplus must cover it.
        LibEscrow.requireSolvent(s);
        emit ITMPProject.ProjectCreated(projectId, owner, budget, endsAt);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPProject.
    function closeProject(uint256 projectId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        LibGuards._nonReentrantBefore(s);

        // Relayed, the forwarder must report no payment, so none lands unbooked.
        if (s.trustedForwarders[msg.sender]) LibGuards._requireReportedPayment(0);
        ITMPProject.ProjectRecord storage p = _project(s, projectId);
        bytes32 poolId = LibProject.poolOf(projectId);
        if (s.fundingPools[poolId].closed) revert ITMPProject.ProjectAlreadyClosed();
        address caller = LibGuards._effectiveSender(s);
        if (caller != p.owner && block.timestamp < p.endsAt) revert ITMPProject.NotProjectOwner();

        // Closing moves no money: what the pool holds stays booked and is now the backers' pot.
        LibFundingPool.close(s, poolId);
        LibEscrow.requireSolvent(s);
        emit ITMPProject.ProjectClosed(projectId, caller, s.fundingPools[poolId].available);
        LibGuards._nonReentrantAfter(s);
    }

    /// @notice See ITMPProject.
    function projectPoolId(uint256 projectId) external view returns (bytes32) {
        _project(LibAppStorage.appStorage(), projectId);
        return LibProject.poolOf(projectId);
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

    /// @notice See ITMPProject. Called by CoreFacet.updateTask through the diamond, inside that
    ///         entrypoint's pause and reentrancy checks, so it takes neither itself.
    function drawTopUp(bytes32 taskId, address caller, uint256 amount) external {
        if (msg.sender != address(this)) revert ITMPProject.NotDiamond();
        LibProject.drawForTask(LibAppStorage.appStorage(), taskId, caller, amount);
    }

    /// @notice See ITMPProject.
    function grantOperator(uint256 projectId, address operator, ITMPProject.GrantTerms calldata terms) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibGuards._requireNotPaused(s);
        ITMPProject.ProjectRecord storage p = _project(s, projectId);
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
        ITMPProject.ProjectRecord storage p = _project(s, projectId);
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
        AppStorage storage s = LibAppStorage.appStorage();
        ITMPProject.ProjectRecord storage p = _project(s, projectId);
        ITMPFundingPool.Pool storage pool = s.fundingPools[LibProject.poolOf(projectId)];
        return ITMPProject.Project({
            owner: p.owner, endsAt: p.endsAt, closed: pool.closed, funded: pool.funded, available: pool.available
        });
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

    /// @dev Checks the caller may spend `amount` of the project's budget and spends it from the
    ///      pool (LibProject.draw), which unbooks it, so the task's own booking in LibTaskCreation
    ///      finds it as surplus. projectPrepaid tells the creation payment checks the task is
    ///      already paid for. Returns the task's requester: the owner, or the operator when its
    ///      grant says so. An operator needs an accepted, unrevoked grant and stays within its cap.
    function _authorizeSpend(AppStorage storage s, uint256 projectId, uint256 amount)
        private
        returns (address requester)
    {
        address projectOwner = _project(s, projectId).owner;
        address caller = LibGuards._effectiveSender(s);
        address operator = caller == projectOwner ? address(0) : caller;
        LibProject.draw(s, projectId, caller, operator, amount);
        requester = projectOwner;
        if (
            operator != address(0)
                && s.projectGrants[projectId][operator].terms.requesterOfRecord
                    == ITMPProject.RequesterOfRecord.Operator
        ) requester = operator;
        s.projectPrepaid = amount;
    }

    function _link(AppStorage storage s, uint256 projectId, bytes32 taskId) private {
        uint256 amount = s.projectPrepaid;
        s.projectPrepaid = 0;
        address creator = LibGuards._effectiveSender(s);
        s.taskProjects[taskId] = projectId;
        s.taskCreators[taskId] = creator;
        s.taskPoolDraws[taskId] = amount;
        if (creator != s.projects[projectId].owner) s.taskOperators[taskId] = creator;
        s.projectTaskIds[projectId].push(taskId);
        emit ITMPProject.ProjectTaskCreated(projectId, taskId, creator, amount);
    }

    function _project(AppStorage storage s, uint256 projectId)
        private
        view
        returns (ITMPProject.ProjectRecord storage p)
    {
        p = s.projects[projectId];
        if (p.owner == address(0)) revert ITMPProject.ProjectNotFound();
    }
}
