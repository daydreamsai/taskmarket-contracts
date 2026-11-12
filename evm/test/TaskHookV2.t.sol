// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { ITMPHookDispatch } from "../src/interfaces/ITMPHookDispatch.sol";
import { TMP_CLAIM, TMP_BOUNTY, TMP_PITCH, TMP_AUCTION, TMP_AUCTION_DUTCH } from "../src/interfaces/ITMPModes.sol";
import { MockCallHookV2 } from "./mocks/MockCallHookV2.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { LibRevision } from "../src/libraries/LibRevision.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev028 Task Hook V2: attach, veto, observers, settlement results, the settlement record,
///      the dispute context. The payout gate is covered in PayoutGateHook.t.sol.
contract TaskHookV2Test is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPHooksV2 internal v2;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC1);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant FEE_BPS = 500;
    bytes32 internal constant WORK = keccak256("work");

    uint32 internal constant BIT_CREATE = uint32(1) << 0;
    uint32 internal constant BIT_CLAIM = uint32(1) << 3;
    uint32 internal constant BIT_SUBMIT = uint32(1) << 9;
    uint32 internal constant BIT_ACCEPT = uint32(1) << 13;
    uint32 internal constant BIT_CANCEL = uint32(1) << 14;
    uint32 internal constant BIT_AFTER_COMPLETE = uint32(1) << 21;
    uint32 internal constant BIT_AFTER_CANCEL = uint32(1) << 22;
    uint32 internal constant BIT_AFTER_EXPIRE = uint32(1) << 23;
    uint32 internal constant BIT_OBSERVER = uint32(1) << 25;
    uint32 internal constant BIT_REALLOCATE = uint32(1) << 26;
    uint32 internal constant BIT_HOOK_FEE = uint32(1) << 27;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, uint16(FEE_BPS));
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        v2 = ITMPHooksV2(address(market));
        usdc.mint(address(forwarder), 10_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _createWith(bytes4 mode, address[] memory hooks, bytes[] memory configs) internal returns (bytes32) {
        return _createAs(requester, mode, hooks, configs);
    }

    function _createAs(address sender, bytes4 mode, address[] memory hooks, bytes[] memory configs)
        internal
        returns (bytes32)
    {
        bytes memory data = configs.length == 0 ? bytes("") : abi.encode(configs);
        ITMPCore.TaskConfig memory cfg = mode == TMP_PITCH
            ? taskConfig(REWARD, DURATION, mode, 1 days, 0, bytes4(0))
            : mode == TMP_AUCTION
                ? taskConfig(REWARD, DURATION, mode, 0, 1 days, TMP_AUCTION_DUTCH)
                : taskConfig(REWARD, DURATION, mode);
        // An expected revert returns no data here, so decode only a real return.
        bytes memory ret = _relay(
            sender,
            REWARD,
            abi.encodeCall(
                market.createTask,
                (
                    cfg,
                    ITMPCore.HookConfig({ contracts: hooks, data: data }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig(),
                    stakeTerms(false, 0)
                )
            )
        );
        return ret.length == 32 ? abi.decode(ret, (bytes32)) : bytes32(0);
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _cfg(bytes memory c) internal pure returns (bytes[] memory a) {
        a = new bytes[](1);
        a[0] = c;
    }

    function _createClaim(address hook) internal returns (bytes32) {
        return _createWith(TMP_CLAIM, _one(hook), new bytes[](0));
    }

    function _claimAndSubmit(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    function _accept(bytes32 taskId) internal {
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }

    function _net(uint256 amt) internal pure returns (uint256) {
        return amt - (amt * FEE_BPS) / 10000;
    }

    function _mock(uint32 caps) internal returns (MockTaskHookV2) {
        return new MockTaskHookV2(address(market), caps);
    }

    /// @dev A Claim task with an evaluator and a dispute resolver, appealed: status Disputed.
    function _disputedTask(address hook) internal returns (bytes32 taskId) {
        taskId = _createClaim(hook);
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
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Disputed), "disputed");
    }

    function _disputedTaskNoHook() internal returns (bytes32 taskId) {
        taskId = _createWith(TMP_CLAIM, new address[](0), new bytes[](0));
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
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Disputed), "disputed");
    }

    function _resolve(bytes32 taskId) internal {
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, awards);
    }

    // -------------------------------------------------------------------------
    // Version and attach
    // -------------------------------------------------------------------------

    function test_NewTaskIsV2WithAttachment() public {
        MockTaskHookV2 h = _mock(BIT_CREATE | BIT_OBSERVER);
        bytes32 taskId = _createWith(TMP_CLAIM, _one(address(h)), _cfg(hex"beef"));
        assertEq(v2.getTaskHookVersion(taskId), 2, "v2");
        ITMPHookV2.Attachment[] memory list = v2.getTaskHooksV2(taskId);
        assertEq(list.length, 1);
        assertEq(list[0].hook, address(h));
        assertEq(list[0].capabilities, BIT_CREATE | BIT_OBSERVER);
        assertEq(list[0].configHash, keccak256(hex"beef"));
        assertEq(list[0].codehash, address(h).codehash);
        assertEq(h.createCalls(), 1, "beforeCreate ran");
        assertEq(h.lastConfig(), hex"beef", "config passed");
        assertEq(h.lastActor(), requester, "actor resolved through the forwarder");
        assertEq(h.lastAfterAction(), 0, "create observed");
        assertEq(market.getTaskHooks(taskId)[0], address(h), "getTaskHooks reads V2 attachments");
    }

    function test_TaskWithoutHooksIsV2() public {
        bytes32 taskId = _createWith(TMP_CLAIM, new address[](0), new bytes[](0));
        assertEq(v2.getTaskHookVersion(taskId), 2);
    }

    function test_V1HookRetired() public {
        MockTaskHook v1 = new MockTaskHook();
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookV1Retired.selector, uint8(0)));
        _createClaim(address(v1));
    }

    function test_RejectsNoCapabilitiesAndVersionTooHigh() public {
        MockTaskHookV2 none = _mock(uint32(1) << 31);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookIncompatible.selector, uint8(0), uint8(4)));
        _createClaim(address(none));

        MockTaskHookV2 future = _mock(BIT_CREATE);
        future.setMinVersion(uint16(LibRevision.CURRENT_REVISION + 1));
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookIncompatible.selector, uint8(0), uint8(3)));
        _createClaim(address(future));
    }

    function test_ConfigCountMismatch() public {
        MockTaskHookV2 h = _mock(BIT_CREATE);
        bytes[] memory two = new bytes[](2);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookIncompatible.selector, uint8(0), uint8(5)));
        _createWith(TMP_CLAIM, _one(address(h)), two);
    }

    function test_SecondTransformingHookReverts() public {
        address[] memory hooks = new address[](2);
        hooks[0] = address(_mock(BIT_ACCEPT | BIT_REALLOCATE));
        hooks[1] = address(_mock(BIT_ACCEPT | BIT_HOOK_FEE));
        vm.expectRevert(ITMPHooksV2.MultipleTransformingHooks.selector);
        _createWith(TMP_CLAIM, hooks, new bytes[](0));
    }

    function test_NineHooksRevert() public {
        address[] memory hooks = new address[](9);
        for (uint256 i; i < 9; ++i) {
            hooks[i] = address(_mock(BIT_OBSERVER));
        }
        vm.expectRevert(ITMPCore.TooManyHooks.selector);
        _createWith(TMP_CLAIM, hooks, new bytes[](0));
    }

    function test_DefaultHooksCappedAtTwoAndAttachedFirst() public {
        address[] memory defaults = new address[](3);
        for (uint256 i; i < 3; ++i) {
            defaults[i] = address(_mock(BIT_OBSERVER));
        }
        vm.prank(owner);
        vm.expectRevert(ITMPHooksV2.TooManyDefaultHooks.selector);
        v2.setDefaultHooksV2(defaults);

        address[] memory two = new address[](2);
        two[0] = defaults[0];
        two[1] = defaults[1];
        vm.prank(owner);
        v2.setDefaultHooksV2(two);
        MockTaskHookV2 mine = _mock(BIT_OBSERVER);
        bytes32 taskId = _createClaim(address(mine));
        ITMPHookV2.Attachment[] memory list = v2.getTaskHooksV2(taskId);
        assertEq(list.length, 3);
        assertEq(list[0].hook, defaults[0]);
        assertEq(list[1].hook, defaults[1]);
        assertEq(list[2].hook, address(mine));
    }

    function test_DispatchSelectorsRejectOutsideCallers() public {
        vm.expectRevert(ITMPHookDispatch.NotSelf.selector);
        ITMPHookDispatch(address(market)).hookBefore(bytes32(0), 3, address(0), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Veto and observers
    // -------------------------------------------------------------------------

    function test_BeforeClaimVetoes() public {
        MockTaskHookV2 h = _mock(BIT_CLAIM);
        bytes32 taskId = _createClaim(address(h));
        h.setVeto(3, true);
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        h.setVeto(3, false);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(uint8(h.lastPriorStatus()), uint8(ITMPCore.TaskStatus.Open), "prior status");
    }

    function test_BeforeCancelVetoes() public {
        MockTaskHookV2 h = _mock(BIT_CANCEL);
        bytes32 taskId = _createClaim(address(h));
        h.setVeto(14, true);
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_ObserverSequenceAndSwallowedFailure() public {
        MockTaskHookV2 h = _mock(BIT_OBSERVER);
        bytes32 taskId = _createClaim(address(h));
        assertEq(v2.hookCallSeq(taskId, 0), 1, "create observed");
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(h.lastSeq(), 1);
        assertEq(h.lastAfterAction(), 3, "claim observed");
        h.setRevertAfter(true);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        assertEq(v2.hookCallSeq(taskId, 0), 3, "a failed call still takes a sequence number");
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Claimed));
    }

    function test_CodeChangeBlocksVetoableAction() public {
        MockTaskHookV2 h = _mock(BIT_CLAIM);
        bytes32 taskId = _createClaim(address(h));
        vm.etch(address(h), address(new PayoutGateHook(address(market))).code);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCodeChanged.selector, uint8(0)));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    function test_ActionDataReachesHook() public {
        MockTaskHookV2 h = _mock(BIT_CLAIM);
        bytes32 taskId = _createClaim(address(h));
        bytes memory inner = abi.encodeCall(market.claimTask, (taskId, 0));
        _relay(worker, 0, abi.encodeCall(v2.withActionData, (hex"c0ffee", inner)));
        assertEq(h.lastActionData(), hex"c0ffee");
        assertEq(market.getTask(taskId).worker, worker, "claimed by the relayed worker");
    }

    function test_ActionDataTooLong() public {
        bytes memory big = new bytes(2049);
        vm.expectRevert(ITMPHooksV2.ActionDataTooLong.selector);
        v2.withActionData(big, hex"");
    }

    function test_NonVetoableExpiryWithHostileHook() public {
        MockTaskHookV2 h = _mock(BIT_CLAIM | BIT_AFTER_EXPIRE);
        bytes32 taskId = _createClaim(address(h));
        h.setRevertAfter(true);
        vm.warp(block.timestamp + DURATION + 1);
        market.refundExpired{ gas: 10_000_000 }(taskId, 0);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(usdc.balanceOf(requester), REWARD, "refunded");
        ITMPHookV2.SettlementAmounts memory r = v2.getTaskSettlement(taskId);
        assertTrue(r.recorded);
        assertEq(r.requesterRefund, REWARD);
    }

    // -------------------------------------------------------------------------
    // Settlement record and amounts
    // -------------------------------------------------------------------------

    function test_SettlementRecordOnAccept() public {
        MockTaskHookV2 h = _mock(BIT_AFTER_COMPLETE);
        bytes32 taskId = _createClaim(address(h));
        _claimAndSubmit(taskId);
        _accept(taskId);
        ITMPHookV2.SettlementAmounts memory r = v2.getTaskSettlement(taskId);
        assertTrue(r.recorded);
        assertEq(r.workerPaid, _net(REWARD));
        assertEq(r.protocolFee, REWARD - _net(REWARD));
        assertEq(r.requesterRefund, 0);
        assertEq(r.awardCount, 1);
        assertEq(r.terminalStatus, uint8(ITMPCore.TaskStatus.Accepted));
        ITMPHookV2.SettlementAmounts memory seen = h.lastAmounts();
        assertEq(seen.workerPaid, r.workerPaid, "callback amounts equal the record");
        assertEq(h.lastTerminalKind(), 1);
    }

    function test_SettlementRecordOnCancel() public {
        MockTaskHookV2 h = _mock(BIT_AFTER_CANCEL);
        bytes32 taskId = _createClaim(address(h));
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        ITMPHookV2.SettlementAmounts memory r = v2.getTaskSettlement(taskId);
        assertTrue(r.recorded);
        assertEq(r.requesterRefund, REWARD);
        assertEq(r.terminalStatus, uint8(ITMPCore.TaskStatus.Cancelled));
        assertEq(h.lastTerminalKind(), 2);
    }

    /// @dev A task from before the cut: dispatch version 0 and a V1 hook list in storage (no code path
    ///      can create one now, so makeLegacyV1Task writes it). Rev030: it is a task with no hooks.
    function _legacyV1Task(MockTaskHook v1) internal returns (bytes32 taskId) {
        taskId = _createWith(TMP_CLAIM, new address[](0), new bytes[](0));
        address[] memory legacy = new address[](1);
        legacy[0] = address(v1);
        makeLegacyV1Task(address(market), taskId, legacy);
        assertEq(v2.getTaskHookVersion(taskId), 0, "created before the cut");
    }

    function test_SettlementRecordForPreCutV1Task() public {
        MockTaskHook v1 = new MockTaskHook();
        bytes32 taskId = _legacyV1Task(v1);
        _claimAndSubmit(taskId);
        _accept(taskId);
        ITMPHookV2.SettlementAmounts memory r = v2.getTaskSettlement(taskId);
        assertTrue(r.recorded, "tasks from before the cut are recorded");
        assertEq(r.workerPaid, _net(REWARD));
        assertEq(v1.checkCompleteCalls(), 0, "the V1 hook is not called");
        assertEq(v1.onCompleteCalls(), 0, "the V1 hook is not called");
    }

    // -------------------------------------------------------------------------
    // Settlement results
    // -------------------------------------------------------------------------

    function test_TransformingHookReducesAwardAndTakesFee() public {
        vm.prank(owner);
        v2.setMaxHookFeeBps(100);
        MockTaskHookV2 h = _mock(BIT_ACCEPT | BIT_REALLOCATE | BIT_HOOK_FEE);
        bytes32 taskId = _createClaim(address(h));
        _claimAndSubmit(taskId);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: 60e6, rank: 1 });
        h.setResult(awards, 100, false);
        _accept(taskId);

        uint256 fee = (60e6 * FEE_BPS) / 10000;
        uint256 hookFee = (60e6 * 100) / 10000;
        assertEq(usdc.balanceOf(worker), 60e6 - fee - hookFee, "worker net of both fees");
        assertEq(usdc.balanceOf(address(h)), hookFee, "hook fee to the hook");
        assertEq(usdc.balanceOf(requester), 40e6, "shortfall refunded");
        assertEq(usdc.balanceOf(address(market)), 0, "nothing left in escrow");
        ITMPHookV2.SettlementAmounts memory r = v2.getTaskSettlement(taskId);
        assertEq(r.hookFee, hookFee);
        assertEq(r.requesterRefund, 40e6);
    }

    function test_ResultToIneligibleWorkerReverts() public {
        MockTaskHookV2 h = _mock(BIT_ACCEPT | BIT_REALLOCATE);
        bytes32 taskId = _createClaim(address(h));
        _claimAndSubmit(taskId);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker2, amount: 10e6, rank: 1 });
        h.setResult(awards, 0, false);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookResultInvalid.selector, uint8(0)));
        _accept(taskId);
    }

    function test_ResultOverBudgetOrFeeOverCapReverts() public {
        MockTaskHookV2 h = _mock(BIT_ACCEPT | BIT_REALLOCATE | BIT_HOOK_FEE);
        bytes32 taskId = _createClaim(address(h));
        _claimAndSubmit(taskId);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD + 1, rank: 1 });
        h.setResult(awards, 0, false);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookResultInvalid.selector, uint8(0)));
        _accept(taskId);

        h.setResult(new ITMPCore.Award[](0), 50, false); // maxHookFeeBps is 0
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookResultInvalid.selector, uint8(0)));
        _accept(taskId);

        h.setResult(new ITMPCore.Award[](0), 0, true); // awardCount does not match
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookResultInvalid.selector, uint8(0)));
        _accept(taskId);
    }

    // -------------------------------------------------------------------------
    // Dispute context
    // -------------------------------------------------------------------------

    function test_DisputeShowsDisputedToV2AndIgnoresVeto() public {
        MockTaskHookV2 h = _mock(BIT_ACCEPT);
        MockTaskHookV2 vetoer = _mock(BIT_ACCEPT);
        vetoer.setVeto(13, true);
        address[] memory hooks = new address[](2);
        hooks[0] = address(h);
        hooks[1] = address(vetoer);
        bytes32 taskId = _createWith(TMP_CLAIM, hooks, new bytes[](0));
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
        _resolve(taskId);
        assertEq(uint8(h.lastAcceptState()), uint8(ITMPCore.TaskStatus.Disputed), "beforeAccept saw Disputed");
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "ruling settled");
        assertEq(usdc.balanceOf(worker), _net(REWARD));
    }

    function test_DisputeOnAPreCutTaskResolvesWithoutItsV1Hook() public {
        MockTaskHook v1 = new MockTaskHook();
        v1.setRevertOnCheckComplete(true);
        bytes32 taskId = _disputedTaskNoHook();
        address[] memory legacy = new address[](1);
        legacy[0] = address(v1);
        makeLegacyV1Task(address(market), taskId, legacy);
        _resolve(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted), "ruling settled");
        assertEq(v1.checkCompleteCalls(), 0, "no V1 checkComplete");
        assertEq(v1.onCompleteCalls(), 0, "no V1 onComplete");
        assertTrue(v2.getTaskSettlement(taskId).recorded, "recorded");
    }

    // -------------------------------------------------------------------------
    // Hook rejection helper
    // -------------------------------------------------------------------------

    function _gateRejected(bytes4 err) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(ITMPHooksV2.HookRejected.selector, uint8(0), uint8(22), abi.encodeWithSelector(err));
    }

    // -------------------------------------------------------------------------
    // Hook calls and caller roles
    // -------------------------------------------------------------------------

    uint32 internal constant ROLE_REQUESTER = 1 << 0;
    uint32 internal constant ROLE_PROJECT = 1 << 1;
    uint32 internal constant ROLE_WORKER = 1 << 2;
    uint32 internal constant ROLE_SUBMITTER = 1 << 3;
    uint32 internal constant ROLE_EVALUATOR = 1 << 4;
    uint32 internal constant ROLE_STRANGER = uint32(1) << 31;
    uint32 internal constant ROLE_ANY = 0x8000001F;
    address internal stranger = address(0x5757);

    function _callHook(uint32 accepted, bytes4 mode) internal returns (MockCallHookV2 h, bytes32 taskId) {
        h = new MockCallHookV2(address(market), accepted);
        taskId = _createWith(mode, _one(address(h)), new bytes[](0));
    }

    /// @dev Calls `h` on `taskId` as `who` and returns the roles the hook received.
    function _rolesSeen(MockCallHookV2 h, bytes32 taskId, address who) internal returns (uint32) {
        _relay(who, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"01")));
        assertEq(h.lastCaller(), who, "caller");
        assertEq(h.lastRoles(), v2.taskCallerRoles(taskId, who), "view matches the call");
        return h.lastRoles();
    }

    function test_RolesClaim() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_CLAIM);
        assertEq(v2.getTaskHooksV2(taskId)[0].callRoles, ROLE_ANY, "roles pinned at attach");
        _relay(
            requester, 0, abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, 2 days, 1 days, resolver))
        );
        assertEq(_rolesSeen(h, taskId, requester), ROLE_REQUESTER);
        assertEq(_rolesSeen(h, taskId, stranger), ROLE_STRANGER);
        assertEq(_rolesSeen(h, taskId, worker), ROLE_STRANGER, "not yet the worker");
        assertEq(_rolesSeen(h, taskId, evaluator), ROLE_EVALUATOR);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(_rolesSeen(h, taskId, worker), ROLE_WORKER);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        // Submitter is a contest role (Bounty, Benchmark); a single-worker delivery stays Worker.
        assertEq(_rolesSeen(h, taskId, worker), ROLE_WORKER);
        assertEq(h.lastData(), hex"01");
    }

    function test_RolesPitch() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_PITCH);
        _relay(worker, 0, abi.encodeCall(market.submitPitch, (taskId, keccak256("pitch"))));
        assertEq(_rolesSeen(h, taskId, worker), ROLE_STRANGER, "a pitch is no role");
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker)));
        assertEq(_rolesSeen(h, taskId, worker), ROLE_WORKER);
        assertEq(_rolesSeen(h, taskId, requester), ROLE_REQUESTER);
    }

    function test_RolesAuction() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_AUCTION);
        assertEq(_rolesSeen(h, taskId, worker), ROLE_STRANGER);
        _relay(worker, 0, abi.encodeCall(market.acceptAuction, (taskId, 60e6)));
        assertEq(_rolesSeen(h, taskId, worker), ROLE_WORKER);
    }

    function test_RolesBounty() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_BOUNTY);
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        assertEq(_rolesSeen(h, taskId, worker2), ROLE_SUBMITTER, "any submitter on a bounty");
        assertEq(_rolesSeen(h, taskId, worker), ROLE_STRANGER);
    }

    function test_RolesWorkerReassignedAfterForfeit() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_CLAIM);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(v2.taskCallerRoles(taskId, worker), ROLE_WORKER);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        assertEq(_rolesSeen(h, taskId, worker), ROLE_STRANGER, "forfeited worker loses the role");
        _relay(requester, 0, abi.encodeCall(market.updateTask, (taskId, 0, block.timestamp + 3 days, 0, 0)));
        _relay(worker2, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(_rolesSeen(h, taskId, worker2), ROLE_WORKER, "the new worker");
        assertEq(_rolesSeen(h, taskId, worker), ROLE_STRANGER);
    }

    function test_RolesOneWalletHoldsSeveral() public {
        MockCallHookV2 h = new MockCallHookV2(address(market), ROLE_ANY);
        bytes32 taskId = _createWith(TMP_CLAIM, _one(address(h)), new bytes[](0));
        _relay(requester, 0, abi.encodeCall(market.assignEvaluator, (taskId, worker, 0, 0, 2 days, 1 days, resolver)));
        uint32 r = v2.taskCallerRoles(taskId, worker);
        assertTrue(r & ROLE_EVALUATOR != 0 && r & ROLE_STRANGER == 0, "evaluator, not a stranger");
    }

    function test_CallTaskHookRefusesRoleNotAccepted() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_WORKER, TMP_CLAIM);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_REQUESTER));
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_STRANGER));
        vm.prank(stranger);
        v2.callTaskHook(taskId, address(h), hex"");
        assertEq(h.calls(), 0);
    }

    function test_CallTaskHookAcceptsStrangerOnlyWhenDeclared() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_STRANGER, TMP_CLAIM);
        vm.prank(stranger);
        v2.callTaskHook(taskId, address(h), hex"");
        assertEq(h.lastRoles(), ROLE_STRANGER);
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCallRoleRefused.selector, ROLE_REQUESTER));
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
    }

    function test_CallTaskHookRefusesARelayedPayment() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_CLAIM);
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(requester, 1, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
    }

    function test_CallTaskHookRefusesHookNotAttached() public {
        (, bytes32 taskId) = _callHook(ROLE_ANY, TMP_CLAIM);
        MockCallHookV2 other = new MockCallHookV2(address(market), ROLE_ANY);
        vm.expectRevert(ITMPHooksV2.HookNotAttached.selector);
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(other), hex"")));
    }

    function test_CallTaskHookRefusesHookWithoutCapability() public {
        MockTaskHookV2 h = _mock(BIT_CREATE);
        bytes32 taskId = _createClaim(address(h));
        assertEq(v2.getTaskHooksV2(taskId)[0].callRoles, 0);
        vm.expectRevert(ITMPHooksV2.HookCallNotDeclared.selector);
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
    }

    function test_CallTaskHookRefusesSettledTask() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_CLAIM);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        vm.expectRevert(ITMPHooksV2.TaskAlreadySettled.selector);
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
    }

    function test_CallTaskHookSurfacesHookRevert() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_CLAIM);
        h.setRefuse(true);
        vm.expectRevert(_gateRejected(MockCallHookV2.MockCallRefused.selector));
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
    }

    function test_CallTaskHookRefusesReentry() public {
        (MockCallHookV2 h, bytes32 taskId) = _callHook(ROLE_ANY, TMP_CLAIM);
        h.setReenter(true);
        vm.expectPartialRevert(ITMPHooksV2.HookRejected.selector);
        _relay(requester, 0, abi.encodeCall(v2.callTaskHook, (taskId, address(h), hex"")));
        assertEq(h.calls(), 0);
    }

    // -------------------------------------------------------------------------
    // Review fixes
    // -------------------------------------------------------------------------

    function test_ExpiryNeverRevertsForHookGas() public {
        vm.startPrank(owner);
        v2.setHookCapabilityGas(23, 8_000_000);
        vm.stopPrank();
        address[] memory hooks = new address[](8);
        for (uint256 i; i < 8; ++i) {
            hooks[i] = address(_mock(BIT_AFTER_EXPIRE));
        }
        bytes32 taskId = _createWith(TMP_CLAIM, hooks, new bytes[](0));
        vm.warp(block.timestamp + DURATION + 1);
        market.refundExpired{ gas: 3_000_000 }(taskId, 0);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired), "expired");
        assertEq(usdc.balanceOf(requester), REWARD, "refunded");
        assertEq(v2.hookCallSeq(taskId, 7), 1, "skipped callbacks still spend a sequence number");
    }

    function test_DisputeRulingIgnoresSettlementResult() public {
        vm.prank(owner);
        v2.setMaxHookFeeBps(100);
        MockTaskHookV2 h = _mock(BIT_ACCEPT | BIT_REALLOCATE | BIT_HOOK_FEE);
        bytes32 taskId = _disputedTask(address(h));
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: 1e6, rank: 1 });
        h.setResult(awards, 100, false);
        _resolve(taskId);
        assertEq(usdc.balanceOf(worker), _net(REWARD), "the ruling stands as given");
        assertEq(usdc.balanceOf(address(h)), 0, "no hook fee on a ruling");
    }

    function test_PriorStatusOnCancel() public {
        MockTaskHookV2 h = _mock(BIT_CANCEL);
        bytes32 taskId = _createClaim(address(h));
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(uint8(h.lastPriorStatus()), uint8(ITMPCore.TaskStatus.Open));
    }

    function test_PreCutTaskCancelsWithoutItsV1Hook() public {
        MockTaskHook v1 = new MockTaskHook();
        bytes32 taskId = _legacyV1Task(v1);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertTrue(v2.getTaskSettlement(taskId).recorded);
        assertEq(v1.onCancelCalls(), 0, "the V1 hook is not called");
    }

    // -------------------------------------------------------------------------
    // Base defaults and owner settings
    // -------------------------------------------------------------------------

    function test_BaseDefaultsAllowAndIgnore() public {
        DefaultsHookV2 h = new DefaultsHookV2(address(market));
        ITMPHookV2.TaskContextV2 memory c;
        ITMPCore.Verdict memory v;
        ITMPHookV2.SettlementAmounts memory a;
        bytes32 t = keccak256("t");
        vm.startPrank(address(market));
        assertEq(h.beforeCreate(t, c, "", ""), h.beforeCreate.selector);
        assertEq(h.beforeAssignEvaluator(t, c, address(0), ""), h.beforeAssignEvaluator.selector);
        assertEq(h.beforeUpdate(t, c, ""), h.beforeUpdate.selector);
        assertEq(h.beforeClaim(t, c, address(0), ""), h.beforeClaim.selector);
        assertEq(h.beforeSubmitPitch(t, c, address(0), bytes32(0), ""), h.beforeSubmitPitch.selector);
        assertEq(h.beforeSelectWorker(t, c, address(0), ""), h.beforeSelectWorker.selector);
        assertEq(h.beforeSubmitProof(t, c, address(0), bytes32(0), ""), h.beforeSubmitProof.selector);
        assertEq(h.beforeSubmitBid(t, c, address(0), 0, ""), h.beforeSubmitBid.selector);
        assertEq(h.beforeAcceptAuction(t, c, address(0), ""), h.beforeAcceptAuction.selector);
        assertEq(h.beforeSubmitWork(t, c, address(0), bytes32(0), ""), h.beforeSubmitWork.selector);
        assertEq(h.beforeRejectSubmission(t, c, address(0), ""), h.beforeRejectSubmission.selector);
        assertEq(h.beforeEvaluate(t, c, v, ""), h.beforeEvaluate.selector);
        assertEq(h.beforeAppeal(t, c, address(0), ""), h.beforeAppeal.selector);
        (bytes4 sel,,) = h.beforeAccept(t, c, v, "");
        assertEq(sel, h.beforeAccept.selector);
        assertEq(h.beforeCancel(t, c, ""), h.beforeCancel.selector);
        assertEq(h.beforeRate(t, c, address(0), ""), h.beforeRate.selector);
        h.afterComplete(t, c, a, 0);
        h.afterCancel(t, c, a, 0);
        h.afterExpire(t, c, a, 0);
        h.afterForfeit(t, c, a, 0);
        h.afterAction(t, c, 0, "", 0);
        vm.stopPrank();
        assertEq(h.minDiamondVersion(), 28);
        assertTrue(h.supportsInterface(type(ITMPHookV2).interfaceId));
        vm.expectRevert();
        h.beforeClaim(t, c, address(0), "");
        vm.expectRevert(BaseTMPHookV2.BaseTMPHookV2__ZeroDiamond.selector);
        new DefaultsHookV2(address(0));
    }

    function test_OwnerSettingsAndViews() public {
        assertEq(v2.hookCapabilityGas(3), 1_000_000, "floor by default");
        assertEq(v2.maxHookFeeBps(), 0);
        assertEq(v2.getDefaultHooksV2().length, 0);
        vm.startPrank(owner);
        vm.expectRevert(ITMPHooksV2.HookCapabilityGasOutOfRange.selector);
        v2.setHookCapabilityGas(3, 999_999);
        vm.expectRevert(ITMPHooksV2.HookCapabilityGasOutOfRange.selector);
        v2.setHookCapabilityGas(3, 8_000_001);
        vm.expectRevert(ITMPHooksV2.HookCapabilityGasOutOfRange.selector);
        v2.setHookCapabilityGas(32, 2_000_000);
        v2.setHookCapabilityGas(3, 2_000_000);
        vm.expectRevert(ITMPHooksV2.MaxHookFeeBpsOutOfRange.selector);
        v2.setMaxHookFeeBps(1001);
        v2.setMaxHookFeeBps(1000);
        address[] memory two = new address[](2);
        two[0] = address(_mock(BIT_ACCEPT | BIT_REALLOCATE));
        two[1] = address(_mock(BIT_ACCEPT | BIT_HOOK_FEE));
        vm.expectRevert(ITMPHooksV2.MultipleTransformingHooks.selector);
        v2.setDefaultHooksV2(two);
        two[1] = two[0];
        vm.expectRevert(ITMPCore.DuplicateHookAddress.selector);
        v2.setDefaultHooksV2(two);
        vm.stopPrank();
        assertEq(v2.hookCapabilityGas(3), 2_000_000);
        assertEq(v2.maxHookFeeBps(), 1000);
        vm.expectRevert();
        v2.setMaxHookFeeBps(1);
    }

    function test_WithActionDataBubblesRevertsAndRejectsNesting() public {
        bytes memory nested = abi.encodeCall(v2.withActionData, (hex"", hex""));
        vm.expectRevert(ITMPHooksV2.ActionDataCallFailed.selector);
        v2.withActionData(hex"01", nested);
        bytes memory bad = abi.encodeCall(market.claimTask, (keccak256("none"), 0));
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        v2.withActionData(hex"01", bad);
    }

    // -------------------------------------------------------------------------
    // Combined-branch review fixes
    // -------------------------------------------------------------------------

    function test_WithActionDataRefusedInsideDispatch() public {
        ActionDataReentryHook h = new ActionDataReentryHook(address(market));
        bytes32 taskId = _createClaim(address(h));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertTrue(h.attempted(), "the hook tried");
        assertFalse(h.succeeded(), "withActionData is refused inside an action under way");
    }

    function test_FeeOnlyResultStillRejectsZeroPair() public {
        vm.prank(owner);
        v2.setMaxHookFeeBps(100);
        MockTaskHookV2 h = _mock(BIT_ACCEPT | BIT_HOOK_FEE);
        bytes32 taskId = _createWith(TMP_BOUNTY, _one(address(h)), new bytes[](0));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work2"))));
        h.setResult(new ITMPCore.Award[](0), 100, false);
        address[] memory workers = new address[](2);
        workers[0] = worker;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 10000;
        vm.expectRevert(ITMPCore.ZeroPayoutPerPair.selector);
        _relay(
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), uint256(0)))
        );
    }

    function test_BeforeAcceptSeesStatusBeforeTheAccept() public {
        MockTaskHookV2 h = _mock(BIT_ACCEPT);
        bytes32 taskId = _createClaim(address(h));
        _claimAndSubmit(taskId);
        ITMPCore.TaskStatus before = market.getTaskState(taskId);
        _accept(taskId);
        assertEq(uint8(h.lastAcceptState()), uint8(before), "accept path: the status before Accepted");

        MockTaskHookV2 h2 = _mock(BIT_ACCEPT);
        bytes32 evalTask = _createClaim(address(h2));
        _relay(
            requester, 0, abi.encodeCall(market.assignEvaluator, (evalTask, evaluator, 0, 0, 2 days, 1 days, resolver))
        );
        _claimAndSubmit(evalTask);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (evalTask, ITMPCore.VerdictType.APPROVE, 900, 1000, bytes32(0), awards))
        );
        vm.warp(block.timestamp + 1 days);
        market.finalizeVerdict(evalTask);
        assertEq(uint8(h2.lastAcceptState()), uint8(ITMPCore.TaskStatus.Appealing), "finalize path: Appealing");
    }

    function test_VerdictRecordsTheAwardsPaid() public {
        MockTaskHookV2 h = _mock(BIT_ACCEPT | BIT_REALLOCATE);
        bytes32 taskId = _createClaim(address(h));
        _relay(
            requester, 0, abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, 2 days, 1 days, resolver))
        );
        _claimAndSubmit(taskId);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.APPROVE, 900, 1000, bytes32(0), awards))
        );
        ITMPCore.Award[] memory reduced = new ITMPCore.Award[](1);
        reduced[0] = ITMPCore.Award({ worker: worker, amount: 30e6, rank: 1 });
        h.setResult(reduced, 0, false);
        vm.warp(block.timestamp + 1 days);
        market.finalizeVerdict(taskId);
        ITMPCore.Verdict memory v = market.getTaskVerdict(taskId);
        assertEq(v.awards.length, 1);
        assertEq(v.awards[0].amount, 30e6, "the verdict holds the paid award");
        assertEq(usdc.balanceOf(worker), _net(30e6));
    }

    /// @dev The ERC-165 id clients and the backend use to recognise a V2 hook.
    function test_ITMPHookV2InterfaceId() public pure {
        assertEq(type(ITMPHookV2).interfaceId, bytes4(0x9044a8c7));
    }

    // -------------------------------------------------------------------------
    // Integration smoke fixes
    // -------------------------------------------------------------------------

    function test_AcceptRequiresGasForEveryAfterCallback() public {
        vm.prank(owner);
        v2.setHookCapabilityGas(21, 4_000_000);
        MockTaskHookV2 h = _mock(BIT_AFTER_COMPLETE);
        bytes32 taskId = _createClaim(address(h));
        _claimAndSubmit(taskId);
        bytes memory accept = abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0));
        // Too little gas for the after-callback's budget: the accept reverts rather than skipping
        // it, so a gas estimate for the accept always covers the callback.
        vm.expectRevert(ITMPHooksV2.InsufficientGasForHooks.selector);
        forwarder.relay{ gas: 3_000_000 }(address(market), requester, 0, accept);
        _relay(requester, 0, accept);
        assertEq(h.lastTerminalKind(), 1, "afterComplete ran");
    }

    function test_DefaultBudgetFollowsHookGasStipend() public {
        vm.prank(owner);
        market.setHookGasStipend(3_000_000);
        assertEq(v2.hookCapabilityGas(0), 3_000_000, "unset budgets read the chain's stipend");
    }

    function test_HookRejectedCarriesReason() public {
        MockTaskHookV2 h = _mock(BIT_CLAIM);
        bytes32 taskId = _createClaim(address(h));
        h.setVeto(3, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                ITMPHooksV2.HookRejected.selector, uint8(0), uint8(3), abi.encodeWithSignature("Error(string)", "veto")
            )
        );
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    function test_StrictAfterCallbackGasIsCapped() public {
        // A Tempo-like stipend and a full task of after-callback hooks: the strict requirement is
        // capped, so the accept stays reachable under a 29.9M transaction.
        vm.prank(owner);
        market.setHookGasStipend(6_000_000);
        address[] memory hooks = new address[](8);
        for (uint256 i; i < 8; ++i) {
            hooks[i] = address(_mock(BIT_AFTER_COMPLETE));
        }
        bytes32 taskId = _createWith(TMP_CLAIM, hooks, new bytes[](0));
        _claimAndSubmit(taskId);
        forwarder.relay{ gas: 29_000_000 }(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0))
        );
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(MockTaskHookV2(hooks[0]).lastTerminalKind(), 1, "the first callbacks ran");
    }
}

/// @dev A V2 hook that keeps every BaseTMPHookV2 default.
contract DefaultsHookV2 is BaseTMPHookV2 {
    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return 1;
    }
}

/// @dev A hook whose beforeClaim tries withActionData mid-dispatch.
contract ActionDataReentryHook is BaseTMPHookV2 {
    bool public attempted;
    bool public succeeded;

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function hookCapabilities() external pure override returns (uint32) {
        return uint32(1) << 3;
    }

    function beforeClaim(bytes32, TaskContextV2 calldata, address, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        attempted = true;
        (succeeded,) = diamond.call(abi.encodeCall(ITMPHooksV2.withActionData, (hex"01", hex"")));
        return this.beforeClaim.selector;
    }
}
