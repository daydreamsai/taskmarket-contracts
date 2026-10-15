// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";

/// @notice Rev025 createTask overload taking explicit settlement terms. Declared apart from
///         ITMPDiamond because Solidity cannot take `.selector` or `abi.encodeCall` of an
///         overloaded function, and ITMPDiamond's createTask is the legacy overload.
interface ITMPTerms {
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms
    ) external returns (bytes32);
}
