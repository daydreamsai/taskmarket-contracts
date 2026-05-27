// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ITMPCore} from "./ITMPCore.sol";

/// @title ITMPRegistry — ERC-8195 task registry view interface
/// @notice Provides composable read-only access to task state, context, and verdict.
///         External contracts (hook implementations, integrations, aggregators) use
///         these views to query task state without relying on indexed events.
interface ITMPRegistry is IERC165 {
    function getTaskState(bytes32 taskId) external view returns (ITMPCore.TaskStatus);
    function getTaskContext(bytes32 taskId) external view returns (ITMPCore.TaskContext memory);
    function getTaskVerdict(bytes32 taskId) external view returns (ITMPCore.Verdict memory);
}
