// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev031: an observer hook whose code changed after attach is skipped and reported on the
///      actions it watches (Cyclops 7611, 7625); a changed hook that vetoes the action still blocks it.
contract ObserverHookCodeChangeTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPHooksV2 internal v2;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;
    bytes32 internal constant WORK = keccak256("work");

    uint8 internal constant A_SUBMIT_WORK = 9;
    uint8 internal constant A_EVALUATE = 11;
    uint8 internal constant A_APPEAL = 12;
    uint8 internal constant FAIL_CODE_CHANGED = 6;
    uint32 internal constant BIT_APPEAL = uint32(1) << 12;
    uint32 internal constant BIT_OBSERVER = uint32(1) << 25;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        v2 = ITMPHooksV2(address(market));
        usdc.mint(address(forwarder), 100_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(address hook) internal returns (bytes32) {
        address[] memory hooks = new address[](1);
        hooks[0] = hook;
        ITMPCore.TaskEvaluatorConfig memory cfg = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 0,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: resolver
        });
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, 7 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                stakeTerms(true, 1000)
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    function _claim(bytes32 id) internal {
        _relay(worker, STAKE, abi.encodeCall(market.claimTask, (id, STAKE)));
    }

    function _submit(bytes32 id) internal {
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));
    }

    function _reject(bytes32 id) internal {
        _relay(
            evaluator,
            0,
            abi.encodeCall(
                market.evaluate, (id, ITMPCore.VerdictType.REJECT, 0, 1000, bytes32(0), new ITMPCore.Award[](0))
            )
        );
    }

    function _change(address hook) internal {
        vm.etch(hook, address(usdc).code);
    }

    function _expectSkipped(bytes32 id, address hook, uint8 action) internal {
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPHooksV2.HookCallFailedV2(id, 0, hook, action, 1, FAIL_CODE_CHANGED, bytes32(0), v2.hookCallSeq(id, 0));
    }

    function test_ChangedObserverDoesNotBlockAppeal() public {
        MockTaskHookV2 h = new MockTaskHookV2(address(market), BIT_OBSERVER);
        bytes32 id = _create(address(h));
        _claim(id);
        _submit(id);
        _reject(id);
        _change(address(h));
        uint64 seq = v2.hookCallSeq(id, 0);
        _expectSkipped(id, address(h), A_APPEAL);
        _relay(worker, 0, abi.encodeCall(market.appeal, (id)));
        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Disputed), "the worker appealed");
        assertEq(v2.hookCallSeq(id, 0), seq + 1, "the skipped callback spends its sequence number");
    }

    function test_ChangedObserverDoesNotBlockEvaluate() public {
        MockTaskHookV2 h = new MockTaskHookV2(address(market), BIT_OBSERVER);
        bytes32 id = _create(address(h));
        _claim(id);
        _submit(id);
        _change(address(h));
        _expectSkipped(id, address(h), A_EVALUATE);
        _reject(id);
        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Appealing), "the verdict landed");
    }

    function test_ChangedObserverDoesNotBlockSubmit() public {
        MockTaskHookV2 h = new MockTaskHookV2(address(market), BIT_OBSERVER);
        bytes32 id = _create(address(h));
        _claim(id);
        _change(address(h));
        _expectSkipped(id, address(h), A_SUBMIT_WORK);
        _submit(id);
        assertEq(market.getTask(id).deliverable, WORK, "the delivery landed");
    }

    function test_ChangedVetoingHookStillBlocksAppeal() public {
        MockTaskHookV2 h = new MockTaskHookV2(address(market), BIT_APPEAL | BIT_OBSERVER);
        bytes32 id = _create(address(h));
        _claim(id);
        _submit(id);
        _reject(id);
        _change(address(h));
        vm.expectRevert(abi.encodeWithSelector(ITMPHooksV2.HookCodeChanged.selector, uint8(0)));
        _relay(worker, 0, abi.encodeCall(market.appeal, (id)));
    }
}
