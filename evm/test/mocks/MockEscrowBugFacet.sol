// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../../src/libraries/LibAppStorage.sol";
import { LibEscrow } from "../../src/libraries/LibEscrow.sol";

/// @dev Cut into a test diamond to stand in for a buggy payout path and for a pre-rev026 task.
contract MockEscrowBugFacet {
    /// @dev Pays `amount` out of the pool without the task's state owing any less.
    function bugOverpay(bytes32 taskId, address to, uint256 amount) external {
        AppStorage storage s = LibAppStorage.appStorage();
        uint256 balanceBefore = LibEscrow.balance(s);
        require(s.usdcToken.transfer(to, amount));
        LibEscrow.release(s, taskId, balanceBefore);
    }

    /// @dev Raises a task's reward with no funding and runs a payout-side release over it.
    function bugInflateReward(bytes32 taskId, uint256 extra) external {
        AppStorage storage s = LibAppStorage.appStorage();
        s.tasks[taskId].reward += extra;
        LibEscrow.release(s, taskId, LibEscrow.balance(s));
    }

    /// @dev Makes a task read as created before rev026 and never booked.
    function bugUnbook(bytes32 taskId) external {
        AppStorage storage s = LibAppStorage.appStorage();
        s.totalLiabilities -= s.escrowRecords[taskId].booked;
        delete s.escrowRecords[taskId];
    }

    /// @dev Sets a task's reward directly, as a full reject fee does.
    function bugSetReward(bytes32 taskId, uint256 reward) external {
        LibAppStorage.appStorage().tasks[taskId].reward = reward;
    }

    function bugSetLiabilitiesInitialised(bool value) external {
        LibAppStorage.appStorage().liabilitiesInitialised = value;
    }
}
