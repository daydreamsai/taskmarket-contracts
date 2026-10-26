// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../../src/interfaces/ITMPHook.sol";
import { TMP_BOUNTY } from "../../src/interfaces/ITMPModes.sol";
import { BaseTMPHook } from "../../src/hooks/base/BaseTMPHook.sol";

/// @notice Reusable Foundry checks for hooks that inherit BaseTMPHook.
/// @dev Hook authors implement the three fixture accessors, then inherit this contract
///      in their test suite. The suite proves ERC-165 support, safe default checks, and
///      that every lifecycle callback rejects a fabricated non-Diamond invocation.
abstract contract TMPHookConformance is Test {
    address internal constant NON_DIAMOND_CALLER = address(0xBADC0DE);
    bytes32 internal constant TASK_ID = keccak256("tmp-hook-conformance-task");
    bytes32 internal constant CONFORMANCE_TAG = keccak256("tmp-hook-conformance-tag");

    function hookUnderTest() internal virtual returns (ITMPHook);
    function taskmarketDiamond() internal virtual returns (address);
    function allowedConformanceWorker() internal virtual returns (address);

    function testConformance_supportsHookAndERC165() public {
        ITMPHook hook = hookUnderTest();
        assertTrue(hook.supportsInterface(type(ITMPHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(0xffffffff));
    }

    function testConformance_checksAllowDocumentedHappyPath() public {
        ITMPHook hook = hookUnderTest();
        ITMPCore.TaskContext memory ctx = _context(1);
        ITMPCore.Verdict memory verdict = _verdict();
        address worker = allowedConformanceWorker();

        vm.startPrank(taskmarketDiamond());
        assertTrue(hook.checkFund(TASK_ID, ctx, bytes("")));
        assertTrue(hook.checkClaim(TASK_ID, ctx, worker));
        assertTrue(hook.checkSelectWorker(TASK_ID, ctx, worker));
        assertTrue(hook.checkSubmit(TASK_ID, ctx, worker, bytes32(0)));
        assertTrue(hook.checkEvaluate(TASK_ID, ctx, address(0xE1A1)));
        assertTrue(hook.checkComplete(TASK_ID, ctx, verdict));
        hook.onComplete(TASK_ID, ctx, verdict);
        hook.onForfeit(TASK_ID, ctx, worker);
        hook.onCancel(TASK_ID, ctx);
        hook.onExpire(TASK_ID, ctx);
        vm.stopPrank();
    }

    function testConformance_onlyDiamondMayCallEveryLifecycleCallback() public {
        ITMPHook hook = hookUnderTest();
        ITMPCore.TaskContext memory ctx = _context(1);
        ITMPCore.Verdict memory verdict = _verdict();
        address worker = allowedConformanceWorker();

        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.checkFund, (TASK_ID, ctx, bytes(""))));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.checkClaim, (TASK_ID, ctx, worker)));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.checkSelectWorker, (TASK_ID, ctx, worker)));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.checkSubmit, (TASK_ID, ctx, worker, bytes32(0))));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.checkEvaluate, (TASK_ID, ctx, address(0xE1A1))));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.checkComplete, (TASK_ID, ctx, verdict)));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.onComplete, (TASK_ID, ctx, verdict)));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.onForfeit, (TASK_ID, ctx, worker)));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.onCancel, (TASK_ID, ctx)));
        _expectUnauthorized(address(hook), abi.encodeCall(ITMPHook.onExpire, (TASK_ID, ctx)));
    }

    function testFuzzConformance_nonDiamondCannotFund(
        address caller,
        bytes32 taskId,
        uint96 reward,
        bytes memory hookData
    ) public {
        vm.assume(caller != taskmarketDiamond());
        ITMPCore.TaskContext memory ctx = _context(reward);
        ctx.taskId = taskId;

        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        vm.prank(caller);
        hookUnderTest().checkFund(taskId, ctx, hookData);
    }

    function testFuzzConformance_terminalCallbacksRemainLive(bytes32 taskId, uint40 timestamp) public {
        ITMPHook hook = hookUnderTest();
        ITMPCore.TaskContext memory ctx = _context(1);
        ctx.taskId = taskId;
        vm.warp(timestamp);

        vm.startPrank(taskmarketDiamond());
        hook.onCancel(taskId, ctx);
        hook.onExpire(taskId, ctx);
        vm.stopPrank();
    }

    function _expectUnauthorized(address hook, bytes memory callData) private {
        vm.expectRevert(
            abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, NON_DIAMOND_CALLER)
        );
        vm.prank(NON_DIAMOND_CALLER);
        (bool success,) = hook.call(callData);
        // expectRevert consumes the revert; retain the return value to satisfy Solidity's
        // low-level-call warning without asserting its Foundry-specific value.
        _ignore(success);
    }

    function _ignore(bool) private pure { }

    function _context(uint256 reward) internal pure returns (ITMPCore.TaskContext memory ctx) {
        bytes32[] memory tags = new bytes32[](1);
        tags[0] = CONFORMANCE_TAG;
        return ITMPCore.TaskContext({
            taskId: TASK_ID,
            requester: address(0xBEEF),
            evaluator: address(0),
            paymentToken: address(0xCAFE),
            reward: reward,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            submissionDeadline: 0,
            evaluationWindow: 0,
            appealWindow: 0,
            disputeResolver: address(0),
            currentState: ITMPCore.TaskStatus.Open,
            mode: TMP_BOUNTY,
            tags: tags
        });
    }

    function _verdict() internal pure returns (ITMPCore.Verdict memory) {
        return ITMPCore.Verdict({
            issued: true,
            verdictType: ITMPCore.VerdictType.APPROVE,
            score: 100,
            confidence: 100,
            criteriaFlags: new bytes32[](0),
            evidenceHash: bytes32(0),
            awards: new ITMPCore.Award[](0)
        });
    }
}
