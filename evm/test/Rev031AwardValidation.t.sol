// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_BOUNTY, TMP_BENCHMARK } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Rev031: one award and rank validation for evaluator verdicts, dispute rulings and
///      transforming hook results, and the primary worker follows the lowest-ranked paid award.
contract Rev031AwardValidationTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);
    address internal workerA = address(0xC0);
    address internal workerB = address(0xC1);
    address internal workerC = address(0xC2);
    address internal workerD = address(0xC3);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    uint32 internal constant BIT_ACCEPT = uint32(1) << 13;
    uint32 internal constant BIT_REALLOCATE = uint32(1) << 26;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, uint16(500));
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(bytes4 mode, address hook) internal returns (bytes32) {
        address[] memory hooks = new address[](hook == address(0) ? 0 : 1);
        if (hook != address(0)) hooks[0] = hook;
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, mode),
                        ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _work(address w) internal pure returns (bytes32) {
        return keccak256(abi.encode("work", w));
    }

    function _submit(bytes32 taskId, address w) internal {
        _relay(w, 0, abi.encodeCall(market.submitWork, (taskId, _work(w))));
    }

    /// @dev A contest with an evaluator (fee 10%) and a resolver, and submissions from A and B.
    function _evaluatedContest(bytes4 mode) internal returns (bytes32 taskId) {
        taskId = _create(mode, address(0));
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 1000, uint32(2 days), uint32(1 days), resolver)
            )
        );
        _submit(taskId, workerA);
        _submit(taskId, workerB);
    }

    function _evaluateCall(bytes32 taskId, ITMPCore.Award[] memory awards) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ITMPDiamond.evaluate, (taskId, ITMPCore.VerdictType.PARTIAL, uint16(9000), uint16(9000), bytes32(0), awards)
        );
    }

    function _pair(address w0, uint256 a0, uint16 r0, address w1, uint256 a1, uint16 r1)
        internal
        pure
        returns (ITMPCore.Award[] memory awards)
    {
        awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: w0, amount: a0, rank: r0 });
        awards[1] = ITMPCore.Award({ worker: w1, amount: a1, rank: r1 });
    }

    function _contestModes() internal pure returns (bytes4[2] memory) {
        return [TMP_BOUNTY, TMP_BENCHMARK];
    }

    // -------------------------------------------------------------------------
    // Evaluator verdicts and dispute rulings
    // -------------------------------------------------------------------------

    /// Cantina TASK-329: two paid awards may not share a contest rank.
    function test_RevertWhen_Evaluate_DuplicatePaidRank() public {
        for (uint256 m; m < 2; ++m) {
            bytes32 taskId = _evaluatedContest(_contestModes()[m]);
            vm.expectRevert(ITMPCore.InvalidAwardRank.selector);
            _relay(evaluator, 0, _evaluateCall(taskId, _pair(workerA, 40e6, 1, workerB, 40e6, 1)));

            // A zero-amount entry names no place, so it may repeat a rank.
            _relay(evaluator, 0, _evaluateCall(taskId, _pair(workerA, 40e6, 1, workerB, 0, 1)));
            assertTrue(market.getTaskVerdict(taskId).issued);
        }
    }

    /// Cantina TASK-338: one worker may not hold two paid awards.
    function test_RevertWhen_Evaluate_DuplicatePaidWorker() public {
        for (uint256 m; m < 2; ++m) {
            bytes32 taskId = _evaluatedContest(_contestModes()[m]);
            vm.expectRevert(ITMPCore.DuplicateAwardWorker.selector);
            _relay(evaluator, 0, _evaluateCall(taskId, _pair(workerA, 40e6, 1, workerA, 40e6, 2)));

            _relay(evaluator, 0, _evaluateCall(taskId, _pair(workerA, 40e6, 1, workerA, 0, 2)));
            assertTrue(market.getTaskVerdict(taskId).issued);
        }
    }

    /// Cantina TASK-414: the primary worker is the lowest-ranked paid award, not the first entry.
    /// A paid co-winner may appeal too (Cyclops 7666), so only the task's worker is asserted here.
    function test_Evaluate_PrimaryWorkerIsTheLowestRank() public {
        bytes32 taskId = _evaluatedContest(TMP_BOUNTY);
        _relay(evaluator, 0, _evaluateCall(taskId, _pair(workerB, 30e6, 2, workerA, 50e6, 1)));
        assertEq(market.getTask(taskId).worker, workerA, "rank 1 is the primary worker");

        _relay(workerA, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Disputed));

        // The ruling's primary worker follows rank as well.
        _relay(
            resolver,
            0,
            abi.encodeCall(
                market.resolveDispute, (taskId, ITMPCore.VerdictType.PARTIAL, _pair(workerA, 30e6, 2, workerB, 50e6, 1))
            )
        );
        assertEq(market.getTask(taskId).worker, workerB);
    }

    function test_RevertWhen_ResolveDispute_DuplicatePaidRankOrWorker() public {
        bytes32 taskId = _evaluatedContest(TMP_BOUNTY);
        _relay(evaluator, 0, _evaluateCall(taskId, _pair(workerA, 50e6, 1, workerB, 30e6, 2)));
        _relay(workerA, 0, abi.encodeCall(market.appeal, (taskId)));

        vm.expectRevert(ITMPCore.InvalidAwardRank.selector);
        _relay(
            resolver,
            0,
            abi.encodeCall(
                market.resolveDispute, (taskId, ITMPCore.VerdictType.PARTIAL, _pair(workerA, 30e6, 1, workerB, 30e6, 1))
            )
        );
        vm.expectRevert(ITMPCore.DuplicateAwardWorker.selector);
        _relay(
            resolver,
            0,
            abi.encodeCall(
                market.resolveDispute, (taskId, ITMPCore.VerdictType.PARTIAL, _pair(workerB, 30e6, 1, workerB, 30e6, 2))
            )
        );
    }

    /// Cyclops 7623: a ruling that changes only the ranks does not uphold the verdict, so the
    /// evaluator fee goes back to the requester.
    function test_ResolveDispute_RankChangeIsNotUpheld() public {
        bytes32 taskId = _evaluatedContest(TMP_BOUNTY);
        _relay(evaluator, 0, _evaluateCall(taskId, _pair(workerA, 40e6, 1, workerB, 40e6, 2)));
        _relay(workerA, 0, abi.encodeCall(market.appeal, (taskId)));
        uint256 evaluatorBefore = usdc.balanceOf(evaluator);
        _relay(
            resolver,
            0,
            abi.encodeCall(
                market.resolveDispute, (taskId, ITMPCore.VerdictType.PARTIAL, _pair(workerA, 40e6, 2, workerB, 40e6, 1))
            )
        );
        assertEq(usdc.balanceOf(evaluator), evaluatorBefore, "a changed ruling pays no evaluator fee");
        assertEq(market.getTask(taskId).worker, workerB);
    }

    function test_ResolveDispute_SameVerdictIsUpheld() public {
        bytes32 taskId = _evaluatedContest(TMP_BOUNTY);
        ITMPCore.Award[] memory awards = _pair(workerA, 40e6, 1, workerB, 40e6, 2);
        _relay(evaluator, 0, _evaluateCall(taskId, awards));
        _relay(workerA, 0, abi.encodeCall(market.appeal, (taskId)));
        uint256 evaluatorBefore = usdc.balanceOf(evaluator);
        _relay(resolver, 0, abi.encodeCall(market.resolveDispute, (taskId, ITMPCore.VerdictType.PARTIAL, awards)));
        assertEq(usdc.balanceOf(evaluator), evaluatorBefore + REWARD / 10, "an upheld verdict pays the fee");
    }

    // -------------------------------------------------------------------------
    // Transforming hook results
    // -------------------------------------------------------------------------

    function _hookContest(bytes4 mode, MockTaskHookV2 h) internal returns (bytes32 taskId) {
        taskId = _create(mode, address(h));
        _submit(taskId, workerA);
        _submit(taskId, workerB);
        _submit(taskId, workerC);
        _submit(taskId, workerD);
    }

    function _acceptA(bytes32 taskId) internal returns (bytes memory) {
        return abi.encodeCall(market.acceptSubmission, (taskId, workerA, _work(workerA), 0));
    }

    function _acceptAB(bytes32 taskId) internal view returns (bytes memory) {
        address[] memory workers = new address[](2);
        workers[0] = workerA;
        workers[1] = workerB;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        return abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0));
    }

    function _transforming() internal returns (MockTaskHookV2) {
        return new MockTaskHookV2(address(market), BIT_ACCEPT | BIT_REALLOCATE);
    }

    function _invalid() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ITMPHooksV2.HookResultInvalid.selector, uint8(0));
    }

    /// Cyclops 7634, Cantina TASK-69: a hook result is held to the chain's winner cap, not 50.
    function test_RevertWhen_HookResultExceedsTheChainWinnerCap() public {
        vm.prank(owner);
        market.setMaxSubmissionWinners(3);
        MockTaskHookV2 h = _transforming();
        bytes32 taskId = _hookContest(TMP_BOUNTY, h);
        ITMPCore.Award[] memory four = new ITMPCore.Award[](4);
        address[4] memory ws = [workerA, workerB, workerC, workerD];
        for (uint256 i; i < 4; ++i) {
            four[i] = ITMPCore.Award({ worker: ws[i], amount: 10e6, rank: uint16(i + 1) });
        }
        h.setResult(four, 0, false);
        vm.expectRevert(_invalid());
        _relay(requester, 0, _acceptA(taskId));

        // Zero-amount entries are stored with the verdict, so they count toward the cap as well.
        four[3].amount = 0;
        h.setResult(four, 0, false);
        vm.expectRevert(_invalid());
        _relay(requester, 0, _acceptA(taskId));

        ITMPCore.Award[] memory three = new ITMPCore.Award[](3);
        for (uint256 i; i < 3; ++i) {
            three[i] = four[i];
        }
        h.setResult(three, 0, false);
        _relay(requester, 0, _acceptA(taskId));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
        assertEq(market.getTaskVerdict(taskId).awards.length, 3);
    }

    /// Cyclops 7633: a paid contest award in a hook result needs rank >= 1.
    function test_RevertWhen_HookResultPaysRankZero() public {
        for (uint256 m; m < 2; ++m) {
            MockTaskHookV2 h = _transforming();
            bytes32 taskId = _hookContest(_contestModes()[m], h);
            h.setResult(_pair(workerA, 50e6, 1, workerB, 30e6, 0), 0, false);
            vm.expectRevert(_invalid());
            _relay(requester, 0, _acceptA(taskId));
        }
    }

    /// Cantina TASK-236: two paid awards in a hook result may not share a rank.
    function test_RevertWhen_HookResultDuplicatesAPaidRank() public {
        for (uint256 m; m < 2; ++m) {
            MockTaskHookV2 h = _transforming();
            bytes32 taskId = _hookContest(_contestModes()[m], h);
            h.setResult(_pair(workerA, 50e6, 1, workerB, 30e6, 1), 0, false);
            vm.expectRevert(_invalid());
            _relay(requester, 0, _acceptAB(taskId));
        }
    }

    /// Cantina TASK-237: after a hook reallocates, the task's worker and deliverable are the
    /// lowest-ranked paid award's, on single and multi-winner acceptance.
    function test_HookReallocation_SetsWorkerAndDeliverableFromRankOne() public {
        MockTaskHookV2 h = _transforming();
        bytes32 taskId = _hookContest(TMP_BOUNTY, h);
        h.setResult(_pair(workerA, 30e6, 2, workerC, 50e6, 1), 0, false);
        _relay(requester, 0, _acceptA(taskId));
        ITMPCore.Task memory t = market.getTask(taskId);
        assertEq(t.worker, workerC);
        assertEq(t.deliverable, _work(workerC));

        MockTaskHookV2 h2 = _transforming();
        bytes32 multi = _hookContest(TMP_BENCHMARK, h2);
        h2.setResult(_pair(workerD, 30e6, 2, workerB, 50e6, 1), 0, false);
        _relay(requester, 0, _acceptAB(multi));
        t = market.getTask(multi);
        assertEq(t.worker, workerB);
        assertEq(t.deliverable, _work(workerB));
    }

    /// A result that keeps the core's rank-1 worker keeps the deliverable the requester accepted.
    function test_HookReallocation_SameWorkerKeepsTheAcceptedDeliverable() public {
        MockTaskHookV2 h = _transforming();
        bytes32 taskId = _create(TMP_BOUNTY, address(h));
        bytes32 older = keccak256("older");
        _relay(workerA, 0, abi.encodeCall(market.submitWork, (taskId, older)));
        _submit(taskId, workerA);
        _submit(taskId, workerB);
        h.setResult(_pair(workerA, 50e6, 1, workerB, 30e6, 2), 0, false);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, workerA, older, 0)));
        ITMPCore.Task memory t = market.getTask(taskId);
        assertEq(t.worker, workerA);
        assertEq(t.deliverable, older);
    }
}
