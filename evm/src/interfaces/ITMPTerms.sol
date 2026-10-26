// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";

/// @notice The rev025 createTask taking explicit settlement terms. Declared apart from
///         ITMPDiamond while ITMPDiamond also carried the legacy overload; since rev026 removed
///         that overload the two declare the same function.
interface ITMPTerms {
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms
    ) external returns (bytes32);
}
