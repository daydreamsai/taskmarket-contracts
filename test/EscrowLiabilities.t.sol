// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TaskMarketForwarderV2.sol";
import "../src/interfaces/ITMPCore.sol";
import { ITMPEscrow } from "../src/interfaces/ITMPEscrow.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockUnreportingForwarder } from "./mocks/MockUnreportingForwarder.sol";
import { MockEscrowBugFacet } from "./mocks/MockEscrowBugFacet.sol";
import "./helpers/DiamondTestHelper.sol";
import "../src/interfaces/ITMPDiamond.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev rev026: booking, release, the solvency check, the per-task payout cap, unbooked
///      pre-rev026 tasks and the surplus sweep.
contract EscrowLiabilitiesTest is DiamondTestHelper {
    ITMPDiamond public market;
    MockEscrowBugFacet public bug;
    MockUnreportingForwarder public unreporting;
    TaskMarketForwarderV2 public v2;
    MockUSDC public usdc;

    address public owner = address(1);
    address public server = address(2);
    address public requester = address(3);
    address public worker = address(4);
    address public evaluator = address(6);
    address public feeRecipient = address(0xFEE);

    uint256 constant REWARD = 100e6;
    uint256 constant STAKE = 10e6;
    uint256 internal _n;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        unreporting = new MockUnreportingForwarder();
        v2 = new TaskMarketForwarderV2(address(usdc), address(market), server);
        market.addForwarder(address(unreporting));
        market.addForwarder(address(v2));

        MockEscrowBugFacet facet = new MockEscrowBugFacet();
        bytes4[] memory sels = new bytes4[](4);
        sels[0] = MockEscrowBugFacet.bugOverpay.selector;
        sels[1] = MockEscrowBugFacet.bugInflateReward.selector;
        sels[2] = MockEscrowBugFacet.bugUnbook.selector;
        sels[3] = MockEscrowBugFacet.bugSetLiabilitiesInitialised.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(facet), IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        vm.stopPrank();
        bug = MockEscrowBugFacet(address(market));

        usdc.mint(server, 10_000e6);
        vm.startPrank(server);
        usdc.approve(address(v2), type(uint256).max);
        vm.stopPrank();
    }

    function _relay(address fwd, address sender, uint256 amount, bytes memory data) internal {
        _n++;
        vm.prank(server);
        TaskMarketForwarderV2(fwd).relay(sender, amount, block.timestamp + 5 minutes, bytes32(_n), data);
    }

    function _createData(uint256 reward, ITMPCore.TaskEvaluatorConfig memory cfg) internal view returns (bytes memory) {
        return abi.encodeCall(
            market.createTask,
            (
                taskConfig(reward, 7 days, market.CLAIM(), 0, 0, bytes4(0)),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                stakeTerms(false, 0)
            )
        );
    }

    function _nextId() internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(market), requester, market.requesterNonce(requester)));
    }

    function _create() internal returns (bytes32 taskId) {
        taskId = _nextId();
        _relay(address(v2), requester, REWARD, _createData(REWARD, noEvaluatorConfig()));
    }

    function _booked(bytes32 taskId) internal view returns (uint256 booked) {
        (booked,) = market.escrowRecord(taskId);
    }

    // ---------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------

    function test_Create_BooksRewardAndEvaluatorStake() public {
        bytes32 taskId = _nextId();
        ITMPCore.TaskEvaluatorConfig memory cfg = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: STAKE,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: address(0)
        });
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPEscrow.EscrowFunded(taskId, requester, REWARD + STAKE, ITMPEscrow.Component.Task);
        _relay(address(v2), requester, REWARD + STAKE, _createData(REWARD, cfg));
        (uint256 booked, bool tracked) = market.escrowRecord(taskId);
        assertTrue(tracked);
        assertEq(booked, REWARD + STAKE);
        assertEq(market.totalLiabilities(), REWARD + STAKE);
    }

    function test_Create_UnreportedPayment_Reverts() public {
        // A forwarder that cannot report its payment is refused before anything is booked.
        bytes memory data = _createData(REWARD, noEvaluatorConfig());
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        unreporting.relay(address(market), requester, data);
    }

    function test_UpdateTask_UnreportedIncrease_Reverts() public {
        bytes32 taskId = _create();
        bytes memory data = abi.encodeCall(market.updateTask, (taskId, REWARD * 2, 0, 0, 0));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        unreporting.relay(address(market), requester, data);
    }

    function test_UpdateTask_IncreaseAndDecrease_BookAndRelease() public {
        bytes32 taskId = _create();
        _relay(address(v2), requester, REWARD, abi.encodeCall(market.updateTask, (taskId, REWARD * 2, 0, 0, 0)));
        assertEq(_booked(taskId), 2 * REWARD);
        _relay(address(v2), requester, 0, abi.encodeCall(market.updateTask, (taskId, REWARD / 2, 0, 0, 0)));
        assertEq(_booked(taskId), REWARD / 2);
        assertEq(market.totalLiabilities(), REWARD / 2);
        assertEq(usdc.balanceOf(address(market)), REWARD / 2);
    }

    function test_ClaimStake_Booked() public {
        bytes32 taskId = _create();
        usdc.mint(server, STAKE);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPEscrow.EscrowFunded(taskId, worker, STAKE, ITMPEscrow.Component.WorkerStake);
        _relay(address(v2), worker, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
        assertEq(_booked(taskId), REWARD + STAKE);
    }

    // ---------------------------------------------------------------------
    // Payouts
    // ---------------------------------------------------------------------

    function test_Cancel_ReleasesEverything() public {
        bytes32 taskId = _create();
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPEscrow.EscrowReleased(taskId, REWARD);
        _relay(address(v2), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(_booked(taskId), 0);
        assertEq(market.totalLiabilities(), 0);
    }

    function test_Payout_AboveWhatWasReleased_Reverts() public {
        bytes32 taskId = _create();
        _create();
        vm.expectRevert(abi.encodeWithSelector(ITMPEscrow.EscrowOverdrawn.selector, taskId, 1, 0));
        bug.bugOverpay(taskId, address(0xBAD), 1);
    }

    function test_Payout_LiabilityGrowsWithoutFunding_Reverts() public {
        bytes32 taskId = _create();
        vm.expectRevert(abi.encodeWithSelector(ITMPEscrow.EscrowMismatch.selector, taskId, REWARD + 1, REWARD));
        bug.bugInflateReward(taskId, 1);
    }

    function test_Payout_WhenPoolIsShort_Reverts() public {
        bytes32 taskId = _create();
        bytes32 other = _create();
        // Something outside every task's accounting took funds from the pool.
        deal(address(usdc), address(market), REWARD);
        bytes memory data = abi.encodeCall(market.cancelTask, (taskId, 0));
        vm.expectRevert(abi.encodeWithSelector(ITMPEscrow.EscrowInsolvent.selector, 0, REWARD));
        _relay(address(v2), requester, 0, data);
        assertEq(_booked(other), REWARD);
    }

    function test_UnbookedTask_PayoutReleasesNothing() public {
        bytes32 legacy = _create();
        bytes32 booked = _create();
        bug.bugUnbook(legacy);
        assertEq(market.totalLiabilities(), REWARD);

        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPEscrow.UnbookedRelease(legacy, REWARD);
        _relay(address(v2), requester, 0, abi.encodeCall(market.cancelTask, (legacy, 0)));
        assertEq(market.totalLiabilities(), REWARD);
        assertEq(_booked(booked), REWARD);
    }

    function test_UnbookedTask_FundingBooksNothing() public {
        bytes32 legacy = _create();
        bug.bugUnbook(legacy);
        usdc.mint(server, STAKE);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPEscrow.UnbookedFunding(legacy, worker, ITMPEscrow.Component.WorkerStake);
        _relay(address(v2), worker, STAKE, abi.encodeCall(market.claimTask, (legacy, STAKE)));
        (uint256 amount, bool tracked) = market.escrowRecord(legacy);
        assertEq(amount, 0);
        assertFalse(tracked);
    }

    // ---------------------------------------------------------------------
    // Surplus sweep
    // ---------------------------------------------------------------------

    function test_Sweep_SendsOnlySurplusToFeeRecipient() public {
        _create();
        usdc.mint(address(market), 7e6);
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPEscrow.SurplusSwept(feeRecipient, 7e6);
        vm.prank(owner);
        market.sweepSurplus();
        assertEq(usdc.balanceOf(feeRecipient), 7e6);
        assertEq(usdc.balanceOf(address(market)), REWARD);
    }

    function test_Sweep_WhenPoolIsShort_RevertsInsolvent() public {
        _create();
        deal(address(usdc), address(market), REWARD - 1);
        vm.expectRevert(abi.encodeWithSelector(ITMPEscrow.EscrowInsolvent.selector, REWARD - 1, REWARD));
        vm.prank(owner);
        market.sweepSurplus();
    }

    function test_Sweep_OwnerOnly() public {
        vm.expectRevert();
        vm.prank(requester);
        market.sweepSurplus();
    }

    function test_Sweep_ClosedUntilLiabilitiesInitialised() public {
        assertTrue(market.liabilitiesInitialised());
        bug.bugSetLiabilitiesInitialised(false);
        vm.expectRevert(ITMPEscrow.LiabilitiesNotInitialised.selector);
        vm.prank(owner);
        market.sweepSurplus();
    }

    function test_UnbookedTask_UnreportedIncrease_Reverts() public {
        bytes32 legacy = _create();
        bug.bugUnbook(legacy);
        bytes memory data = abi.encodeCall(market.updateTask, (legacy, REWARD * 2, 0, 0, 0));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        unreporting.relay(address(market), requester, data);
    }
}
