// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";

/// @notice Build a `createTask` task-shape config from loose values.
/// @dev Rev018 groups reward/duration/mode/deadlines/subtype into ITMPCore.TaskConfig, so every
///      call site would otherwise repeat a six-field named literal. Kept as a free function for
///      the same reason as `noEvaluatorConfig`: the call sites live in test contracts with
///      different inheritance.
function taskConfig(
    uint256 reward,
    uint256 duration,
    bytes4 mode,
    uint256 pitchDeadline,
    uint256 bidDeadline,
    bytes4 auctionSubtype
) pure returns (ITMPCore.TaskConfig memory) {
    return ITMPCore.TaskConfig({
        reward: reward,
        duration: duration,
        mode: mode,
        pitchDeadline: pitchDeadline,
        bidDeadline: bidDeadline,
        auctionSubtype: auctionSubtype
    });
}

/// @notice The common case: a task with no pitch window, no bid window, and no auction subtype.
function taskConfig(uint256 reward, uint256 duration, bytes4 mode) pure returns (ITMPCore.TaskConfig memory) {
    return taskConfig(reward, duration, mode, 0, 0, bytes4(0));
}
