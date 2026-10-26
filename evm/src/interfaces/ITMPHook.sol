// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPCore } from "./ITMPCore.sol";

/// @title ITMPHook — ERC-8195 task lifecycle hook interface
/// @notice Implemented by external contracts that wish to observe or gate task
///         state transitions. Registered immutably at task creation via createTask().
///
///         check* hooks: return false OR revert to block the transition. Called AFTER
///         all task state is committed but BEFORE TaskMarket's outbound payout transfers.
///         The hook sees the final committed state and may validate it; a rejection reverts
///         all state changes cleanly. Exception: checkFund runs inside createTask, where
///         USDC has already been moved by the PGTR forwarder before the relayed call
///         arrives — do not assume pre-transfer balances in checkFund implementations.
///         Side effects in the hook are permitted; re-entrant calls into TaskMarket are
///         blocked by nonReentrant.
///
///         on* hooks: called after all state and transfers are committed. Failures are
///         swallowed via try-catch (best-effort). Side effects such as minting reward
///         tokens or emitting external notifications belong here.
///
///         checkEvaluate is wired to evaluate() calls (ITMPEvaluator). Hook contracts
///         MAY implement it as a no-op if they do not care about evaluation events.
interface ITMPHook is IERC165 {
    function checkFund(bytes32 taskId, ITMPCore.TaskContext calldata ctx, bytes calldata hookData)
        external
        returns (bool);
    function checkClaim(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) external returns (bool);
    function checkSelectWorker(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external
        returns (bool);
    function checkSubmit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker, bytes32 deliverableHash)
        external
        returns (bool);
    function checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address evaluator) external returns (bool);
    function checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        external
        returns (bool);
    function onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict) external;
    function onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) external;
    function onCancel(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external;
    function onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external;
}
