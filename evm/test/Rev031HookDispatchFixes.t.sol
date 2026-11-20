// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { TaskMarketForwarderV2 } from "../src/TaskMarketForwarderV2.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev Records the context actor of its after-callbacks and the gas onCall receives.
contract ActorRecorderHookV2 is BaseTMPHookV2 {
    uint32 internal immutable _caps;
    address public lastActor = address(0xdead);
    uint256 public afterCalls;
    uint256 public onCallGas;

    constructor(address diamond_, uint32 caps_) BaseTMPHookV2(diamond_) {
        _caps = caps_;
    }

    function hookCapabilities() external view override returns (uint32) {
        return _caps;
    }

    function hookCallRoles() external pure override returns (uint32) {
        return uint32(1); // ROLE_REQUESTER
    }

    function onCall(bytes32, TaskContextV2 calldata, address, uint32, bytes calldata)
        external
        override
        onlyDiamond
        returns (bytes4)
    {
        onCallGas = gasleft();
        return ITMPHookV2.onCall.selector;
    }

    function afterComplete(bytes32, TaskContextV2 calldata ctx, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _record(ctx.actor);
    }

    function afterExpire(bytes32, TaskContextV2 calldata ctx, SettlementAmounts calldata, uint64)
        external
        override
        onlyDiamond
    {
        _record(ctx.actor);
    }

    function _record(address actor) internal {
        lastActor = actor;
        ++afterCalls;
    }
}

/// @dev rev031: the hook context keeps the outer actor on a self-call and survives a forwarder
///      that reports no sender, onCall gets its own budget, the appeal window floor is held
///      under the terms ceiling, and a default hook is checked for a delegation at attach.
contract Rev031HookDispatchFixesTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);
    address internal stranger = address(0x5157);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant DURATION = 7 days;
    bytes32 internal constant WORK = keccak256("work");

    uint32 internal constant BIT_AFTER_COMPLETE = uint32(1) << 21;
    uint32 internal constant BIT_AFTER_EXPIRE = uint32(1) << 23;
    uint32 internal constant BIT_OBSERVER = uint32(1) << 25;
    uint32 internal constant BIT_HOOK_CALL = uint32(1) << 30;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(address[] memory hooks, ITMPCore.TaskEvaluatorConfig memory cfg) internal returns (bytes32) {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                stakeTerms(false, 0)
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _noEvaluator() internal pure returns (ITMPCore.TaskEvaluatorConfig memory c) {
        return c;
    }

    // -------------------------------------------------------------------------
    // Cyclops 7635: refundExpired settling a verdict keeps its caller as the actor
    // -------------------------------------------------------------------------

    function test_RefundExpiredFinalizingAVerdict_ActorIsTheCaller() public {
        ActorRecorderHookV2 hook = new ActorRecorderHookV2(address(market), BIT_AFTER_COMPLETE);
        ITMPCore.TaskEvaluatorConfig memory cfg = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
        bytes32 id = _create(_one(address(hook)), cfg);
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (id, STAKE)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (id, ITMPCore.VerdictType.APPROVE, 900, 1000, bytes32(0), awards))
        );
        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Appealing));

        vm.warp(market.getTask(id).expiryTime + 1);
        vm.prank(stranger);
        market.refundExpired(id, 0);

        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(hook.afterCalls(), 1, "afterComplete ran");
        assertEq(hook.lastActor(), stranger, "the caller, not the diamond");
    }

    // -------------------------------------------------------------------------
    // Cyclops 7638: a forwarder reporting no sender gives the zero actor, not a revert
    // -------------------------------------------------------------------------

    function test_ZeroSenderRelayOnHookedTask_ActorIsZero() public {
        address relayer = address(0x7E1A);
        TaskMarketForwarderV2 realForwarder = new TaskMarketForwarderV2(address(usdc), address(market), relayer);
        vm.prank(owner);
        market.addForwarder(address(realForwarder));

        ActorRecorderHookV2 hook = new ActorRecorderHookV2(address(market), BIT_AFTER_EXPIRE);
        bytes32 id = _create(_one(address(hook)), _noEvaluator());
        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(relayer);
        realForwarder.relay(
            address(0), 0, block.timestamp + 60, keccak256("zero-sender"), abi.encodeCall(market.refundExpired, (id, 0))
        );

        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(hook.afterCalls(), 1, "afterExpire ran");
        assertEq(hook.lastActor(), address(0), "no sender reads as the zero actor");
    }

    // -------------------------------------------------------------------------
    // Cyclops 7636, Cantina TASK-302: onCall is budgeted under BIT_HOOK_CALL
    // -------------------------------------------------------------------------

    function test_CallTaskHook_BudgetedUnderBitHookCall() public {
        vm.startPrank(owner);
        ITMPHooksV2(address(market)).setHookCapabilityGas(22, 4_000_000);
        ITMPHooksV2(address(market)).setHookCapabilityGas(30, 1_000_000);
        vm.stopPrank();

        ActorRecorderHookV2 hook = new ActorRecorderHookV2(address(market), BIT_HOOK_CALL);
        bytes32 id = _create(_one(address(hook)), _noEvaluator());
        _relay(requester, 0, abi.encodeCall(ITMPHooksV2.callTaskHook, (id, address(hook), hex"")));

        assertGt(hook.onCallGas(), 0, "onCall ran");
        assertLe(hook.onCallGas(), 1_000_000, "the bit 30 budget, not afterCancel's");
    }

    // -------------------------------------------------------------------------
    // Cyclops 7641: the appeal window floor stays at or under the terms ceiling
    // -------------------------------------------------------------------------

    function test_SetMinAppealWindow_AboveMaxWindowReverts() public {
        (, uint32 maxWindow,,) = market.termsBounds();
        vm.startPrank(owner);
        vm.expectRevert(ITMPCore.InvalidMinAppealWindow.selector);
        market.setMinAppealWindowSecs(maxWindow + 1);
        market.setMinAppealWindowSecs(maxWindow);
        vm.stopPrank();
        assertEq(market.minAppealWindowSecs(), maxWindow);
    }

    function test_SetTermsBounds_MaxBelowAppealFloorReverts() public {
        vm.startPrank(owner);
        market.setMinAppealWindowSecs(2 days);
        vm.expectRevert(ITMPCore.InvalidTermsBounds.selector);
        market.setTermsBounds(1 hours, 2 days - 1, 1000, 3);
        market.setTermsBounds(1 hours, 2 days, 1000, 3);
        vm.stopPrank();
        (, uint32 maxWindow,,) = market.termsBounds();
        assertEq(maxWindow, 2 days);
    }

    // -------------------------------------------------------------------------
    // Cyclops 7664: a default hook that is a delegated account is refused at attach
    // -------------------------------------------------------------------------

    /// A default set before rev030 never passed the designator check, so its pinned codehash can
    /// be a designator's. The test writes that state: the default is set while the address holds
    /// hook code, then the address becomes a designator and the pin is rewritten to match.
    function test_HookAttach_RefusesDelegatedDefaultHook() public {
        ActorRecorderHookV2 impl = new ActorRecorderHookV2(address(market), BIT_OBSERVER);
        address legacy = address(0xD7702);
        vm.etch(legacy, address(impl).code);
        vm.prank(owner);
        ITMPHooksV2(address(market)).setDefaultHooksV2(_one(legacy));

        bytes32 pinned = legacy.codehash;
        vm.etch(legacy, abi.encodePacked(hex"ef0100", address(impl)));
        _repin(pinned, legacy.codehash);
        assertEq(ITMPHooksV2(address(market)).getDefaultHooksV2()[0].codehash, legacy.codehash);

        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                _noEvaluator(),
                stakeTerms(false, 0)
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookDelegatedAccount.selector, uint8(0)));
        _relay(requester, REWARD, data);
    }

    function _repin(bytes32 from, bytes32 to) internal {
        vm.record();
        ITMPHooksV2(address(market)).getDefaultHooksV2();
        (bytes32[] memory reads,) = vm.accesses(address(market));
        for (uint256 i; i < reads.length; ++i) {
            if (vm.load(address(market), reads[i]) == from) {
                vm.store(address(market), reads[i], to);
                return;
            }
        }
        revert("pinned codehash slot not found");
    }
}
