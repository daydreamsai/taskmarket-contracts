// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";

/// @notice The zero evaluator config -- "this task has no evaluator".
/// @dev `createTask` takes evaluator terms directly (Rev018), so the great majority of call
///      sites, which are not exercising evaluation at all, need a way to say "none" without
///      spelling out six zero fields each time. Kept as a free function rather than a method on
///      a base test contract because the call sites are spread across test contracts with
///      different inheritance.
function noEvaluatorConfig() pure returns (ITMPCore.TaskEvaluatorConfig memory) {
    return ITMPCore.TaskEvaluatorConfig({
        evaluator: address(0),
        evaluatorStake: 0,
        evaluatorFeeBps: 0,
        evaluationWindow: 0,
        appealWindow: 0,
        disputeResolver: address(0)
    });
}

/// @notice Protocol default settlement terms with the given stake requirement -- what the rev018
///         createTask overload recorded before rev026 removed it.
function stakeTerms(bool stakeRequired, uint16 stakeBps) pure returns (ITMPCore.TaskTerms memory t) {
    t.version = 1;
    t.stakeRequired = stakeRequired;
    t.stakeBps = stakeBps;
}
