// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import {
    TMP_CLAIM,
    TMP_PITCH,
    TMP_AUCTION,
    TMP_AUCTION_DUTCH,
    TMP_AUCTION_ENGLISH,
    TMP_BOUNTY,
    TMP_BENCHMARK
} from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev025 frozen terms: once a worker is committed (claimed, selected, accepted auction) or a
///      Bounty or Benchmark submission is active, updateTask and assignEvaluator revert
///      TermsFrozen. A bid alone commits no one, and a reopened claim task is editable again.
contract FreezeTermsTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant PRICE = 60e6;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant INCREASE = 20e6;
    uint256 internal constant DECREASE = 30e6;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, uint16(500));
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _create(bytes4 mode, bytes4 subtype) internal returns (bytes32) {
        ITMPCore.TaskConfig memory cfg = mode == TMP_PITCH
            ? taskConfig(REWARD, DURATION, mode, 1 days, 0, bytes4(0))
            : mode == TMP_AUCTION
                ? taskConfig(REWARD, DURATION, mode, 0, 1 days, subtype)
                : taskConfig(REWARD, DURATION, mode);
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                cfg,
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0)
            )
        );
        return abi.decode(_relay(requester, REWARD, data), (bytes32));
    }

    function _claimed() internal returns (bytes32 taskId) {
        taskId = _create(TMP_CLAIM, bytes4(0));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Claimed));
    }

    function _pitchSelected() internal returns (bytes32 taskId) {
        taskId = _create(TMP_PITCH, bytes4(0));
        _relay(worker, 0, abi.encodeCall(market.submitPitch, (taskId, keccak256("pitch"))));
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.WorkerSelected));
    }

    function _dutchAccepted() internal returns (bytes32 taskId) {
        taskId = _create(TMP_AUCTION, TMP_AUCTION_DUTCH);
        _relay(worker, 0, abi.encodeCall(market.acceptAuction, (taskId, PRICE)));
        assertEq(market.getTask(taskId).worker, worker);
    }

    function _englishBid(bytes32 taskId) internal {
        _relay(worker, 0, abi.encodeCall(market.submitBid, (taskId, PRICE)));
    }

    function _englishSelected() internal returns (bytes32 taskId) {
        taskId = _create(TMP_AUCTION, TMP_AUCTION_ENGLISH);
        _englishBid(taskId);
        vm.warp(market.getTaskAuctionConfig(taskId).bidDeadline);
        _relay(address(0), 0, abi.encodeCall(market.selectLowestBidder, (taskId)));
        assertEq(market.getTask(taskId).worker, worker);
    }

    function _submitted(bytes4 mode) internal returns (bytes32 taskId) {
        taskId = _create(mode, bytes4(0));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Open));
    }

    function _updateData(bytes32 taskId, uint256 reward, uint256 expiry, uint256 bidDl, uint256 pitchDl)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(market.updateTask, (taskId, reward, expiry, bidDl, pitchDl));
    }

    function _assignData(bytes32 taskId) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), address(0))
            );
    }

    function _expectFrozen(uint256 payment, bytes memory data) internal {
        vm.expectRevert(ITMPCore.TermsFrozen.selector);
        forwarder.relay(address(market), requester, payment, data);
    }

    /// @dev Every edit path reverts TermsFrozen: reward increase (with the exact forwarded
    ///      payment), reward decrease, expiry, the mode's deadline, and assignEvaluator.
    function _assertAllFrozen(bytes32 taskId) internal {
        uint256 reward = market.getTask(taskId).reward;
        uint256 later = block.timestamp + 2 days;
        _expectFrozen(INCREASE, _updateData(taskId, reward + INCREASE, 0, 0, 0));
        _expectFrozen(0, _updateData(taskId, reward - DECREASE, 0, 0, 0));
        _expectFrozen(0, _updateData(taskId, 0, block.timestamp + DURATION * 2, 0, 0));
        _expectFrozen(0, _updateData(taskId, 0, 0, later, 0));
        _expectFrozen(0, _updateData(taskId, 0, 0, 0, later));
        _expectFrozen(0, _assignData(taskId));
    }

    /// @dev Every edit path succeeds on an open task with no committed worker.
    function _assertEditable(bytes32 taskId) internal {
        uint256 reward = market.getTask(taskId).reward;
        _relay(requester, INCREASE, _updateData(taskId, reward + INCREASE, 0, 0, 0));
        assertEq(market.getTask(taskId).reward, reward + INCREASE);
        _relay(requester, 0, _updateData(taskId, reward + INCREASE - DECREASE, 0, 0, 0));
        assertEq(market.getTask(taskId).reward, reward + INCREASE - DECREASE);
        uint256 newExpiry = block.timestamp + DURATION * 2;
        _relay(requester, 0, _updateData(taskId, 0, newExpiry, 0, 0));
        assertEq(market.getTask(taskId).expiryTime, newExpiry);
        _relay(requester, 0, _assignData(taskId));
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, evaluator);
    }

    // -------------------------------------------------------------------------
    // Frozen once committed
    // -------------------------------------------------------------------------

    function test_RevertWhen_Claim_Claimed_TermsFrozen() public {
        _assertAllFrozen(_claimed());
    }

    function test_RevertWhen_Pitch_WorkerSelected_TermsFrozen() public {
        _assertAllFrozen(_pitchSelected());
    }

    function test_RevertWhen_Auction_DutchAccepted_TermsFrozen() public {
        _assertAllFrozen(_dutchAccepted());
    }

    function test_RevertWhen_Auction_LowestBidderSelected_TermsFrozen() public {
        _assertAllFrozen(_englishSelected());
    }

    function test_RevertWhen_Bounty_ActiveSubmission_TermsFrozen() public {
        _assertAllFrozen(_submitted(TMP_BOUNTY));
    }

    function test_RevertWhen_Benchmark_ActiveSubmission_TermsFrozen() public {
        _assertAllFrozen(_submitted(TMP_BENCHMARK));
    }

    // -------------------------------------------------------------------------
    // Editable again after reopen; open control cases
    // -------------------------------------------------------------------------

    function test_Claim_Open_Editable() public {
        _assertEditable(_create(TMP_CLAIM, bytes4(0)));
    }

    function test_Claim_ReopenedByForfeit_Editable() public {
        bytes32 taskId = _claimed();
        vm.warp(market.getTask(taskId).expiryTime + 1);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open));
        assertEq(task.worker, address(0));
        _assertEditable(taskId);
    }

    function test_Claim_ReopenedByRelease_Editable() public {
        bytes32 taskId = _claimed();
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (taskId)));
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint8(task.status), uint8(ITMPCore.TaskStatus.Open));
        assertEq(task.worker, address(0));
        _assertEditable(taskId);
    }

    // -------------------------------------------------------------------------
    // A bid alone does not freeze terms
    // -------------------------------------------------------------------------

    function test_Auction_BidOnly_AssignEvaluatorSucceeds() public {
        bytes32 taskId = _create(TMP_AUCTION, TMP_AUCTION_ENGLISH);
        _englishBid(taskId);
        _relay(requester, 0, _assignData(taskId));
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, evaluator);
    }

    function test_RevertWhen_Auction_BidOnly_UpdateTask_BidsExist() public {
        bytes32 taskId = _create(TMP_AUCTION, TMP_AUCTION_ENGLISH);
        _englishBid(taskId);
        vm.expectRevert(ITMPCore.BidsExist.selector);
        forwarder.relay(address(market), requester, 0, _updateData(taskId, 0, block.timestamp + DURATION * 2, 0, 0));
    }

    // -------------------------------------------------------------------------
    // Terminal tasks still report TaskNotOpen
    // -------------------------------------------------------------------------

    function test_RevertWhen_Cancelled_TaskNotOpen() public {
        bytes32 taskId = _create(TMP_CLAIM, bytes4(0));
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(address(market), requester, 0, _updateData(taskId, 0, block.timestamp + DURATION * 2, 0, 0));
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(address(market), requester, 0, _assignData(taskId));
    }
}
