// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";
import { ITMPProject } from "../interfaces/ITMPProject.sol";

/// @title LibProject -- rev028: where money owed to a task's requester goes
/// @dev Every facet that pays a task's requester calls payRequester instead of transferring to
///      task.requester. For a project task the money stays in the diamond and is credited back to
///      the project's available budget while the project is open and before its end date, and is
///      paid to the project owner after that. The credit is booked in totalLiabilities before the
///      calling entrypoint's LibEscrow.release, which then releases the task's whole liability: the
///      booking moves from the task to the project and the solvency check still holds.
library LibProject {
    /// @notice Pays `amount` owed to the task's requester, or credits it to the task's project.
    ///         Returns the token transfer's result, true for a credit.
    function payRequester(AppStorage storage s, bytes32 taskId, uint256 amount) internal returns (bool) {
        uint256 projectId = s.taskProjects[taskId];
        if (projectId == 0) return s.usdcToken.transfer(s.tasks[taskId].requester, amount);
        _release(s, projectId, taskId, amount);
        ITMPProject.Project storage p = s.projects[projectId];
        if (!isOpen(p)) return s.usdcToken.transfer(p.owner, amount);
        if (amount == 0) return true;
        p.available += amount;
        s.totalLiabilities += amount;
        emit ITMPProject.ProjectRefunded(projectId, taskId, amount);
        return true;
    }

    /// @notice Open means not closed and before the end date: it can fund tasks and take refunds.
    function isOpen(ITMPProject.Project storage p) internal view returns (bool) {
        return !p.closed && block.timestamp < p.endsAt;
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
