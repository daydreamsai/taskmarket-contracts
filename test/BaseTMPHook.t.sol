// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { BaseTMPHook } from "../src/hooks/base/BaseTMPHook.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";

contract BaseTMPHookHarness is BaseTMPHook {
    bool public expireCalled;
    uint8 public lastCallback;
    bytes32 public lastTaskId;
    address public lastRequester;
    uint256 public lastReward;
    bytes public lastHookData;
    address public lastActor;
    bytes32 public lastHash;

    constructor(address diamond_) BaseTMPHook(diamond_) { }

    function _record(uint8 callbackId, bytes32 taskId, ITMPCore.TaskContext calldata ctx) private {
        lastCallback = callbackId;
        lastTaskId = taskId;
        lastRequester = ctx.requester;
        lastReward = ctx.reward;
    }

    function _checkFund(bytes32 taskId, ITMPCore.TaskContext calldata ctx, bytes calldata hookData)
        internal
        override
        returns (bool)
    {
        _record(1, taskId, ctx);
        lastHookData = hookData;
        return false;
    }

    function _checkClaim(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        internal
        override
        returns (bool)
    {
        _record(2, taskId, ctx);
        lastActor = worker;
        return true;
    }

    function _checkSelectWorker(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        internal
        override
        returns (bool)
    {
        _record(3, taskId, ctx);
        lastActor = worker;
        return true;
    }

    function _checkSubmit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker, bytes32 deliverableHash)
        internal
        override
        returns (bool)
    {
        _record(4, taskId, ctx);
        lastActor = worker;
        lastHash = deliverableHash;
        return true;
    }

    function _checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address evaluator)
        internal
        override
        returns (bool)
    {
        _record(5, taskId, ctx);
        lastActor = evaluator;
        return true;
    }

    function _checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
        returns (bool)
    {
        _record(6, taskId, ctx);
        lastHash = verdict.evidenceHash;
        return true;
    }

    function _onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        internal
        override
    {
        _record(7, taskId, ctx);
        lastHash = verdict.evidenceHash;
    }

    function _onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) internal override {
        _record(8, taskId, ctx);
        lastActor = worker;
    }

    function _onCancel(bytes32 taskId, ITMPCore.TaskContext calldata ctx) internal override {
        _record(9, taskId, ctx);
    }

    function _onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) internal override {
        _record(10, taskId, ctx);
        expireCalled = true;
    }
}

contract DefaultBaseTMPHook is BaseTMPHook {
    constructor(address diamond_) BaseTMPHook(diamond_) { }
}

interface IExtraBaseTMPHook {
    function extraCapability() external;
}

contract ExtendedBaseTMPHook is DefaultBaseTMPHook, IExtraBaseTMPHook {
    constructor(address diamond_) DefaultBaseTMPHook(diamond_) { }

    function extraCapability() external { }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IExtraBaseTMPHook).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract BaseTMPHookTest is Test {
    address internal diamond = makeAddr("diamond");
    address internal caller = makeAddr("caller");
    BaseTMPHookHarness internal hook;

    function setUp() public {
        hook = new BaseTMPHookHarness(diamond);
    }

    function test_constructorRejectsZeroDiamond() public {
        vm.expectRevert(BaseTMPHook.BaseTMPHook__ZeroDiamond.selector);
        new BaseTMPHookHarness(address(0));
    }

    function test_exposesConfiguredDiamond() public view {
        assertEq(hook.diamond(), diamond);
    }

    function test_supportsHookAndERC165Interfaces() public view {
        assertTrue(hook.supportsInterface(type(ITMPHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(0xffffffff));
    }

    function test_derivedHookCanComposeERC165SupportThroughSuper() public {
        ExtendedBaseTMPHook extended = new ExtendedBaseTMPHook(diamond);

        assertTrue(extended.supportsInterface(type(IExtraBaseTMPHook).interfaceId));
        assertTrue(extended.supportsInterface(type(ITMPHook).interfaceId));
        assertTrue(extended.supportsInterface(type(IERC165).interfaceId));
    }

    function test_onlyDiamondGuardsEveryCallback() public {
        ITMPCore.TaskContext memory ctx;
        ITMPCore.Verdict memory verdict;

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.checkFund(bytes32(0), ctx, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.checkClaim(bytes32(0), ctx, address(0));
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.checkSelectWorker(bytes32(0), ctx, address(0));
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.checkSubmit(bytes32(0), ctx, address(0), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.checkEvaluate(bytes32(0), ctx, address(0));
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.checkComplete(bytes32(0), ctx, verdict);
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.onComplete(bytes32(0), ctx, verdict);
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.onForfeit(bytes32(0), ctx, address(0));
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.onCancel(bytes32(0), ctx);
        vm.expectRevert(abi.encodeWithSelector(BaseTMPHook.BaseTMPHook__UnauthorizedCaller.selector, caller));
        hook.onExpire(bytes32(0), ctx);
        vm.stopPrank();
    }

    function test_defaultsAllowChecksAndNoOpOnCallbacks() public {
        DefaultBaseTMPHook defaultHook = new DefaultBaseTMPHook(diamond);
        ITMPCore.TaskContext memory ctx;
        ITMPCore.Verdict memory verdict;

        vm.startPrank(diamond);
        assertTrue(defaultHook.checkFund(bytes32(0), ctx, bytes("")));
        assertTrue(defaultHook.checkClaim(bytes32(0), ctx, address(0)));
        assertTrue(defaultHook.checkSelectWorker(bytes32(0), ctx, address(0)));
        assertTrue(defaultHook.checkSubmit(bytes32(0), ctx, address(0), bytes32(0)));
        assertTrue(defaultHook.checkEvaluate(bytes32(0), ctx, address(0)));
        assertTrue(defaultHook.checkComplete(bytes32(0), ctx, verdict));
        defaultHook.onComplete(bytes32(0), ctx, verdict);
        defaultHook.onForfeit(bytes32(0), ctx, address(0));
        defaultHook.onCancel(bytes32(0), ctx);
        defaultHook.onExpire(bytes32(0), ctx);
        vm.stopPrank();
    }

    function test_checkOverrideControlsDiamondResult() public {
        ITMPCore.TaskContext memory ctx;

        vm.prank(diamond);
        assertFalse(hook.checkFund(bytes32(0), ctx, bytes("")));
    }

    function test_overrideIsCalledOnlyThroughDiamond() public {
        ITMPCore.TaskContext memory ctx;

        vm.prank(diamond);
        hook.onExpire(bytes32(0), ctx);

        assertTrue(hook.expireCalled());
    }

    function test_forwardsEveryCallbackAndItsDistinctArguments() public {
        bytes32 taskId = keccak256("forwarded-task");
        bytes memory hookData = hex"010203";
        address actor = makeAddr("forwarded-actor");
        bytes32 forwardedHash = keccak256("forwarded-hash");
        ITMPCore.TaskContext memory ctx;
        ctx.requester = makeAddr("forwarded-requester");
        ctx.reward = 42 ether;
        ITMPCore.Verdict memory verdict;
        verdict.evidenceHash = forwardedHash;

        vm.startPrank(diamond);
        hook.checkFund(taskId, ctx, hookData);
        _assertCommonForwarding(1, taskId, ctx);
        assertEq(hook.lastHookData(), hookData);
        hook.checkClaim(taskId, ctx, actor);
        _assertActorForwarding(2, taskId, ctx, actor);
        hook.checkSelectWorker(taskId, ctx, actor);
        _assertActorForwarding(3, taskId, ctx, actor);
        hook.checkSubmit(taskId, ctx, actor, forwardedHash);
        _assertActorForwarding(4, taskId, ctx, actor);
        assertEq(hook.lastHash(), forwardedHash);
        hook.checkEvaluate(taskId, ctx, actor);
        _assertActorForwarding(5, taskId, ctx, actor);
        hook.checkComplete(taskId, ctx, verdict);
        _assertCommonForwarding(6, taskId, ctx);
        assertEq(hook.lastHash(), forwardedHash);
        hook.onComplete(taskId, ctx, verdict);
        _assertCommonForwarding(7, taskId, ctx);
        assertEq(hook.lastHash(), forwardedHash);
        hook.onForfeit(taskId, ctx, actor);
        _assertActorForwarding(8, taskId, ctx, actor);
        hook.onCancel(taskId, ctx);
        _assertCommonForwarding(9, taskId, ctx);
        hook.onExpire(taskId, ctx);
        _assertCommonForwarding(10, taskId, ctx);
        vm.stopPrank();
    }

    function _assertCommonForwarding(uint8 callbackId, bytes32 taskId, ITMPCore.TaskContext memory ctx) private view {
        assertEq(hook.lastCallback(), callbackId);
        assertEq(hook.lastTaskId(), taskId);
        assertEq(hook.lastRequester(), ctx.requester);
        assertEq(hook.lastReward(), ctx.reward);
    }

    function _assertActorForwarding(uint8 callbackId, bytes32 taskId, ITMPCore.TaskContext memory ctx, address actor)
        private
        view
    {
        _assertCommonForwarding(callbackId, taskId, ctx);
        assertEq(hook.lastActor(), actor);
    }
}
