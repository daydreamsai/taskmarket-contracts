// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AppStorage } from "./LibAppStorage.sol";

/// @title LibTaskLimits -- rev025 per-chain limits on tags and hooks per task
/// @notice Each limit is owner-settable per chain. A stored zero (every diamond before the owner
///         sets it) reads as the default, so the limits are live as soon as the facets are cut.
library LibTaskLimits {
    uint16 internal constant DEFAULT_MAX_TAGS = 10;
    uint8 internal constant DEFAULT_MAX_HOOKS = 8;
    /// @dev Upper bounds the owner may set: tags are copied into every hook context and each
    ///      hook is owed a forced gas stipend, so both stay bounded against a block gas cap.
    uint16 internal constant MAX_MAX_TAGS = 64;
    uint8 internal constant MAX_MAX_HOOKS = 16;

    function maxTags(AppStorage storage s) internal view returns (uint256) {
        uint16 v = s.taskLimits.maxTags;
        return v == 0 ? DEFAULT_MAX_TAGS : v;
    }

    function maxHooks(AppStorage storage s) internal view returns (uint256) {
        uint8 v = s.taskLimits.maxHooks;
        return v == 0 ? DEFAULT_MAX_HOOKS : v;
    }
}
