// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev The standalone payout gate hook V2: every path of the original gate, plus the re-link after
///      a gating task fails, the deadline extension, and the project operator's calls.
contract PayoutGateHookTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPHooksV2 internal v2;
    ITMPProject internal projects;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    PayoutGateHook internal gate;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);
    address internal stranger = address(0x5757);
    address internal other = address(0xB7);
    address internal runner = address(0xB1);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    bytes32 internal constant WORK = keccak256("work");
    uint32 internal constant ROLE_REQUESTER = 1 << 0;
    uint32 internal constant ROLE_PROJECT = 1 << 1;
    uint32 internal constant ROLE_STRANGER = uint32(1) << 31;
    uint8 internal constant ACT_LINK = 1;
    uint8 internal constant ACT_EXTEND = 2;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        v2 = ITMPHooksV2(address(market));
        projects = ITMPProject(address(market));
        usdc.mint(address(forwarder), 10_000_000e6);
        gate = new PayoutGateHook(address(market));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(address sender, address[] memory hooks, bytes[] memory configs) internal returns (bytes32) {
        bytes memory data = configs.length == 0 ? bytes("") : abi.encode(configs);
        bytes memory ret = _relay(
            sender,
            REWARD,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD, DURATION, TMP_CLAIM),
                    ITMPCore.HookConfig({ contracts: hooks, data: data }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig(),
                    stakeTerms(false, 0)
                )
            )
        );
        return ret.length == 32 ? abi.decode(ret, (bytes32)) : bytes32(0);
    }

    function _plain() internal returns (bytes32) {
        return _create(requester, new address[](0), new bytes[](0));
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _cfg(bytes memory c) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = c;
    }

    function _ids(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function _gated(bytes32 gatingTaskId, uint64 deadline) internal returns (bytes32) {
        return _create(requester, _one(address(gate)), _cfg(abi.encode(gatingTaskId, deadline, new bytes32[](0))));
    }

    function _gating(bytes32 gated) internal returns (bytes32) {
        return _create(requester, _one(address(gate)), _cfg(abi.encode(bytes32(0), uint64(0), _ids(gated))));
    }

    function _claimAndSubmit(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    function _accept(bytes32 taskId) internal {
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }

    function _cancel(bytes32 taskId) internal {
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function _call(address sender, bytes32 taskId, bytes memory data) internal {
        _relay(sender, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(gate), data)));
    }

    function _link(address sender, bytes32 taskId, bytes32 gatingTaskId) internal {
        _call(sender, taskId, abi.encode(ACT_LINK, gatingTaskId));
    }

    function _extend(address sender, bytes32 taskId, uint256 deadline) internal {
        _call(sender, taskId, abi.encode(ACT_EXTEND, bytes32(deadline)));
    }

    function _rejected(bytes memory err) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ITMPHooksV2.HookRejected.selector, uint8(0), uint8(22), err);
    }

    function _rejected(bytes4 err) internal pure returns (bytes memory) {
        return _rejected(abi.encodeWithSelector(err));
    }

    function _assertClosed(bytes32 taskId) internal {
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _accept(taskId);
    }

    function _state(bytes32 taskId) internal view returns (ITMPCore.TaskStatus) {
        return market.getTaskState(taskId);
    }

    // -------------------------------------------------------------------------
    // Manifest and attach
    // -------------------------------------------------------------------------

    function test_ManifestAndInterface() public view {
        assertEq(gate.hookCapabilities(), (uint32(1) << 0) | (uint32(1) << 13) | (uint32(1) << 30));
        assertEq(gate.hookCapabilities(), gate.CAPABILITIES());
        assertEq(gate.minDiamondVersion(), 28);
        assertEq(gate.diamond(), address(market));
        assertEq(gate.hookCallRoles(), ROLE_REQUESTER | ROLE_PROJECT);
        assertTrue(gate.supportsInterface(type(ITMPHookV2).interfaceId));
        assertTrue(gate.supportsInterface(type(IERC165).interfaceId));
        assertFalse(gate.supportsInterface(0xdeadbeef));
        assertEq(gate.MIN_DEADLINE_WINDOW(), 1 hours);
        assertEq(gate.MAX_DEADLINE_WINDOW(), 180 days);
        assertEq(gate.MAX_GATES_PER_TASK(), 16);
    }

    function test_ZeroDiamondRefused() public {
        vm.expectRevert(BaseTMPHookV2.BaseTMPHookV2__ZeroDiamond.selector);
        new PayoutGateHook(address(0));
    }

    function test_CallRolesPinnedAtAttach() public {
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 days));
        ITMPHookV2.Attachment memory a = v2.getTaskHooksV2(taskId)[0];
        assertEq(a.callRoles, ROLE_REQUESTER | ROLE_PROJECT, "requester and project operator");
        assertEq(a.capabilities, gate.CAPABILITIES());
        assertFalse(a.transforming);
    }

    function test_UnknownGateReadsZero() public {
        bytes32 taskId = _plain();
        (bytes32 g, uint64 d, bool paid, bool open) = gate.gateOf(taskId);
        assertEq(g, bytes32(0));
        assertEq(d, 0);
        assertFalse(paid);
        assertFalse(open);
        assertFalse(gate.isOpen(taskId));
        (,, uint64 maxDeadline,,,,) = gate.gateDetailsOf(taskId);
        assertEq(maxDeadline, 0);
    }

    function test_HooksOnlyFromDiamond() public {
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 days));
        ITMPHookV2.TaskContextV2 memory ctx;
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHookV2.BaseTMPHookV2__UnauthorizedCaller.selector, requester));
        gate.onCall(taskId, ctx, requester, ROLE_REQUESTER, abi.encode(ACT_LINK, bytes32(uint256(1))));
        ITMPCore.Verdict memory v;
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHookV2.BaseTMPHookV2__UnauthorizedCaller.selector, requester));
        gate.beforeAccept(taskId, ctx, v, "");
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHookV2.BaseTMPHookV2__UnauthorizedCaller.selector, requester));
        gate.beforeCreate(taskId, ctx, "", "");
    }

    // -------------------------------------------------------------------------
    // The original gate behaviour
    // -------------------------------------------------------------------------

    function test_GateHoldsUntilGatingTaskPaid() public {
        bytes32 review = _plain();
        uint64 deadline = uint64(block.timestamp + 3 days);
        bytes32 taskId = _gated(review, deadline);
        (bytes32 g, uint64 d, bool paid, bool open) = gate.gateOf(taskId);
        assertEq(g, review);
        assertEq(d, deadline);
        assertFalse(paid);
        assertFalse(open);
        _claimAndSubmit(taskId);
        _assertClosed(taskId);
        _claimAndSubmit(review);
        _accept(review);
        (,, paid, open) = gate.gateOf(taskId);
        assertTrue(paid && open, "paying the gating task opens the gate");
        assertTrue(gate.isOpen(taskId));
        _accept(taskId);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_GateOpensAtDeadline() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 2 hours));
        _claimAndSubmit(taskId);
        _assertClosed(taskId);
        vm.warp(block.timestamp + 2 hours);
        _accept(taskId);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_GateWithNoGatingTaskOpensAtDeadline() public {
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 hours));
        _claimAndSubmit(taskId);
        _assertClosed(taskId);
        vm.warp(block.timestamp + 1 hours);
        _accept(taskId);
    }

    function test_GateNeverHoldsExpiryRefund() public {
        bytes32 taskId = _gated(_plain(), uint64(block.timestamp + 30 days));
        vm.warp(block.timestamp + DURATION + 1);
        market.refundExpired(taskId, 0);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Expired));
    }

    function test_GateNeverHoldsCancel() public {
        bytes32 taskId = _gated(_plain(), uint64(block.timestamp + 30 days));
        _cancel(taskId);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Cancelled));
    }

    function test_GatePassesDisputeRuling() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 30 days));
        _relay(
            requester, 0, abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, 2 days, 1 days, resolver))
        );
        _claimAndSubmit(taskId);
        ITMPCore.Award[] memory none = new ITMPCore.Award[](0);
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.REJECT, 0, 1000, bytes32(0), none))
        );
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, awards);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "the ruling is not held");
    }

    function test_DeadlineWindowAtCreation() public {
        bytes4 rej = ITMPHooksV2.HookRejected.selector;
        vm.expectPartialRevert(rej);
        _gated(bytes32(0), uint64(block.timestamp + 59 minutes));
        vm.expectPartialRevert(rej);
        _gated(bytes32(0), uint64(block.timestamp + 180 days + 1));
        _gated(bytes32(0), uint64(block.timestamp + 1 hours));
        bytes32 top = _gated(bytes32(0), uint64(block.timestamp + 180 days));
        (,, uint64 maxDeadline,,,,) = gate.gateDetailsOf(top);
        assertEq(maxDeadline, block.timestamp + 180 days);
    }

    function test_CreateConfigRules() public {
        bytes4 rej = ITMPHooksV2.HookRejected.selector;
        vm.expectPartialRevert(rej);
        _gated(keccak256("unknown"), uint64(block.timestamp + 1 days));
        vm.expectPartialRevert(rej);
        _create(requester, _one(address(gate)), _cfg(hex"01"));
        vm.expectPartialRevert(rej);
        _create(
            requester,
            _one(address(gate)),
            _cfg(abi.encode(bytes32(0), uint256(type(uint64).max) + 1, new bytes32[](0)))
        );
        bytes32 done = _plain();
        _cancel(done);
        vm.expectPartialRevert(rej);
        _gated(done, uint64(block.timestamp + 1 days));
    }

    function test_GateComposesWithAnotherHook() public {
        address[] memory hooks = new address[](2);
        hooks[0] = address(new PayoutGateHook(address(market)));
        hooks[1] = address(gate);
        bytes[] memory configs = new bytes[](2);
        configs[0] = abi.encode(bytes32(0), uint64(block.timestamp + 30 days), new bytes32[](0));
        configs[1] = abi.encode(bytes32(0), uint64(block.timestamp + 1 hours), new bytes32[](0));
        bytes32 taskId = _create(requester, hooks, configs);
        _claimAndSubmit(taskId);
        _assertClosed(taskId);
        vm.warp(block.timestamp + 1 hours);
        _assertClosed(taskId);
    }

    function test_ChainABlocksBBlocksC() public {
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32 a = _plain();
        bytes32 b = _gated(a, deadline);
        bytes32 c = _gated(b, deadline);
        _claimAndSubmit(c);
        _claimAndSubmit(b);
        _assertClosed(c);
        _assertClosed(b);
        _claimAndSubmit(a);
        _accept(a);
        _assertClosed(c);
        _accept(b);
        _accept(c);
        assertEq(uint8(_state(c)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    // -------------------------------------------------------------------------
    // Late link
    // -------------------------------------------------------------------------

    function test_LinkRules() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 days));
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_STRANGER));
        _link(worker, taskId, review);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidGatingTask.selector));
        _link(requester, taskId, taskId);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidGatingTask.selector));
        _link(requester, taskId, bytes32(0));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidGatingTask.selector));
        _link(requester, taskId, keccak256("unknown"));

        vm.expectEmit(address(gate));
        emit PayoutGateHook.PayoutGateLinked(taskId, review);
        vm.expectEmit(address(market));
        emit ITMPHooksV2.TaskHookCalled(
            taskId, address(gate), requester, ROLE_REQUESTER, keccak256(abi.encode(ACT_LINK, review))
        );
        _link(requester, taskId, review);
        (bytes32 linked,,,) = gate.gateOf(taskId);
        assertEq(linked, review);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyLinked.selector));
        _link(requester, taskId, review);
    }

    function test_LinkRefusesOtherRequestersTask() public {
        bytes32 foreign = _create(other, new address[](0), new bytes[](0));
        assertTrue(foreign != bytes32(0));
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 days));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__RequesterMismatch.selector));
        _link(requester, taskId, foreign);
    }

    function test_LinkRefusesSettledGatingTask() public {
        bytes32 done = _plain();
        _cancel(done);
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 days));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidGatingTask.selector));
        _link(requester, taskId, done);
    }

    function test_LinkDirectCallToDiamond() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 days));
        vm.prank(requester);
        v2.callTaskHook(taskId, address(gate), abi.encode(ACT_LINK, review));
        (bytes32 linked,,,) = gate.gateOf(taskId);
        assertEq(linked, review);
    }

    function test_CallDataAndActionRules() public {
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 days));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidConfig.selector));
        _call(requester, taskId, hex"01");
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidConfig.selector));
        _call(requester, taskId, abi.encode(bytes32(uint256(1))));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidConfig.selector));
        _call(requester, taskId, abi.encode(uint8(3), bytes32(uint256(1))));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidConfig.selector));
        _call(requester, taskId, abi.encode(uint8(0), bytes32(uint256(1))));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidConfig.selector));
        _call(requester, taskId, new bytes(96));
    }

    function test_CallOnTaskWithoutGateRefused() public {
        // A gating-mode task carries the hook but holds no gate of its own.
        bytes32 bounty = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        bytes32 review = _gating(bounty);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__UnknownTask.selector));
        _link(requester, review, bounty);
    }

    function test_LinkAfterPayoutRejectedByDiamond() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours);
        _claimAndSubmit(taskId);
        _accept(taskId);
        vm.expectRevert(ITMPHooksV2.TaskAlreadySettled.selector);
        _link(requester, taskId, review);
    }

    function test_LinkRefusedOnceGateOpen() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyOpen.selector));
        _link(requester, taskId, review);
    }

    // -------------------------------------------------------------------------
    // Gating mode
    // -------------------------------------------------------------------------

    function test_GatingModeLinksAutomatically() public {
        bytes32 bounty = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        bytes32 review = _gating(bounty);
        (bytes32 g,,, bool open) = gate.gateOf(bounty);
        assertEq(g, review);
        assertFalse(open);
        _claimAndSubmit(bounty);
        _assertClosed(bounty);
        _claimAndSubmit(review);
        _accept(review);
        _accept(bounty);
        assertEq(uint8(_state(bounty)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_GatingModeRules() public {
        bytes32 bounty = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        bytes4 rej = ITMPHooksV2.HookRejected.selector;
        bytes32 plain = _plain();
        vm.expectPartialRevert(rej);
        _gating(plain);
        vm.expectPartialRevert(rej);
        _create(
            requester, _one(address(gate)), _cfg(abi.encode(bytes32(0), uint64(block.timestamp + 1 days), _ids(bounty)))
        );
        vm.expectPartialRevert(rej);
        _create(requester, _one(address(gate)), _cfg(abi.encode(keccak256("x"), uint64(0), _ids(bounty))));
        _gating(bounty);
        vm.expectPartialRevert(rej);
        _gating(bounty);
        bytes32 doomed = _gated(bytes32(0), uint64(block.timestamp + 1 hours));
        _cancel(doomed);
        vm.expectPartialRevert(rej);
        _gating(doomed);
    }

    function test_GatingModeRejectsOtherRequester() public {
        bytes32 bounty = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _create(other, _one(address(gate)), _cfg(abi.encode(bytes32(0), uint64(0), _ids(bounty))));
    }

    function test_GatingModeRejectsSelfLink() public {
        // The gated task cannot be its own gating task: ids are derived at create, so the listed id
        // is never the id being created. An unknown id is refused as not gated.
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _gating(keccak256("self"));
    }

    function test_GatingTaskGatesSeveralBounties() public {
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32[] memory bounties = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            bounties[i] = _gated(bytes32(0), deadline);
        }
        bytes32 review = _create(requester, _one(address(gate)), _cfg(abi.encode(bytes32(0), uint64(0), bounties)));
        for (uint256 i; i < 3; ++i) {
            (bytes32 g,,,) = gate.gateOf(bounties[i]);
            assertEq(g, review);
            _claimAndSubmit(bounties[i]);
        }
        _assertClosed(bounties[2]);
        _claimAndSubmit(review);
        _accept(review);
        for (uint256 i; i < 3; ++i) {
            _accept(bounties[i]);
        }
    }

    function test_GatingListCappedAtSixteen() public {
        uint64 deadline = uint64(block.timestamp + 30 days);
        bytes32[] memory sixteen = new bytes32[](16);
        for (uint256 i; i < 16; ++i) {
            sixteen[i] = _gated(bytes32(0), deadline);
        }
        bytes32 review = _create(requester, _one(address(gate)), _cfg(abi.encode(bytes32(0), uint64(0), sixteen)));
        (bytes32 g,,,) = gate.gateOf(sixteen[15]);
        assertEq(g, review, "sixteen are allowed");
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _create(requester, _one(address(gate)), _cfg(abi.encode(bytes32(0), uint64(0), new bytes32[](17))));
    }

    // -------------------------------------------------------------------------
    // A gating task that settles without paying: the gate stays closed, one re-link
    // -------------------------------------------------------------------------

    function test_CancelledGatingTaskKeepsGateClosed() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 2 days));
        _claimAndSubmit(taskId);
        _cancel(review);
        (,, bool paid, bool open) = gate.gateOf(taskId);
        assertFalse(paid);
        assertFalse(open, "a cancelled sign-off never releases the payout");
        (,,, bool paidD, bool failed,,) = gate.gateDetailsOf(taskId);
        assertFalse(paidD);
        assertTrue(failed);
        _assertClosed(taskId);
    }

    function test_RelinkAfterCancelledGatingTask() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 2 days));
        _claimAndSubmit(taskId);
        _cancel(review);
        bytes32 review2 = _plain();
        vm.expectEmit(address(gate));
        emit PayoutGateHook.PayoutGateRelinked(taskId, review, review2);
        _link(requester, taskId, review2);
        (bytes32 g,, bool paid, bool open) = gate.gateOf(taskId);
        assertEq(g, review2);
        assertFalse(paid || open);
        (,,,, bool failed, bool relinked,) = gate.gateDetailsOf(taskId);
        assertFalse(failed);
        assertTrue(relinked);
        _assertClosed(taskId);
        _claimAndSubmit(review2);
        _accept(review2);
        _accept(taskId);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_RelinkAfterExpiredGatingTask() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 30 days));
        vm.warp(block.timestamp + DURATION + 1);
        market.refundExpired(review, 0);
        (,,,, bool failed,,) = gate.gateDetailsOf(taskId);
        assertTrue(failed, "expired is a failed gating task");
        // taskId is itself past its expiry but unsettled; the call still reaches the gate.
        bytes32 review2 = _plain();
        _link(requester, taskId, review2);
        (bytes32 g,,,) = gate.gateOf(taskId);
        assertEq(g, review2);
    }

    function test_RelinkOnlyOnce() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 2 days));
        _cancel(review);
        bytes32 review2 = _plain();
        _link(requester, taskId, review2);
        _cancel(review2);
        bytes32 review3 = _plain();
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__RelinkUsed.selector));
        _link(requester, taskId, review3);
        // The deadline is still the backstop.
        _claimAndSubmit(taskId);
        _assertClosed(taskId);
        vm.warp(block.timestamp + 2 days);
        _accept(taskId);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_RelinkRefusedWhileGatingTaskLive() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 30 days));
        _claimAndSubmit(review);
        bytes32 review2 = _plain();
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyLinked.selector));
        _link(requester, taskId, review2);
    }

    function test_RejectedSubmissionIsNotSettlement() public {
        // An evaluator's rejection leaves the gating task live (it can be appealed): no re-link.
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 30 days));
        _relay(
            requester, 0, abi.encodeCall(market.assignEvaluator, (review, evaluator, 0, 0, 2 days, 1 days, resolver))
        );
        _claimAndSubmit(review);
        ITMPCore.Award[] memory none = new ITMPCore.Award[](0);
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (review, ITMPCore.VerdictType.REJECT, 0, 1000, bytes32(0), none))
        );
        (,,, bool failed,,,) = _details(taskId);
        assertFalse(failed);
        bytes32 review2 = _plain();
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyLinked.selector));
        _link(requester, taskId, review2);
    }

    function _details(bytes32 taskId)
        internal
        view
        returns (bytes32, uint64, uint64, bool failed, bool paid, bool relinked, bool open)
    {
        bytes32 g;
        uint64 d;
        uint64 m;
        (g, d, m, paid, failed, relinked, open) = gate.gateDetailsOf(taskId);
        return (g, d, m, failed, paid, relinked, open);
    }

    function test_RelinkRefusedToOtherRequestersTask() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 30 days));
        _cancel(review);
        bytes32 foreign = _create(other, new address[](0), new bytes[](0));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__RequesterMismatch.selector));
        _link(requester, taskId, foreign);
        // A refused re-link does not use up the one re-link.
        _link(requester, taskId, _plain());
    }

    function test_RelinkRefusedToSettledOrSelf() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 30 days));
        _cancel(review);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidGatingTask.selector));
        _link(requester, taskId, review);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidGatingTask.selector));
        _link(requester, taskId, taskId);
        bytes32 done = _plain();
        _cancel(done);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__InvalidGatingTask.selector));
        _link(requester, taskId, done);
    }

    function test_RelinkRefusedOnceGateOpen() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 1 hours));
        _cancel(review);
        vm.warp(block.timestamp + 1 hours);
        bytes32 review2 = _plain();
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyOpen.selector));
        _link(requester, taskId, review2);
    }

    function test_PaidGatingTaskCannotBeReplaced() public {
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, uint64(block.timestamp + 30 days));
        _claimAndSubmit(review);
        _accept(review);
        // Open: any further call is refused as already open.
        bytes32 review2 = _plain();
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyOpen.selector));
        _link(requester, taskId, review2);
    }

    // -------------------------------------------------------------------------
    // Deadline extension
    // -------------------------------------------------------------------------

    function test_ExtendDeadlineUpwardOnly() public {
        uint64 start = uint64(block.timestamp);
        bytes32 taskId = _gated(_plain(), start + 2 days);
        vm.expectEmit(address(gate));
        emit PayoutGateHook.PayoutGateExtended(taskId, start + 2 days, start + 5 days);
        _extend(requester, taskId, start + 5 days);
        (, uint64 d,,) = gate.gateOf(taskId);
        assertEq(d, start + 5 days);
        vm.expectRevert(
            _rejected(
                abi.encodeWithSelector(
                    PayoutGateHook.PayoutGate__ExtensionOutOfWindow.selector,
                    uint256(start + 5 days),
                    uint64(start + 5 days),
                    uint64(start + 180 days)
                )
            )
        );
        _extend(requester, taskId, start + 5 days);
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _extend(requester, taskId, start + 3 days);
    }

    function test_ExtendWindowIsMeasuredFromCreation() public {
        uint64 start = uint64(block.timestamp);
        bytes32 taskId = _gated(_plain(), start + 2 days);
        // Past the deadline the gate is open and cannot be extended.
        vm.warp(start + 40 days);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyOpen.selector));
        _extend(requester, taskId, start + 100 days);

        uint64 created = start + 40 days;
        bytes32 t2 = _gated(_plain(), created + 100 days);
        vm.warp(created + 30 days);
        _extend(requester, t2, created + 180 days);
        (, uint64 d,,) = gate.gateOf(t2);
        assertEq(d, created + 180 days, "the cap is 180 days from creation, not from the call");
        vm.warp(created + 40 days);
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _extend(requester, t2, created + 180 days + 1);
    }

    function test_ExtendKeepsTheGateClosedLonger() public {
        uint64 start = uint64(block.timestamp);
        bytes32 taskId = _gated(_plain(), start + 1 hours);
        _claimAndSubmit(taskId);
        _extend(requester, taskId, start + 3 hours);
        vm.warp(start + 1 hours);
        _assertClosed(taskId);
        vm.warp(start + 3 hours);
        _accept(taskId);
    }

    function test_ExtendNeverReopensAnOpenGate() public {
        uint64 start = uint64(block.timestamp);
        bytes32 taskId = _gated(_plain(), start + 1 hours);
        vm.warp(start + 1 hours);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__AlreadyOpen.selector));
        _extend(requester, taskId, start + 2 days);
    }

    function test_ExtendAfterGatingTaskFailed() public {
        uint64 start = uint64(block.timestamp);
        bytes32 review = _plain();
        bytes32 taskId = _gated(review, start + 2 days);
        _cancel(review);
        _extend(requester, taskId, start + 10 days);
        (, uint64 d,,) = gate.gateOf(taskId);
        assertEq(d, start + 10 days);
    }

    function test_ExtendRefusedForStrangersAndSettledTasks() public {
        uint64 start = uint64(block.timestamp);
        bytes32 taskId = _gated(_plain(), start + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_STRANGER));
        _extend(stranger, taskId, start + 2 days);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_STRANGER));
        _extend(worker, taskId, start + 2 days);
        vm.warp(start + 1 hours);
        _claimAndSubmit(taskId);
        _accept(taskId);
        vm.expectRevert(ITMPHooksV2.TaskAlreadySettled.selector);
        _extend(requester, taskId, start + 2 days);
    }

    function test_ExtendOnTaskWithoutGateRefused() public {
        bytes32 bounty = _gated(bytes32(0), uint64(block.timestamp + 30 days));
        bytes32 review = _gating(bounty);
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__UnknownTask.selector));
        _extend(requester, review, block.timestamp + 40 days);
    }

    function test_ExtendedTaskExpiryLeavesGateAlone() public {
        // The gate's clock and the task's expiry are independent: extending the task's expiry
        // changes nothing in the gate, and a deadline past the task's expiry still lets the expiry
        // refund through (it is never held).
        uint64 start = uint64(block.timestamp);
        bytes32 taskId = _gated(_plain(), start + 3 days);
        _relay(requester, 0, abi.encodeCall(market.updateTask, (taskId, 0, start + 20 days, 0, 0)));
        assertEq(market.getTask(taskId).expiryTime, start + 20 days);
        (, uint64 d,, bool open) = gate.gateOf(taskId);
        assertEq(d, start + 3 days, "the deadline is unchanged");
        assertFalse(open);
        _extend(requester, taskId, start + 25 days);
        (, d,,) = gate.gateOf(taskId);
        assertEq(d, start + 25 days, "the deadline may pass the task's expiry");
        vm.warp(start + 21 days);
        market.refundExpired(taskId, 0);
        assertEq(uint8(_state(taskId)), uint8(ITMPCore.TaskStatus.Expired), "expiry refund is not held");
    }

    // -------------------------------------------------------------------------
    // Project operators (the runner under a grant holds ROLE_PROJECT, not ROLE_REQUESTER)
    // -------------------------------------------------------------------------

    uint256 internal projectId;
    uint256 internal otherProjectId;

    function _openProjects() internal {
        initMockPool(address(market), owner);
        uint256 budget = 500e6;
        uint64 endsAt = uint64(block.timestamp) + 60 days;
        projectId = abi.decode(
            _relay(requester, budget, abi.encodeCall(projects.createProject, (address(usdc), budget, endsAt, 30 days))),
            (uint256)
        );
        otherProjectId = abi.decode(
            _relay(requester, budget, abi.encodeCall(projects.createProject, (address(usdc), budget, endsAt, 30 days))),
            (uint256)
        );
        ITMPProject.GrantTerms memory terms = ITMPProject.GrantTerms({
            cap: 0,
            requesterOfRecord: ITMPProject.RequesterOfRecord.Owner,
            ownerOverride: true,
            revokeRemovesControl: true
        });
        _relay(requester, 0, abi.encodeCall(projects.grantOperator, (projectId, runner, terms)));
        _relay(runner, 0, abi.encodeCall(projects.acceptGrant, (projectId, keccak256(abi.encode(terms)))));
    }

    function _projectTask(address sender, uint256 pid, bytes memory config) internal returns (bytes32 taskId) {
        bytes[] memory configs = config.length == 0 ? new bytes[](0) : _cfg(config);
        address[] memory hooks = config.length == 0 ? new address[](0) : _one(address(gate));
        bytes memory data = configs.length == 0 ? bytes("") : abi.encode(configs);
        bytes memory ret = _relay(
            sender,
            0,
            abi.encodeCall(
                projects.createProjectTask,
                (
                    pid,
                    taskConfig(20e6, DURATION, TMP_CLAIM),
                    ITMPCore.HookConfig({ contracts: hooks, data: data }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig(),
                    _v2Terms(),
                    address(0)
                )
            )
        );
        return abi.decode(ret, (bytes32));
    }

    function _v2Terms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 2;
    }

    function test_RunnerHoldsProjectRoleOnly() public {
        _openProjects();
        bytes32 gated =
            _projectTask(runner, projectId, abi.encode(bytes32(0), uint64(block.timestamp + 5 days), new bytes32[](0)));
        assertEq(market.getTask(gated).requester, requester, "the owner is the requester of record");
        assertEq(v2.taskCallerRoles(gated, runner), ROLE_PROJECT, "the runner is not the requester");
        assertEq(v2.taskCallerRoles(gated, requester), ROLE_REQUESTER | ROLE_PROJECT);
    }

    function test_RunnerLinksGatingTaskInSameProject() public {
        _openProjects();
        bytes32 gated =
            _projectTask(runner, projectId, abi.encode(bytes32(0), uint64(block.timestamp + 5 days), new bytes32[](0)));
        bytes32 review = _projectTask(runner, projectId, "");
        vm.expectEmit(address(market));
        emit ITMPHooksV2.TaskHookCalled(
            gated, address(gate), runner, ROLE_PROJECT, keccak256(abi.encode(ACT_LINK, review))
        );
        _link(runner, gated, review);
        (bytes32 g,,,) = gate.gateOf(gated);
        assertEq(g, review);
    }

    function test_RunnerLinksGatingTaskWithSameRequesterOfRecord() public {
        _openProjects();
        bytes32 gated =
            _projectTask(runner, projectId, abi.encode(bytes32(0), uint64(block.timestamp + 5 days), new bytes32[](0)));
        // A task outside any project, made by the project's owner: same requester of record.
        bytes32 review = _plain();
        _link(runner, gated, review);
        (bytes32 g,,,) = gate.gateOf(gated);
        assertEq(g, review);
    }

    function test_RunnerCannotLinkAStrangersTask() public {
        _openProjects();
        bytes32 gated =
            _projectTask(runner, projectId, abi.encode(bytes32(0), uint64(block.timestamp + 5 days), new bytes32[](0)));
        bytes32 foreign = _create(other, new address[](0), new bytes[](0));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__RequesterMismatch.selector));
        _link(runner, gated, foreign);
        // Same owner, other project: still the owner's requester of record, so allowed; a task of
        // another owner in another project is refused.
        address owner2 = address(0xB9);
        usdc.mint(address(forwarder), 1000e6);
        uint256 p2 = abi.decode(
            _relay(
                owner2,
                100e6,
                abi.encodeCall(
                    projects.createProject, (address(usdc), 100e6, uint64(block.timestamp) + 60 days, 30 days)
                )
            ),
            (uint256)
        );
        bytes32 foreignProject = _projectTask(owner2, p2, "");
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__RequesterMismatch.selector));
        _link(runner, gated, foreignProject);
    }

    function test_RequesterCannotUseTheProjectRuleForOtherProjects() public {
        // A caller with only ROLE_REQUESTER (a plain task) gets no project rule: the gating task
        // must have its own requester.
        _openProjects();
        bytes32 taskId = _gated(bytes32(0), uint64(block.timestamp + 5 days));
        bytes32 foreign = _create(other, new address[](0), new bytes[](0));
        vm.expectRevert(_rejected(PayoutGateHook.PayoutGate__RequesterMismatch.selector));
        _link(requester, taskId, foreign);
    }

    function test_RunnerRelinksAndExtends() public {
        _openProjects();
        uint64 start = uint64(block.timestamp);
        bytes32 review = _projectTask(runner, projectId, "");
        bytes32 gated = _projectTask(runner, projectId, abi.encode(review, start + 5 days, new bytes32[](0)));
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (review, 0)));
        bytes32 review2 = _projectTask(runner, projectId, "");
        _link(runner, gated, review2);
        (bytes32 g,,,) = gate.gateOf(gated);
        assertEq(g, review2);
        _extend(runner, gated, start + 9 days);
        (, uint64 d,,) = gate.gateOf(gated);
        assertEq(d, start + 9 days);
    }

    function test_RevokedOrUngrantedOperatorRefused() public {
        _openProjects();
        bytes32 gated =
            _projectTask(runner, projectId, abi.encode(bytes32(0), uint64(block.timestamp + 5 days), new bytes32[](0)));
        address nobody = address(0xBAD);
        bytes32 review = _plain();
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_STRANGER));
        _link(nobody, gated, review);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_STRANGER));
        _extend(nobody, gated, block.timestamp + 6 days);
    }

    function test_OperatorOfAnotherProjectRefused() public {
        _openProjects();
        // The runner holds a grant on `projectId` only; a task of the other project gives it no role.
        bytes32 foreignGate = _projectTask(
            requester, otherProjectId, abi.encode(bytes32(0), uint64(block.timestamp + 5 days), new bytes32[](0))
        );
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_STRANGER));
        _extend(runner, foreignGate, block.timestamp + 6 days);
    }

    function test_ProjectGateOpensOnPaidGatingTask() public {
        _openProjects();
        bytes32 gated =
            _projectTask(runner, projectId, abi.encode(bytes32(0), uint64(block.timestamp + 5 days), new bytes32[](0)));
        bytes32 review = _projectTask(runner, projectId, "");
        _link(runner, gated, review);
        _claimAndSubmit(gated);
        _claimAndSubmit(review);
        _assertProjectClosed(gated);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (review, worker, WORK, 0)));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (gated, worker, WORK, 0)));
        assertEq(uint8(_state(gated)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function _assertProjectClosed(bytes32 taskId) internal {
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }
}
