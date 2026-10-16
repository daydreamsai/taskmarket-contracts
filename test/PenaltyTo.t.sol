// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../src/interfaces/ITMPTerms.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { RegistryFacet } from "../src/facets/RegistryFacet.sol";
import { TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";
import { TermsProbeFacet, ITermsProbe } from "./TaskTerms.t.sol";

/// @dev rev025 penaltyTo: every worker-stake forfeit goes to the requester by default or to the
///      protocol as fees, evaluator stakes keep their destinations, and forfeitAndReopen extends
///      the expiry so the reopened task can be claimed.
contract PenaltyToTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;
    ITermsProbe internal probe;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal worker2 = address(0xC1);
    address internal evaluator = address(0xD0);
    address internal resolver = address(0xE0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant STAKE = 10e6;
    uint256 internal constant EVAL_STAKE = 5e6;
    uint256 internal constant DURATION = 7 days;
    uint16 internal constant EVAL_FEE_BPS = 1000;
    uint32 internal constant APPEAL_WINDOW = 1 days;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = TermsProbeFacet.probeWipeTerms.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(new TermsProbeFacet()), IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
        vm.stopPrank();
        probe = ITermsProbe(address(market));

        usdc.mint(address(forwarder), 100_000e6);
        usdc.mint(requester, 1_000e6);
        vm.prank(requester);
        usdc.approve(address(market), type(uint256).max);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _terms(ITMPCore.PenaltyTo to) internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 1;
        t.penaltyTo = to;
    }

    function _evalConfig(uint256 stake, address dr) internal view returns (ITMPCore.TaskEvaluatorConfig memory) {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: stake,
            evaluatorFeeBps: EVAL_FEE_BPS,
            evaluationWindow: 2 days,
            appealWindow: APPEAL_WINDOW,
            disputeResolver: dr
        });
    }

    function _create(ITMPCore.TaskTerms memory terms, ITMPCore.TaskEvaluatorConfig memory evalCfg)
        internal
        returns (bytes32)
    {
        bytes memory data = abi.encodeCall(
            ITMPTerms.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                evalCfg,
                terms
            )
        );
        return abi.decode(_relay(requester, REWARD + evalCfg.evaluatorStake, data), (bytes32));
    }

    function _claim(bytes32 taskId, address w) internal {
        _relay(w, STAKE, abi.encodeCall(market.claimTask, (taskId, STAKE)));
    }

    function _award(uint256 amount) internal view returns (ITMPCore.Award[] memory awards) {
        awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: amount, rank: 1 });
    }

    function _evaluate(bytes32 taskId, ITMPCore.VerdictType verdict, ITMPCore.Award[] memory awards) internal {
        _relay(evaluator, 0, abi.encodeCall(market.evaluate, (taskId, verdict, 900, 1000, bytes32(0), awards)));
    }

    /// @dev Asserts the stake landed on exactly one side and was booked as fees only for Protocol.
    function _assertRouted(
        ITMPCore.PenaltyTo to,
        uint256 requesterGain,
        uint256 requesterBase,
        uint256 feeBefore,
        uint256 feesBefore
    ) internal view {
        bool protocol = to == ITMPCore.PenaltyTo.Protocol;
        assertEq(requesterGain, requesterBase + (protocol ? 0 : STAKE), "requester share");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, protocol ? STAKE : 0, "fee recipient share");
        assertEq(market.totalFeesCollected() - feesBefore, protocol ? STAKE : 0, "protocol fees booked");
    }

    // -------------------------------------------------------------------------
    // forfeitAndReopen
    // -------------------------------------------------------------------------

    function _forfeitAndReopen(ITMPCore.PenaltyTo to) internal {
        bytes32 taskId = _create(_terms(to), noEvaluatorConfig());
        _claim(taskId, worker);
        uint256 oldExpiry = market.getTask(taskId).expiryTime;
        vm.warp(oldExpiry + 1);

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 feesBefore = market.totalFeesCollected();
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeForfeited(taskId, worker, STAKE);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        _assertRouted(to, usdc.balanceOf(requester) - reqBefore, 0, feeBefore, feesBefore);
        assertEq(usdc.balanceOf(worker), 0, "worker keeps nothing");
        assertEq(RegistryFacet(address(market)).stakeForfeit(taskId), STAKE, "forfeit recorded");
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open));
        assertEq(task.expiryTime, block.timestamp + 72 hours, "expiry extended by the default reopen extension");

        _claim(taskId, worker2);
        assertEq(market.getTask(taskId).worker, worker2, "reopened task can be claimed");
    }

    function test_ForfeitAndReopen_PenaltyToRequester() public {
        _forfeitAndReopen(ITMPCore.PenaltyTo.Requester);
    }

    function test_ForfeitAndReopen_PenaltyToProtocol() public {
        _forfeitAndReopen(ITMPCore.PenaltyTo.Protocol);
    }

    // -------------------------------------------------------------------------
    // refundExpired on an undelivered staked Claim task
    // -------------------------------------------------------------------------

    /// @dev A worker who claimed and never delivered forfeits the whole stake at expiry, to the
    ///      same destination as forfeitAndReopen, and the requester also recovers the reward.
    function _refundExpiredUndelivered(ITMPCore.PenaltyTo to) internal {
        bytes32 taskId = _create(_terms(to), noEvaluatorConfig());
        _claim(taskId, worker);
        vm.warp(market.getTask(taskId).expiryTime + 1);

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 feesBefore = market.totalFeesCollected();
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeForfeited(taskId, worker, STAKE);
        market.refundExpired(taskId, 0);

        _assertRouted(to, usdc.balanceOf(requester) - reqBefore, REWARD, feeBefore, feesBefore);
        assertEq(usdc.balanceOf(worker), 0, "worker gets no stake back");
        assertEq(RegistryFacet(address(market)).stakeForfeit(taskId), STAKE, "forfeit recorded");
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Expired), "expired");
        assertEq(task.stakeAmount, 0, "stake cleared");
        assertEq(usdc.balanceOf(address(market)), 0, "diamond holds nothing");
    }

    function test_RefundExpired_Undelivered_ForfeitsStake_PenaltyToRequester() public {
        _refundExpiredUndelivered(ITMPCore.PenaltyTo.Requester);
    }

    function test_RefundExpired_Undelivered_ForfeitsStake_PenaltyToProtocol() public {
        _refundExpiredUndelivered(ITMPCore.PenaltyTo.Protocol);
    }

    /// @dev Racing refundExpired ahead of the requester's forfeitAndReopen yields the same stake
    ///      forfeit, so a keeper calling refundExpired first cannot hand the stake back to the worker.
    function test_RefundExpired_RacingForfeitAndReopen_SameForfeit() public {
        bytes32 forfeited = _create(_terms(ITMPCore.PenaltyTo.Requester), noEvaluatorConfig());
        _claim(forfeited, worker);
        bytes32 refunded = _create(_terms(ITMPCore.PenaltyTo.Requester), noEvaluatorConfig());
        _claim(refunded, worker2);
        vm.warp(market.getTask(refunded).expiryTime + 1);

        uint256 reqBefore = usdc.balanceOf(requester);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (forfeited)));
        uint256 viaForfeit = usdc.balanceOf(requester) - reqBefore;

        reqBefore = usdc.balanceOf(requester);
        market.refundExpired(refunded, 0);
        uint256 viaRefund = usdc.balanceOf(requester) - reqBefore - REWARD;

        assertEq(viaForfeit, STAKE, "forfeitAndReopen pays the stake");
        assertEq(viaRefund, viaForfeit, "refundExpired forfeits the same stake");
        assertEq(usdc.balanceOf(worker), 0, "first worker keeps nothing");
        assertEq(usdc.balanceOf(worker2), 0, "second worker keeps nothing");
        assertEq(
            RegistryFacet(address(market)).stakeForfeit(refunded),
            RegistryFacet(address(market)).stakeForfeit(forfeited),
            "same forfeit recorded"
        );

        // The refunded task is terminal: the requester's forfeitAndReopen now comes too late.
        vm.expectRevert();
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (refunded)));
    }

    function test_ForfeitAndReopen_CustomExtension_KeepsLaterExpiry() public {
        ITMPCore.TaskTerms memory t = _terms(ITMPCore.PenaltyTo.Requester);
        t.reopenExtensionSecs = 2 days;
        bytes32 taskId = _create(t, noEvaluatorConfig());
        _claim(taskId, worker);
        vm.warp(market.getTask(taskId).expiryTime + 1);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        assertEq(market.getTask(taskId).expiryTime, block.timestamp + 2 days, "custom reopen extension");
    }

    function test_ForfeitAndReopen_LegacyTaskDefaultsToRequester() public {
        bytes32 taskId = _create(_terms(ITMPCore.PenaltyTo.Protocol), noEvaluatorConfig());
        _claim(taskId, worker);
        probe.probeWipeTerms(taskId);
        vm.warp(market.getTask(taskId).expiryTime + 1);

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        assertEq(usdc.balanceOf(requester) - reqBefore, STAKE, "normalized task pays the requester");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "nothing to the protocol");
        assertEq(market.getTask(taskId).expiryTime, block.timestamp + 72 hours, "default extension");
        assertEq(market.getTaskTerms(taskId).version, 1, "normalized on read");
    }

    // -------------------------------------------------------------------------
    // rejectDelivery
    // -------------------------------------------------------------------------

    /// @dev A delivered worker's stake is never a penalty: a zero-fee reject returns it in full
    ///      and routes nothing to the requester or the protocol, whatever penaltyTo says.
    function _rejectDelivery(ITMPCore.PenaltyTo to) internal {
        ITMPCore.TaskTerms memory t = _terms(to);
        t.rejectFeeBps = 1; // stored as fee + 1: a zero reject fee
        bytes32 taskId = _create(t, noEvaluatorConfig());
        _claim(taskId, worker);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 feesBefore = market.totalFeesCollected();
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.StakeReturned(taskId, worker, STAKE);
        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPCore.DeliveryRejected(taskId, worker, 0, 0);
        _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));

        assertEq(usdc.balanceOf(worker), STAKE, "worker gets the full stake back");
        assertEq(usdc.balanceOf(requester), reqBefore, "requester takes no stake");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "protocol takes no stake");
        assertEq(market.totalFeesCollected(), feesBefore, "no fees booked");
        assertEq(RegistryFacet(address(market)).stakeForfeit(taskId), 0, "no forfeit recorded");
        assertEq(market.getTask(taskId).stakeAmount, 0, "stake cleared");
        assertEq(usdc.balanceOf(address(market)), REWARD, "only the escrow stays");
    }

    function test_RejectDelivery_ZeroFee_PenaltyToRequester() public {
        _rejectDelivery(ITMPCore.PenaltyTo.Requester);
    }

    function test_RejectDelivery_ZeroFee_PenaltyToProtocol() public {
        _rejectDelivery(ITMPCore.PenaltyTo.Protocol);
    }

    /// @dev A requester cannot farm stakes by rejecting delivery after delivery at a zero fee:
    ///      each rejected worker leaves with exactly the stake they posted.
    function test_RejectDelivery_ZeroFee_RepeatedCyclesLeaveRequesterNoStakes() public {
        ITMPCore.TaskTerms memory t = _terms(ITMPCore.PenaltyTo.Requester);
        t.rejectFeeBps = 1;
        bytes32 taskId = _create(t, noEvaluatorConfig());
        uint256 reqBefore = usdc.balanceOf(requester);

        address[3] memory workers = [worker, worker2, address(0xC2)];
        for (uint256 i; i < workers.length; ++i) {
            _claim(taskId, workers[i]);
            _relay(workers[i], 0, abi.encodeCall(market.submitWork, (taskId, keccak256(abi.encode(i)))));
            vm.expectEmit(true, true, false, true, address(market));
            emit ITMPCore.StakeReturned(taskId, workers[i], STAKE);
            _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));

            assertEq(usdc.balanceOf(workers[i]), STAKE, "each rejected worker keeps their stake");
            assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Open), "reopened");
        }

        assertEq(usdc.balanceOf(requester), reqBefore, "requester collected no stakes");
        assertEq(RegistryFacet(address(market)).stakeForfeit(taskId), 0, "nothing forfeited");
        assertEq(market.getTask(taskId).reward, REWARD, "a zero fee leaves the escrow whole");
        assertEq(usdc.balanceOf(address(market)), REWARD, "diamond holds only the escrow");
    }

    function test_RejectDelivery_WithFee_ReturnsStakeUnderProtocol() public {
        bytes32 taskId = _create(_terms(ITMPCore.PenaltyTo.Protocol), noEvaluatorConfig());
        _claim(taskId, worker);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        uint256 feesBefore = market.totalFeesCollected();
        _relay(requester, 0, abi.encodeCall(market.rejectDelivery, (taskId)));

        uint256 rejectFee = (REWARD * 2000) / 10000;
        uint256 platformFee = (rejectFee * 500) / 10000;
        assertEq(usdc.balanceOf(worker), STAKE + rejectFee - platformFee, "stake returned with the fee");
        assertEq(market.totalFeesCollected() - feesBefore, platformFee, "only the platform fee is booked");
    }

    // -------------------------------------------------------------------------
    // finalized REJECT verdict and dispute against the worker
    // -------------------------------------------------------------------------

    function _verdictReject(ITMPCore.PenaltyTo to) internal {
        bytes32 taskId = _create(_terms(to), _evalConfig(0, address(0)));
        _claim(taskId, worker);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _evaluate(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));
        vm.warp(block.timestamp + APPEAL_WINDOW);

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 feesBefore = market.totalFeesCollected();
        market.finalizeVerdict(taskId);

        uint256 evalFee = (REWARD * EVAL_FEE_BPS) / 10000;
        _assertRouted(to, usdc.balanceOf(requester) - reqBefore, REWARD - evalFee, feeBefore, feesBefore);
        assertEq(usdc.balanceOf(worker), 0, "rejected worker forfeits the stake");
        assertEq(usdc.balanceOf(address(market)), 0, "diamond settles everything");
    }

    function test_FinalizeVerdictReject_PenaltyToRequester() public {
        _verdictReject(ITMPCore.PenaltyTo.Requester);
    }

    function test_FinalizeVerdictReject_PenaltyToProtocol() public {
        _verdictReject(ITMPCore.PenaltyTo.Protocol);
    }

    function _disputeAgainstWorker(ITMPCore.PenaltyTo to) internal {
        bytes32 taskId = _create(_terms(to), _evalConfig(0, resolver));
        _claim(taskId, worker);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _evaluate(taskId, ITMPCore.VerdictType.PARTIAL, _award(10e6));
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 feesBefore = market.totalFeesCollected();
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, _award(0));

        _assertRouted(to, usdc.balanceOf(requester) - reqBefore, REWARD, feeBefore, feesBefore);
        assertEq(usdc.balanceOf(worker), 0, "resolved against the worker");
        assertEq(usdc.balanceOf(address(market)), 0, "diamond settles everything");
    }

    function test_ResolveDisputeAgainstWorker_PenaltyToRequester() public {
        _disputeAgainstWorker(ITMPCore.PenaltyTo.Requester);
    }

    function test_ResolveDisputeAgainstWorker_PenaltyToProtocol() public {
        _disputeAgainstWorker(ITMPCore.PenaltyTo.Protocol);
    }

    // -------------------------------------------------------------------------
    // Evaluator stakes keep their destinations
    // -------------------------------------------------------------------------

    function test_EvaluatorTimeout_EvaluatorStakeStillToFeeRecipient() public {
        bytes32 taskId = _create(_terms(ITMPCore.PenaltyTo.Requester), _evalConfig(EVAL_STAKE, address(0)));
        _claim(taskId, worker);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        vm.warp(block.timestamp + 2 days + 1);

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, EVAL_STAKE, "evaluator stake to the fee recipient");
        assertEq(usdc.balanceOf(requester), reqBefore, "penaltyTo does not redirect the evaluator stake");
    }
}
