// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TaskMarketForwarderV2.sol";
import "../src/interfaces/ITMPCore.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockUnreportingForwarder } from "./mocks/MockUnreportingForwarder.sol";
import "./helpers/DiamondTestHelper.sol";
import "../src/interfaces/ITMPDiamond.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev Funding checks on the relayed payment: a paying forwarder (v2) must move exactly the
///      reward plus evaluator stake on createTask, the stake on assignEvaluator and the increase
///      on updateTask; a forwarder that cannot report its payment is refused on every one.
contract EvaluatorStakePaymentTest is DiamondTestHelper {
    ITMPDiamond public market;
    MockUnreportingForwarder public unreporting;
    TaskMarketForwarderV2 public v2;
    MockUSDC public usdc;

    address public owner = address(1);
    address public server = address(2);
    address public requester = address(3);
    address public evaluator = address(6);

    uint256 constant REWARD = 100 * 10 ** 6;
    uint256 constant STAKE = 10 * 10 ** 6;
    uint256 constant DURATION = 7 days;
    uint256 internal _n;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), owner, 500);
        unreporting = new MockUnreportingForwarder();
        v2 = new TaskMarketForwarderV2(address(usdc), address(market), server);
        market.addForwarder(address(unreporting));
        market.addForwarder(address(v2));
        vm.stopPrank();

        usdc.mint(server, 10_000 * 10 ** 6);
        vm.startPrank(server);
        usdc.approve(address(v2), type(uint256).max);
        vm.stopPrank();
    }

    function _relay(address fwd, uint256 amount, bytes memory data) internal {
        _n++;
        vm.prank(server);
        TaskMarketForwarderV2(fwd).relay(requester, amount, block.timestamp + 5 minutes, bytes32(_n), data);
    }

    function _evalCfg(uint256 stake) internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: stake,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
    }

    function _createData(ITMPCore.TaskEvaluatorConfig memory cfg) internal view returns (bytes memory) {
        return abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, market.CLAIM(), 0, 0, bytes4(0)),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                stakeTerms(false, 0)
            )
        );
    }

    function _create(address fwd, uint256 paid, ITMPCore.TaskEvaluatorConfig memory cfg) internal returns (bytes32) {
        bytes32 taskId =
            keccak256(abi.encode(block.chainid, address(market), requester, market.requesterNonce(requester)));
        _relay(fwd, paid, _createData(cfg));
        return taskId;
    }

    function _assignData(bytes32 taskId, uint256 stake) internal view returns (bytes memory) {
        return abi.encodeCall(
            market.assignEvaluator, (taskId, evaluator, stake, 0, uint32(2 days), uint32(1 days), address(0))
        );
    }

    // ---------------------------------------------------------------------
    // v2: createTask
    // ---------------------------------------------------------------------

    function test_V2_CreateWithEvaluator_PaysRewardPlusStake_RecordsBothSeparately() public {
        uint256 before = usdc.balanceOf(address(market));
        bytes32 taskId = _create(address(v2), REWARD + STAKE, _evalCfg(STAKE));
        assertEq(market.getTask(taskId).reward, REWARD, "reward recorded");
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, STAKE, "stake recorded");
        assertEq(usdc.balanceOf(address(market)), before + REWARD + STAKE, "escrow holds both");
        assertEq(usdc.balanceOf(requester), 0, "nothing pulled from the requester");
    }

    function test_V2_CreateWithEvaluator_RewardOnly_Reverts() public {
        bytes memory data = _createData(_evalCfg(STAKE));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), REWARD, data);
    }

    function test_V2_CreateWithEvaluator_Overpaid_Reverts() public {
        bytes memory data = _createData(_evalCfg(STAKE));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), REWARD + STAKE + 1, data);
    }

    function test_V2_CreateWithEvaluator_ZeroStake_PaysReward() public {
        bytes32 taskId = _create(address(v2), REWARD, _evalCfg(0));
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, 0);
    }

    function test_V2_CreateWithoutEvaluator_WrongAmount_Reverts() public {
        bytes memory data = _createData(noEvaluatorConfig());
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), REWARD - 1, data);
    }

    function test_V2_CreateWithoutEvaluator_ExactReward_Works() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        assertEq(market.getTask(taskId).reward, REWARD);
    }

    // ---------------------------------------------------------------------
    // v2: assignEvaluator
    // ---------------------------------------------------------------------

    function test_V2_Assign_PaysExactStake() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        uint256 before = usdc.balanceOf(address(market));
        _relay(address(v2), STAKE, _assignData(taskId, STAKE));
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, STAKE, "stake recorded");
        assertEq(usdc.balanceOf(address(market)), before + STAKE, "stake in escrow once");
    }

    function test_V2_Assign_Mismatch_Reverts() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        bytes memory data = _assignData(taskId, STAKE);
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), STAKE - 1, data);
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), 0, data);
    }

    function test_V2_Assign_PaymentWithZeroStake_Reverts() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        bytes memory data = _assignData(taskId, 0);
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), STAKE, data);
    }

    function test_V2_Assign_ZeroStake_Free() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        _relay(address(v2), 0, _assignData(taskId, 0));
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, evaluator);
    }

    function test_V2_Cancel_RefundsRecordedStakeAndReward() public {
        bytes32 taskId = _create(address(v2), REWARD + STAKE, _evalCfg(STAKE));
        _relay(address(v2), 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(usdc.balanceOf(requester), REWARD + STAKE, "reward and stake refunded");
        assertEq(usdc.balanceOf(address(market)), 0, "escrow empty");
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, 0, "stake settled once");
    }

    // ---------------------------------------------------------------------
    // v2: updateTask
    // ---------------------------------------------------------------------

    function test_V2_Update_PaysExactIncrease() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        _relay(address(v2), 5e6, abi.encodeCall(market.updateTask, (taskId, REWARD + 5e6, 0, 0, 0)));
        assertEq(market.getTask(taskId).reward, REWARD + 5e6);
    }

    function test_V2_Update_IncreaseMismatch_Reverts() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        // Escrow holds enough for the new reward, which the balance check alone would accept.
        _create(address(v2), REWARD, noEvaluatorConfig());
        bytes memory data = abi.encodeCall(market.updateTask, (taskId, REWARD + 5e6, 0, 0, 0));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), 0, data);
    }

    function test_V2_Update_PaymentWithoutIncrease_Reverts() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        bytes memory data = abi.encodeCall(market.updateTask, (taskId, REWARD - 1e6, 0, 0, 0));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(address(v2), 1, data);
    }

    // ---------------------------------------------------------------------
    // A forwarder that cannot report its payment is refused
    // ---------------------------------------------------------------------

    function test_Unreported_CreateWithoutEvaluator_Reverts() public {
        bytes memory data = _createData(noEvaluatorConfig());
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        unreporting.relay(address(market), requester, data);
    }

    function test_Unreported_CreateWithEvaluator_Reverts() public {
        bytes memory data = _createData(_evalCfg(STAKE));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        unreporting.relay(address(market), requester, data);
    }

    function test_Unreported_Assign_ZeroStake_Reverts() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        bytes memory data = _assignData(taskId, 0);
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        unreporting.relay(address(market), requester, data);
    }

    function test_Unreported_Update_Increase_Reverts() public {
        bytes32 taskId = _create(address(v2), REWARD, noEvaluatorConfig());
        bytes memory data = abi.encodeCall(market.updateTask, (taskId, REWARD + 5e6, 0, 0, 0));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        unreporting.relay(address(market), requester, data);
    }
}
