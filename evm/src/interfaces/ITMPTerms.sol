// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "./ITMPCore.sol";

/// @notice The rev025 createTask taking explicit settlement terms. Declared apart from
///         ITMPDiamond while ITMPDiamond also carried the legacy overload; since rev026 removed
///         that overload the two declare the same function. Since rev027 the terms are version 2
///         (with acceptWindowSecs).
interface ITMPTerms {
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTerms calldata terms
    ) external returns (bytes32);
}

/// @notice The rev025 createTask taking version 1 terms, which rev027 keeps routed beside the
///         version 2 overload (ITMPTerms) so callers can migrate after the cut. Declared apart so
///         `abi.encodeCall` can name either one unambiguously.
interface ITMPTermsV1 {
    function createTask(
        ITMPCore.TaskConfig calldata config,
        ITMPCore.HookConfig calldata hookConfig,
        ITMPCore.TaskContent calldata content,
        ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig,
        ITMPCore.TaskTermsV1 calldata terms
    ) external returns (bytes32);
}
