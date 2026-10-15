// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { LibTerms } from "../libraries/LibTerms.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";

/// @title SettlementFacet -- rev025 settlement terms and the settlement calls that read them
/// @notice Holds the per-task settlement terms surface: normalization of pre-rev025 tasks and the
///         terms views. Task creation, including the createTask overload taking TaskTerms, stays
///         on CoreFacet; the owner-only bounds setter stays on AdminFacet.
contract SettlementFacet {
    // -------------------------------------------------------------------------
    // Terms
    // -------------------------------------------------------------------------

    /// @notice Normalize the settlement terms of pre-rev025 tasks (permissionless). An id that
    ///         is already normalized, terminal or nonexistent is skipped, so a batch may repeat.
    function normalizeTerms(bytes32[] calldata taskIds) external {
        AppStorage storage s = LibAppStorage.appStorage();
        LibTaskMarket._requireNotPaused(s);
        for (uint256 i; i < taskIds.length; ++i) {
            LibTerms.normalize(s, taskIds[i]);
        }
    }

    /// @notice Get a task's settlement terms. For a non-terminal task created before rev025 and
    ///         not yet normalized, returns the record normalization would write.
    function getTaskTerms(bytes32 taskId) external view returns (ITMPCore.TaskTerms memory) {
        return LibTerms.pendingTerms(LibAppStorage.appStorage(), taskId);
    }

    /// @notice Return the effective bounds on requester-chosen settlement terms. Each reads as
    ///         its compiled default until the owner sets it.
    function termsBounds()
        external
        view
        returns (uint32 minWindowSecs, uint32 maxWindowSecs, uint16 maxRejectFeeBps, uint8 maxRevisions)
    {
        (minWindowSecs, maxWindowSecs, maxRejectFeeBps, maxRevisions) = LibTerms.bounds(LibAppStorage.appStorage());
    }
}
