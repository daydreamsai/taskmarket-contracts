// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPEvaluator } from "../src/interfaces/ITMPEvaluator.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { TMP_CLAIM, TMP_AUCTION, TMP_AUCTION_DUTCH, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @title StakeSettlementTest
/// @dev Every path that ends a task must pay out what the diamond holds for it. Each test runs one
///      task to a terminal state on a fresh diamond and checks the diamond's balance ends at zero,
///      alongside the exact payout to each party.
contract StakeSettlementTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xD0);
    address internal resolver = address(0xE0);

    uint16 internal constant PLATFORM_FEE_BPS = 500;
    uint16 internal constant EVAL_FEE_BPS = 1000;
    uint256 internal constant REWARD = 100e6;
    uint256 internal constant CLAIM_STAKE = 10e6;
    uint256 internal constant EVAL_STAKE = 5e6;
    uint256 internal constant DURATION = 7 days;
    uint32 internal constant EVAL_WINDOW = 2 days;
    uint32 internal constant APPEAL_WINDOW = 1 days;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, PLATFORM_FEE_BPS);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();

        usdc.mint(address(forwarder), 10_000e6);
        usdc.mint(requester, 1_000e6);
        vm.prank(requester);
        usdc.approve(address(market), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _evalConfig(uint256 stake, address dr) internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: stake,
            evaluatorFeeBps: EVAL_FEE_BPS,
            evaluationWindow: EVAL_WINDOW,
            appealWindow: APPEAL_WINDOW,
            disputeResolver: dr
        });
    }

    function _create(ITMPCore.TaskConfig memory config, ITMPCore.TaskEvaluatorConfig memory evalCfg)
        internal
        returns (bytes32)
    {
        return abi.decode(
            _relay(
                requester,
                config.reward + evalCfg.evaluatorStake,
                abi.encodeCall(
                    market.createTask,
                    (
                        config,
                        ITMPCore.StakeConfig({ required: false, bps: 0 }),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        evalCfg
                    )
                )
            ),
            (bytes32)
        );
    }

    /// @dev Claim task with an evaluator, claimed with a stake and submitted, so it sits in Review.
    function _claimToReview(address dr) internal returns (bytes32 taskId) {
        taskId = _create(taskConfig(REWARD, DURATION, TMP_CLAIM), _evalConfig(0, dr));
        _relay(worker, CLAIM_STAKE, abi.encodeCall(market.claimTask, (taskId, CLAIM_STAKE)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function _award(uint256 amount) internal view returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: amount, rank: 1 });
    }

    function _evaluate(bytes32 taskId, ITMPCore.VerdictType verdict, ITMPCore.Award[] memory awards) internal {
        _relay(evaluator, 0, abi.encodeCall(market.evaluate, (taskId, verdict, 900, 1000, bytes32(0), awards)));
    }

    function _assertDiamondEmpty() internal view {
        assertEq(usdc.balanceOf(address(market)), 0, "diamond must hold nothing once its only task ends");
    }

    // -------------------------------------------------------------------------
    // Claim stake on evaluator settlement
    // -------------------------------------------------------------------------

    function test_FinalizeVerdict_Approve_ReturnsClaimStake() public {
        bytes32 taskId = _claimToReview(address(0));
        uint256 evalFee = (REWARD * EVAL_FEE_BPS) / 10000;
        uint256 award = REWARD - evalFee;
        _evaluate(taskId, ITMPCore.VerdictType.APPROVE, _award(award));
        vm.warp(block.timestamp + APPEAL_WINDOW);

        uint256 workerBefore = usdc.balanceOf(worker);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeReturned(taskId, worker, CLAIM_STAKE);
        market.finalizeVerdict(taskId);

        uint256 platformFee = (award * PLATFORM_FEE_BPS) / 10000;
        assertEq(usdc.balanceOf(worker), workerBefore + award - platformFee + CLAIM_STAKE, "award net plus stake");
        assertEq(market.getTask(taskId).stakeAmount, 0, "stake settled exactly once");
        _assertDiamondEmpty();
    }

    function test_FinalizeVerdict_Partial_ReturnsClaimStakeAndRefundsRemainder() public {
        bytes32 taskId = _claimToReview(address(0));
        uint256 award = 40e6;
        _evaluate(taskId, ITMPCore.VerdictType.PARTIAL, _award(award));
        vm.warp(block.timestamp + APPEAL_WINDOW);

        uint256 workerBefore = usdc.balanceOf(worker);
        market.finalizeVerdict(taskId);

        uint256 platformFee = (award * PLATFORM_FEE_BPS) / 10000;
        assertEq(usdc.balanceOf(worker), workerBefore + award - platformFee + CLAIM_STAKE);
        _assertDiamondEmpty();
    }

    function test_FinalizeVerdict_Reject_ForfeitsClaimStakeToRequester() public {
        bytes32 taskId = _claimToReview(address(0));
        _evaluate(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));
        vm.warp(block.timestamp + APPEAL_WINDOW);

        uint256 workerBefore = usdc.balanceOf(worker);
        uint256 requesterBefore = usdc.balanceOf(requester);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeForfeited(taskId, worker, CLAIM_STAKE);
        market.finalizeVerdict(taskId);

        uint256 evalFee = (REWARD * EVAL_FEE_BPS) / 10000;
        assertEq(usdc.balanceOf(worker), workerBefore, "rejected worker forfeits the stake");
        assertEq(
            usdc.balanceOf(requester), requesterBefore + REWARD - evalFee + CLAIM_STAKE, "refund plus forfeited stake"
        );
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore, "verdict forfeits go to the requester");
        assertEq(market.getTask(taskId).stakeAmount, 0, "stake settled exactly once");
        assertEq(RegistryFacet(address(market)).stakeForfeit(taskId), CLAIM_STAKE, "forfeit recorded");
        _assertDiamondEmpty();
    }

    function test_FinalizeVerdict_ZeroAward_ForfeitsClaimStake() public {
        bytes32 taskId = _claimToReview(address(0));
        _evaluate(taskId, ITMPCore.VerdictType.PARTIAL, _award(0));
        vm.warp(block.timestamp + APPEAL_WINDOW);

        uint256 workerBefore = usdc.balanceOf(worker);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeForfeited(taskId, worker, CLAIM_STAKE);
        market.finalizeVerdict(taskId);

        assertEq(usdc.balanceOf(worker), workerBefore, "a verdict that awards nothing forfeits the stake");
        _assertDiamondEmpty();
    }

    function test_ResolveDispute_AgainstWorker_ForfeitsClaimStake() public {
        bytes32 taskId = _claimToReview(resolver);
        _evaluate(taskId, ITMPCore.VerdictType.PARTIAL, _award(10e6));
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));

        uint256 workerBefore = usdc.balanceOf(worker);
        uint256 requesterBefore = usdc.balanceOf(requester);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeForfeited(taskId, worker, CLAIM_STAKE);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, _award(0));

        assertEq(usdc.balanceOf(worker), workerBefore, "resolved against the worker");
        assertEq(usdc.balanceOf(evaluator), 0, "an overturned verdict earns no fee");
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD + CLAIM_STAKE);
        _assertDiamondEmpty();
    }

    function test_ResolveDispute_ReturnsClaimStake() public {
        bytes32 taskId = _claimToReview(resolver);
        _evaluate(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));

        uint256 award = 50e6;
        uint256 workerBefore = usdc.balanceOf(worker);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeReturned(taskId, worker, CLAIM_STAKE);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, _award(award));

        uint256 platformFee = (award * PLATFORM_FEE_BPS) / 10000;
        assertEq(usdc.balanceOf(worker), workerBefore + award - platformFee + CLAIM_STAKE);
        _assertDiamondEmpty();
    }

    // -------------------------------------------------------------------------
    // Evaluator stake on cancel
    // -------------------------------------------------------------------------

    function test_CancelTask_RefundsEvaluatorStakeToRequester() public {
        uint256 requesterStart = usdc.balanceOf(requester);
        bytes32 taskId = _create(taskConfig(REWARD, DURATION, TMP_CLAIM), _evalConfig(EVAL_STAKE, address(0)));
        assertEq(usdc.balanceOf(requester), requesterStart, "stake arrives with the forwarded payment");

        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPEvaluator.EvaluatorStakeRefunded(taskId, requester, EVAL_STAKE);
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));

        assertEq(
            usdc.balanceOf(requester), requesterStart + REWARD + EVAL_STAKE, "reward and evaluator stake both returned"
        );
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, 0, "stake settled exactly once");
        _assertDiamondEmpty();
    }

    function test_CancelTask_WithoutEvaluatorStake_EmitsNoStakeRefund() public {
        bytes32 taskId = _create(taskConfig(REWARD, DURATION, TMP_CLAIM), noEvaluatorConfig());
        vm.recordLogs();
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != ITMPEvaluator.EvaluatorStakeRefunded.selector, "no stake, no refund event");
        }
        _assertDiamondEmpty();
    }

    // -------------------------------------------------------------------------
    // Appeal needs a dispute resolver
    // -------------------------------------------------------------------------

    function test_RevertWhen_Appeal_NoDisputeResolver() public {
        bytes32 taskId = _claimToReview(address(0));
        _evaluate(taskId, ITMPCore.VerdictType.PARTIAL, _award(40e6));

        vm.expectRevert(ITMPCore.NoDisputeResolver.selector);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
    }

    function test_Appeal_NoDisputeResolver_VerdictStillFinalizes() public {
        bytes32 taskId = _claimToReview(address(0));
        uint256 award = 40e6;
        _evaluate(taskId, ITMPCore.VerdictType.PARTIAL, _award(award));

        vm.expectRevert(ITMPCore.NoDisputeResolver.selector);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));

        vm.warp(block.timestamp + APPEAL_WINDOW);
        uint256 workerBefore = usdc.balanceOf(worker);
        market.finalizeVerdict(taskId);
        assertEq(
            usdc.balanceOf(worker),
            workerBefore + award - (award * PLATFORM_FEE_BPS) / 10000 + CLAIM_STAKE,
            "the evaluator's award is paid, not lost to an unresolvable dispute"
        );
        _assertDiamondEmpty();
    }

    function test_Appeal_WithDisputeResolver_EmitsDisputed() public {
        bytes32 taskId = _claimToReview(resolver);
        _evaluate(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));

        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPEvaluator.TaskDisputed(taskId, resolver);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Disputed));
    }

    // -------------------------------------------------------------------------
    // Auction evaluator fee on the settled price
    // -------------------------------------------------------------------------

    function _auctionToReview(uint256 price) internal returns (bytes32 taskId) {
        taskId = _create(
            taskConfig(REWARD, DURATION, TMP_AUCTION, 0, 1 days, TMP_AUCTION_DUTCH), _evalConfig(0, address(0))
        );
        _relay(worker, 0, abi.encodeCall(market.acceptAuction, (taskId, price)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function test_Auction_EvaluatorFee_ChargedOnSettledPrice() public {
        uint256 price = 40e6;
        bytes32 taskId = _auctionToReview(price);

        uint256 evalBefore = usdc.balanceOf(evaluator);
        _evaluate(taskId, ITMPCore.VerdictType.APPROVE, _award(price));
        assertEq(usdc.balanceOf(evaluator), evalBefore, "fee held until the verdict is final");
        assertEq(usdc.balanceOf(address(market)), REWARD);

        vm.warp(block.timestamp + APPEAL_WINDOW);
        uint256 requesterBefore = usdc.balanceOf(requester);
        uint256 workerBefore = usdc.balanceOf(worker);
        market.finalizeVerdict(taskId);

        uint256 evalFee = (price * EVAL_FEE_BPS) / 10000;
        assertEq(usdc.balanceOf(evaluator), evalBefore + evalFee, "fee on the 40 price, not the 100 cap");
        assertEq(usdc.balanceOf(worker), workerBefore + price - (price * PLATFORM_FEE_BPS) / 10000);
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD - evalFee - price, "refund grows with the fee");
        _assertDiamondEmpty();
    }

    function test_Auction_RefundExpiredAfterVerdict_FinalizesReject() public {
        uint256 price = 40e6;
        bytes32 taskId = _auctionToReview(price);
        _evaluate(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));

        vm.warp(market.getTask(taskId).expiryTime + 1);
        uint256 requesterBefore = usdc.balanceOf(requester);
        uint256 evalBefore = usdc.balanceOf(evaluator);
        market.refundExpired(taskId, 0);

        uint256 evalFee = (price * EVAL_FEE_BPS) / 10000;
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Cancelled), "verdict applied");
        assertEq(usdc.balanceOf(evaluator), evalBefore + evalFee, "fee on the settled price");
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD - evalFee);
        _assertDiamondEmpty();
    }

    // -------------------------------------------------------------------------
    // Deferred evaluator fee
    // -------------------------------------------------------------------------

    uint256 internal constant EVAL_FEE = (REWARD * EVAL_FEE_BPS) / 10000;

    function _bountyToEvaluated(ITMPCore.VerdictType verdict, uint256 award) internal returns (bytes32 taskId) {
        taskId = _create(taskConfig(REWARD, DURATION, TMP_BOUNTY), _evalConfig(0, resolver));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _evaluate(taskId, verdict, award == 0 ? new ITMPCore.Award[](0) : _award(award));
        assertEq(usdc.balanceOf(evaluator), 0, "evaluate pays no fee");
        assertEq(usdc.balanceOf(address(market)), REWARD, "fee stays in escrow");
    }

    function _net(uint256 amount) internal pure returns (uint256) {
        return amount - (amount * PLATFORM_FEE_BPS) / 10000;
    }

    function test_EvalFee_FinalizeApprove_PaysEvaluatorAfterWindow() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.APPROVE, REWARD - EVAL_FEE);
        vm.expectRevert(ITMPCore.AppealWindowStillOpen.selector);
        market.finalizeVerdict(taskId);

        vm.warp(block.timestamp + APPEAL_WINDOW);
        uint256 requesterBefore = usdc.balanceOf(requester);
        market.finalizeVerdict(taskId);

        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(usdc.balanceOf(worker), _net(REWARD - EVAL_FEE));
        assertEq(usdc.balanceOf(requester), requesterBefore);
        _assertDiamondEmpty();
    }

    function test_EvalFee_FinalizeReject_PaysEvaluatorAfterWindow() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.REJECT, 0);
        vm.warp(block.timestamp + APPEAL_WINDOW);
        uint256 requesterBefore = usdc.balanceOf(requester);
        market.finalizeVerdict(taskId);

        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD - EVAL_FEE);
        _assertDiamondEmpty();
    }

    function test_EvalFee_ExpiryWithOpenWindow_RevertsApprove() public {
        _assertOpenWindowReverts(ITMPCore.VerdictType.APPROVE, REWARD - EVAL_FEE);
    }

    function test_EvalFee_ExpiryWithOpenWindow_RevertsReject() public {
        _assertOpenWindowReverts(ITMPCore.VerdictType.REJECT, 0);
    }

    function _assertOpenWindowReverts(ITMPCore.VerdictType verdict, uint256 award) internal {
        bytes32 taskId = _bountyToEvaluated(verdict, award);
        vm.expectRevert(ITMPCore.AppealWindowStillOpen.selector);
        market.refundExpired(taskId, 0);
        assertEq(usdc.balanceOf(address(market)), REWARD, "nothing moves");
        assertEq(usdc.balanceOf(evaluator), 0);
    }

    function test_EvalFee_ExpiryAfterWindow_SettlesApprove() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.APPROVE, REWARD - EVAL_FEE);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        uint256 requesterBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(usdc.balanceOf(worker), _net(REWARD - EVAL_FEE));
        assertEq(usdc.balanceOf(requester), requesterBefore);
        _assertDiamondEmpty();
    }

    function test_EvalFee_ExpiryAfterWindow_SettlesReject() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.REJECT, 0);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        uint256 requesterBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Cancelled));
        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD - EVAL_FEE);
        _assertDiamondEmpty();
    }

    function test_EvalFee_UnresolvedDisputeAtExpiry_ApproveStands() public {
        uint256 award = REWARD - EVAL_FEE;
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.APPROVE, award);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);

        vm.warp(market.getTask(taskId).expiryTime + 1);
        uint256 requesterBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(usdc.balanceOf(worker), _net(award));
        assertEq(usdc.balanceOf(requester), requesterBefore);
        _assertDiamondEmpty();
    }

    function test_EvalFee_UnresolvedDisputeAtExpiry_RejectStands() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.REJECT, 0);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));

        vm.warp(market.getTask(taskId).expiryTime + 1);
        uint256 requesterBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Cancelled));
        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(usdc.balanceOf(worker), 0);
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD - EVAL_FEE);
        _assertDiamondEmpty();
    }

    function test_EvalFee_ResolverBeforeExpiry_Wins() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.REJECT, 0);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        vm.warp(market.getTask(taskId).expiryTime);
        uint256 award = REWARD - EVAL_FEE;
        uint256 requesterBefore = usdc.balanceOf(requester);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _award(award));

        vm.warp(block.timestamp + 1);
        vm.expectRevert(ITMPCore.TaskAlreadyAccepted.selector);
        market.refundExpired(taskId, 0);
        assertEq(usdc.balanceOf(evaluator), 0);
        assertEq(usdc.balanceOf(worker), _net(award));
        assertEq(usdc.balanceOf(requester), requesterBefore + EVAL_FEE);
        _assertDiamondEmpty();
    }

    function test_EvalFee_DisputeUpheld_PaysEvaluator() public {
        uint256 award = REWARD - EVAL_FEE;
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.APPROVE, award);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(usdc.balanceOf(address(market)), REWARD);

        uint256 requesterBefore = usdc.balanceOf(requester);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _award(award));

        assertEq(usdc.balanceOf(evaluator), EVAL_FEE);
        assertEq(usdc.balanceOf(worker), _net(award));
        assertEq(usdc.balanceOf(requester), requesterBefore);
        _assertDiamondEmpty();
    }

    function test_EvalFee_DisputeOverturnsApprove_FeeToRequester() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.APPROVE, REWARD - EVAL_FEE);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));

        uint256 award = 30e6;
        uint256 requesterBefore = usdc.balanceOf(requester);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, _award(award));

        assertEq(usdc.balanceOf(evaluator), 0, "an overturned verdict earns no fee");
        assertEq(usdc.balanceOf(worker), _net(award));
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD - EVAL_FEE - award + EVAL_FEE);
        _assertDiamondEmpty();
    }

    function test_EvalFee_DisputeOverturnsReject_FeeToRequester() public {
        bytes32 taskId = _bountyToEvaluated(ITMPCore.VerdictType.REJECT, 0);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));

        uint256 award = REWARD - EVAL_FEE;
        uint256 requesterBefore = usdc.balanceOf(requester);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _award(award));

        assertEq(usdc.balanceOf(evaluator), 0, "an overturned verdict earns no fee");
        assertEq(usdc.balanceOf(worker), _net(award));
        assertEq(usdc.balanceOf(requester), requesterBefore + EVAL_FEE);
        _assertDiamondEmpty();
    }

    // -------------------------------------------------------------------------
    // Multi-winner rounding remainder
    // -------------------------------------------------------------------------

    function test_AcceptSubmissions_RefundsRoundingRemainderToRequester() public {
        uint256 reward = 100e6 + 2; // 3 equal-ish shares cannot split this exactly
        bytes32 taskId = _create(taskConfig(reward, DURATION, TMP_BOUNTY), noEvaluatorConfig());

        address[] memory winners = new address[](3);
        winners[0] = address(0xC1);
        winners[1] = address(0xC2);
        winners[2] = address(0xC3);
        for (uint256 i; i < 3; i++) {
            _relay(winners[i], 0, abi.encodeCall(market.submitWork, (taskId, keccak256(abi.encode(i)))));
        }
        uint16[] memory shares = new uint16[](3);
        shares[0] = 3334;
        shares[1] = 3333;
        shares[2] = 3333;

        uint256 requesterBefore = usdc.balanceOf(requester);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmissions, (taskId, winners, shares, new bytes32[](0), 0)));

        uint256 awarded;
        for (uint256 i; i < 3; i++) {
            awarded += (reward * shares[i]) / 10000;
        }
        assertGt(reward, awarded, "the split rounds down");
        assertEq(usdc.balanceOf(requester), requesterBefore + reward - awarded, "remainder returned");
        _assertDiamondEmpty();
    }
}
