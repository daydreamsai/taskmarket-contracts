// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MockUnreportingForwarder } from "./mocks/MockUnreportingForwarder.sol";
import "../src/TaskMarketForwarderV2.sol";
import "../src/interfaces/IPGTRForwarder.sol";
import "../src/interfaces/IPGTRPaymentForwarder.sol";
import "../src/interfaces/ITMPCore.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import "./helpers/DiamondTestHelper.sol";
import "../src/interfaces/ITMPDiamond.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev Relay target that records pgtrPaymentAmount() mid-call and tries to re-enter relay().
contract PaymentProbe {
    TaskMarketForwarderV2 public forwarder;
    uint256 public seenAmount;
    address public seenSender;
    bool public reentryBlocked;

    function setForwarder(TaskMarketForwarderV2 f) external {
        forwarder = f;
    }

    function start(address sender, uint256 amount) external {
        forwarder.relay(sender, amount, block.timestamp + 1, keccak256("probe"), abi.encodeCall(this.probe, ()));
    }

    function probe() external {
        seenAmount = forwarder.pgtrPaymentAmount();
        seenSender = forwarder.pgtrSender();
        bytes memory data = abi.encodeCall(this.probe, ());
        uint256 validBefore = block.timestamp + 1;
        try forwarder.relay(address(this), 0, validBefore, keccak256("again"), data) { }
        catch (bytes memory reason) {
            reentryBlocked = bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        }
    }
}

/// @dev Claims to be a forwarder reporting any amount; never registered with the diamond.
contract SpoofForwarder {
    function pgtrSender() external view returns (address) {
        return tx.origin;
    }

    function pgtrPaymentAmount() external pure returns (uint256) {
        return 1e12;
    }

    function claim(ITMPDiamond market, bytes32 taskId, uint256 stake) external {
        market.claimTask(taskId, stake);
    }
}

contract TaskMarketForwarderV2Test is DiamondTestHelper {
    ITMPDiamond public market;
    MockUnreportingForwarder public unreporting;
    TaskMarketForwarderV2 public v2;
    MockUSDC public usdc;

    address public owner = address(1);
    address public server = address(2);
    address public requester = address(3);
    address public worker = address(4);
    address public attacker = address(5);

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

    function _relay(address fwd, address sender, uint256 amount, bytes memory data) internal {
        _n++;
        vm.prank(server);
        TaskMarketForwarderV2(fwd).relay(sender, amount, block.timestamp + 5 minutes, bytes32(_n), data);
    }

    function _createClaimTask(address fwd) internal returns (bytes32 taskId) {
        uint256 nonce = market.requesterNonce(requester);
        taskId = keccak256(abi.encode(block.chainid, address(market), requester, nonce));
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, market.CLAIM(), 0, 0, bytes4(0)),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0)
            )
        );
        _relay(fwd, requester, REWARD, data);
    }

    function _claim(address fwd, bytes32 taskId, uint256 paid, uint256 stake) internal {
        _relay(fwd, worker, paid, abi.encodeCall(market.claimTask, (taskId, stake)));
    }

    // ---------------------------------------------------------------------
    // pgtrPaymentAmount exposure
    // ---------------------------------------------------------------------

    function test_ERC165_PaymentForwarder() public view {
        assertTrue(v2.supportsInterface(type(IPGTRPaymentForwarder).interfaceId));
        assertTrue(v2.supportsInterface(type(IPGTRForwarder).interfaceId));
        assertTrue(v2.supportsInterface(type(IERC165).interfaceId));
    }

    function test_PaymentAmount_Reverts_OutsideRelay() public {
        vm.expectRevert(TaskMarketForwarderV2.NoActiveForwardedCall.selector);
        v2.pgtrPaymentAmount();
    }

    function test_PaymentAmount_SetDuringRelay_ResetAfter_ReentryBlocked() public {
        PaymentProbe probe = new PaymentProbe();
        TaskMarketForwarderV2 f = new TaskMarketForwarderV2(address(usdc), address(probe), address(probe));
        probe.setForwarder(f);
        usdc.mint(address(probe), STAKE);
        vm.prank(address(probe));
        usdc.approve(address(f), STAKE);

        probe.start(worker, STAKE);

        assertEq(probe.seenAmount(), STAKE);
        assertEq(probe.seenSender(), worker);
        assertTrue(probe.reentryBlocked());
        vm.expectRevert(TaskMarketForwarderV2.NoActiveForwardedCall.selector);
        f.pgtrPaymentAmount();
        vm.expectRevert(TaskMarketForwarderV2.NoActiveForwardedCall.selector);
        f.pgtrSender();
    }

    // ---------------------------------------------------------------------
    // claimTask through v2
    // ---------------------------------------------------------------------

    function test_V2_Claim_MatchingStake_Records() public {
        bytes32 taskId = _createClaimTask(address(v2));
        uint256 before = usdc.balanceOf(address(market));
        _claim(address(v2), taskId, STAKE, STAKE);
        assertEq(market.getTask(taskId).stakeAmount, STAKE);
        assertEq(market.getTask(taskId).worker, worker);
        assertEq(usdc.balanceOf(address(market)), before + STAKE);
    }

    function test_V2_Claim_ZeroStake_ZeroPayment() public {
        bytes32 taskId = _createClaimTask(address(v2));
        _claim(address(v2), taskId, 0, 0);
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Claimed));
    }

    function test_V2_Claim_PaymentBelowStake_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _claim(address(v2), taskId, STAKE - 1, STAKE);
    }

    function test_V2_Claim_PaymentAboveStake_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _claim(address(v2), taskId, STAKE + 1, STAKE);
    }

    function test_V2_Claim_StakeWithoutPayment_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _claim(address(v2), taskId, 0, STAKE);
    }

    function test_V2_Claim_PaymentWithZeroStake_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _claim(address(v2), taskId, STAKE, 0);
    }

    function testFuzz_V2_Claim_Mismatch_Reverts(uint64 paid, uint64 stake) public {
        vm.assume(paid != stake && paid <= 1_000 * 10 ** 6);
        bytes32 taskId = _createClaimTask(address(v2));
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        _claim(address(v2), taskId, paid, stake);
    }

    // ---------------------------------------------------------------------
    // A forwarder that cannot report its payment
    // ---------------------------------------------------------------------

    function test_Unreported_UnstakedClaim_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        bytes memory data = abi.encodeCall(market.claimTask, (taskId, 0));
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        unreporting.relay(address(market), worker, data);
    }

    function test_Unreported_StakedClaim_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        bytes memory data = abi.encodeCall(market.claimTask, (taskId, STAKE));
        vm.expectRevert(ITMPCore.StakePaymentMismatch.selector);
        unreporting.relay(address(market), worker, data);
    }

    // ---------------------------------------------------------------------
    // Receipts: replay and expiry
    // ---------------------------------------------------------------------

    function _createData() internal view returns (bytes memory) {
        return abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, market.CLAIM(), 0, 0, bytes4(0)),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0)
            )
        );
    }

    function test_Relay_Replay_Reverts() public {
        bytes memory data = _createData();
        uint256 validBefore = block.timestamp + 5 minutes;
        vm.prank(server);
        v2.relay(requester, REWARD, validBefore, bytes32(uint256(99)), data);

        vm.prank(server);
        vm.expectRevert(TaskMarketForwarderV2.ReceiptAlreadyConsumed.selector);
        v2.relay(requester, REWARD, validBefore, bytes32(uint256(99)), data);
    }

    function test_ConsumedReceipts_Stored() public {
        uint256 validBefore = block.timestamp + 5 minutes;
        bytes32 nonce = bytes32(uint256(100));
        bytes32 receiptHash = keccak256(
            abi.encode(
                block.chainid, requester, REWARD, nonce, validBefore, address(market), market.createTask.selector
            )
        );
        assertFalse(v2.consumedReceipts(receiptHash));

        bytes memory data = _createData();
        vm.prank(server);
        v2.relay(requester, REWARD, validBefore, nonce, data);
        assertTrue(v2.consumedReceipts(receiptHash));
    }

    function test_Relay_Expired_Reverts() public {
        bytes memory data = _createData();
        uint256 expiredBefore = block.timestamp - 1;
        vm.prank(server);
        vm.expectRevert(TaskMarketForwarderV2.ReceiptExpired.selector);
        v2.relay(requester, REWARD, expiredBefore, bytes32(uint256(200)), data);
    }

    function test_Relay_ExactlyAtDeadline_Succeeds() public {
        // validBefore == block.timestamp is still valid (inclusive check).
        bytes memory data = _createData();
        vm.prank(server);
        v2.relay(requester, REWARD, block.timestamp, bytes32(uint256(201)), data);
    }

    /// @dev The backend derives the same hash (apps/backend/src/services/relay-receipt.ts) to
    ///      detect a consumed receipt, so the encoding must not change.
    function test_ReceiptHash_DerivationIsFrozen() public pure {
        bytes32 receiptHash = keccak256(
            abi.encode(
                uint256(8453),
                address(0x1111111111111111111111111111111111111111),
                uint256(1_000_000),
                bytes32(0x2222222222222222222222222222222222222222222222222222222222222222),
                uint256(1_786_029_192),
                address(0x3333333333333333333333333333333333333333),
                bytes4(0xdeadbeef)
            )
        );
        assertEq(receiptHash, 0x99ba1fdf70fbfe86a31d2b8e6461b405640c9d5e677c31a0cd24c980cb1782d1);
    }

    // ---------------------------------------------------------------------
    // Spoofing
    // ---------------------------------------------------------------------

    function test_DirectCall_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        vm.prank(attacker);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.claimTask(taskId, STAKE);
    }

    function test_UnregisteredForwarder_CannotSpoofAmount() public {
        bytes32 taskId = _createClaimTask(address(v2));
        SpoofForwarder spoof = new SpoofForwarder();
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        spoof.claim(market, taskId, STAKE);
    }

    function test_UnauthorizedRelayer_Reverts() public {
        bytes32 taskId = _createClaimTask(address(v2));
        vm.prank(attacker);
        vm.expectRevert(TaskMarketForwarderV2.UnauthorizedRelayer.selector);
        bytes memory data = abi.encodeCall(market.claimTask, (taskId, STAKE));
        v2.relay(attacker, 0, block.timestamp + 1, bytes32(uint256(99)), data);
    }
}
