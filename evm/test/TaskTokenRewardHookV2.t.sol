// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { ITMPHooksV2 } from "../src/interfaces/ITMPHooksV2.sol";
import { TMP_CLAIM, TMP_BOUNTY } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { TaskTokenRewardHookV2 } from "../src/hooks/TaskTokenRewardHookV2.sol";
import { PayoutGateHook } from "../src/hooks/payout-gate/PayoutGateHook.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { MockTaskHook } from "./mocks/MockTaskHook.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev TaskTokenRewardHookV2 (rev028) on a real diamond: the bonus through the claim and bounty
///      lifecycles, composition with the payout gate, and (rev030) the bonus following a transforming
///      hook's awards.
contract TaskTokenRewardHookV2Test is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockUSDC internal dreams;
    MockPGTRForwarder internal forwarder;
    TaskTokenRewardHookV2 internal hook2;

    address internal owner = address(0xA0);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    uint256 internal constant REWARD = 100e6;
    bytes32 internal constant WORK = keccak256("work");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        dreams = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));

        (RewardVault v2, EpochBudget b2) = _deps();
        bytes memory init = abi.encodeCall(
            TaskTokenRewardHookV2.initialize,
            (address(v2), address(b2), address(market), 18, 1e18, 1000, address(dreams), 8000, address(0xBEEF), owner)
        );
        hook2 = TaskTokenRewardHookV2(address(new ERC1967Proxy(address(new TaskTokenRewardHookV2()), init)));
        v2.setHook(address(hook2));
        b2.setHook(address(hook2));
        hook2.setRamp(
            [uint40(1), uint40(2), uint40(3)], [uint16(10_000), uint16(10_000), uint16(10_000), uint16(10_000)]
        );
        vm.stopPrank();
        usdc.mint(address(forwarder), 10_000e6);
    }

    function _deps() internal returns (RewardVault vault, EpochBudget budget) {
        vault = new RewardVault(address(dreams), owner);
        budget = new EpochBudget(7 days, 1_000_000e6, 100_000e6, 100_000e6, 10_000e6, owner);
        dreams.mint(owner, 100_000e18);
        dreams.transfer(address(vault), 100_000e18);
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function _create(bytes4 mode, address[] memory hooks, bytes memory data) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, 3 days, mode),
                        ITMPCore.HookConfig({ contracts: hooks, data: data }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _one(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    function _runClaim(address hook) internal returns (bytes32 taskId) {
        taskId = _create(TMP_CLAIM, _one(hook), "");
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
    }

    function test_DeclaresV2() public view {
        assertTrue(hook2.supportsInterface(type(ITMPHookV2).interfaceId));
        assertEq(hook2.hookCapabilities(), hook2.CAPABILITIES());
        assertEq(hook2.minDiamondVersion(), 28);
    }

    function test_V1HookRetiredAfterCut() public {
        bytes memory create = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, 3 days, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: _one(address(new MockTaskHook())), data: "" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                stakeTerms(false, 0)
            )
        );
        vm.expectRevert();
        _relay(requester, REWARD, create);
    }

    function test_ClaimTaskPaysTheBonus() public {
        _runClaim(address(hook2));
        assertGt(hook2.claimable(worker), 0, "worker bonus");
        assertGt(hook2.claimable(requester), 0, "requester bonus");
    }

    function test_BountyPaysTheBonus() public {
        bytes32 b = _create(TMP_BOUNTY, _one(address(hook2)), "");
        _relay(worker, 0, abi.encodeCall(market.submitWork, (b, WORK)));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (b, worker, WORK, 0)));
        assertGt(hook2.claimable(worker), 0, "worker bonus");
    }

    function test_CancelReleasesReserve() public {
        bytes32 b = _create(TMP_CLAIM, _one(address(hook2)), "");
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (b, 0)));
        assertEq(hook2.claimable(worker), 0);
    }

    function test_ComposesWithPayoutGate() public {
        PayoutGateHook gate = new PayoutGateHook(address(market));
        address[] memory hooks = new address[](2);
        hooks[0] = address(hook2);
        hooks[1] = address(gate);
        bytes[] memory configs = new bytes[](2);
        configs[1] = abi.encode(bytes32(0), uint64(block.timestamp + 1 hours), new bytes32[](0));
        bytes32 taskId = _create(TMP_CLAIM, hooks, abi.encode(configs));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        bytes memory accept = abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0));
        vm.expectRevert();
        _relay(requester, 0, accept);
        assertEq(hook2.claimable(worker), 0, "no bonus while gated");
        vm.warp(block.timestamp + 1 hours);
        _relay(requester, 0, accept);
        assertGt(hook2.claimable(worker), 0, "bonus paid with the payout");
    }

    // -------------------------------------------------------------------------
    // Rev030: the bonus follows what a transforming hook made the task pay
    //
    // On Base the reward hook is a protocol default, attached first, so a requester's
    // transforming hook runs after its beforeAccept. Reward 100e6 at 10% and 1e18 DREAMS per
    // USDC is a 10e18 bonus on the full reward; the worker is credited 80% of it.
    // -------------------------------------------------------------------------

    address internal worker2 = address(0xC1);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);
    uint256 internal constant FULL_BONUS = 10e18;

    function _defaultRewardHook() internal {
        vm.prank(owner);
        ITMPHooksV2(address(market)).setDefaultHooksV2(_one(address(hook2)));
    }

    /// @dev A transforming hook: may replace the awards (bit 26) on beforeAccept (bit 13).
    function _transformer() internal returns (MockTaskHookV2) {
        return new MockTaskHookV2(address(market), (uint32(1) << 13) | (uint32(1) << 26));
    }

    function _awards1(address w, uint256 amount) internal pure returns (ITMPCore.Award[] memory a) {
        a = new ITMPCore.Award[](1);
        a[0] = ITMPCore.Award({ worker: w, amount: amount, rank: 1 });
    }

    function _awards2(uint256 a1, uint256 a2) internal view returns (ITMPCore.Award[] memory a) {
        a = new ITMPCore.Award[](2);
        a[0] = ITMPCore.Award({ worker: worker, amount: a1, rank: 1 });
        a[1] = ITMPCore.Award({ worker: worker2, amount: a2, rank: 2 });
    }

    function _claimTaskWith(address[] memory hooks) internal returns (bytes32 taskId) {
        taskId = _create(TMP_CLAIM, hooks, "");
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
    }

    function _bountyWith(MockTaskHookV2 t) internal returns (bytes32 taskId) {
        taskId = _create(TMP_BOUNTY, _one(address(t)), "");
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work2"))));
    }

    function _acceptBoth(bytes32 taskId) internal {
        address[] memory workers = new address[](2);
        workers[0] = worker;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;
        _relay(requester, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0)));
    }

    function _assignEvaluator(bytes32 taskId) internal {
        _relay(
            requester, 0, abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, 2 days, 1 days, resolver))
        );
    }

    function _evaluate(bytes32 taskId, ITMPCore.Award[] memory awards) internal {
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.APPROVE, 900, 1000, bytes32(0), awards))
        );
    }

    function _paid(bytes32 taskId) internal view returns (bool paid) {
        (,,,,,,, paid,) = hook2.rewardStates(taskId);
    }

    function _reserve(bytes32 taskId) internal view returns (uint256) {
        return RewardVault(address(hook2.vault())).taskReserve(taskId);
    }

    function test_Rev030_ReservedAcceptBonusFollowsTransformedAward() public {
        _defaultRewardHook();
        MockTaskHookV2 t = _transformer();
        bytes32 taskId = _claimTaskWith(_one(address(t)));
        assertEq(_reserve(taskId), FULL_BONUS, "full bonus reserved");
        t.setResult(_awards1(worker, 1), 0, false);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));

        assertEq(market.getTaskVerdict(taskId).awards[0].amount, 1, "verdict records the paid award");
        uint256 bonus = FULL_BONUS * 1 / REWARD;
        assertEq(hook2.claimable(worker), bonus * 8000 / 10000, "worker bonus on the paid unit");
        assertEq(hook2.claimable(requester), bonus - bonus * 8000 / 10000, "requester bonus on the paid unit");
        assertEq(_reserve(taskId), 0, "the rest of the reservation released");
        assertTrue(_paid(taskId), "paid once");
        vm.expectRevert(abi.encodeWithSelector(TaskTokenRewardHookV2.ReleaseNotDue.selector, taskId));
        hook2.recoverReserve(taskId);
    }

    function test_Rev030_ReservedAcceptUnchangedWithoutTransform() public {
        _defaultRewardHook();
        // A transforming hook that leaves the awards alone, then no requester hook at all.
        bytes32 a = _claimTaskWith(_one(address(_transformer())));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (a, worker, WORK, 0)));
        assertFalse(market.getTaskVerdict(a).issued, "an unchanged acceptance stores no verdict");
        assertEq(hook2.claimable(worker), FULL_BONUS * 8000 / 10000, "full bonus");
        bytes32 b = _claimTaskWith(new address[](0));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (b, worker, WORK, 0)));
        assertEq(hook2.claimable(worker), 2 * (FULL_BONUS * 8000 / 10000), "full bonus again");
    }

    function test_Rev030_ReservedFinalizeVerdictBonusFollowsTransformedAward() public {
        _defaultRewardHook();
        MockTaskHookV2 t = _transformer();
        bytes32 taskId = _create(TMP_CLAIM, _one(address(t)), "");
        _assignEvaluator(taskId);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _evaluate(taskId, _awards1(worker, REWARD));
        t.setResult(_awards1(worker, 30e6), 0, false);
        vm.warp(block.timestamp + 1 days);
        market.finalizeVerdict(taskId);

        uint256 bonus = FULL_BONUS * 30e6 / REWARD;
        assertEq(hook2.claimable(worker), bonus * 8000 / 10000, "worker bonus on the paid award");
        assertEq(_reserve(taskId), 0, "the rest released");
    }

    function test_Rev030_BountyAcceptSubmissionsBonusFollowsTransformedAwards() public {
        _defaultRewardHook();
        MockTaskHookV2 t = _transformer();
        bytes32 taskId = _bountyWith(t);
        t.setResult(_awards2(10e6, 1e6), 0, false);
        _acceptBoth(taskId);

        ITMPCore.Verdict memory v = market.getTaskVerdict(taskId);
        assertEq(v.awards.length, 2, "verdict records the paid awards");
        assertEq(v.awards[1].amount, 1e6);
        // 10% of each paid award at 1e18 DREAMS per USDC.
        uint256 b1 = 1e18;
        uint256 b2 = 1e17;
        assertEq(hook2.claimable(worker), b1 * 8000 / 10000, "worker bonus on 10e6");
        assertEq(hook2.claimable(worker2), b2 * 8000 / 10000, "worker2 bonus on 1e6");
        assertEq(hook2.claimable(requester), (b1 - b1 * 8000 / 10000) + (b2 - b2 * 8000 / 10000), "requester");
        assertTrue(_paid(taskId), "paid once");
    }

    function test_Rev030_BountyAcceptSubmissionsUnchangedWithoutTransform() public {
        _defaultRewardHook();
        bytes32 taskId = _bountyWith(_transformer());
        _acceptBoth(taskId);
        assertFalse(market.getTaskVerdict(taskId).issued, "an unchanged acceptance stores no verdict");
        // Each half of the reward earns 10%: 5e18 each.
        assertEq(hook2.claimable(worker), 5e18 * 8000 / 10000, "worker half");
        assertEq(hook2.claimable(worker2), 5e18 * 8000 / 10000, "worker2 half");
    }

    function test_Rev030_BountyFinalizeVerdictBonusFollowsTransformedAwards() public {
        _defaultRewardHook();
        MockTaskHookV2 t = _transformer();
        bytes32 taskId = _create(TMP_BOUNTY, _one(address(t)), "");
        _assignEvaluator(taskId);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work2"))));
        _evaluate(taskId, _awards2(50e6, 50e6));
        t.setResult(_awards2(10e6, 1e6), 0, false);
        vm.warp(block.timestamp + 1 days);
        market.finalizeVerdict(taskId);

        assertEq(hook2.claimable(worker), 1e18 * 8000 / 10000, "worker bonus on 10e6");
        assertEq(hook2.claimable(worker2), 1e17 * 8000 / 10000, "worker2 bonus on 1e6");
    }

    /// @dev afterComplete is best effort: a failed call leaves the reservation held and unpaid, and
    ///      recoverReserve pays it from the awards the diamond recorded.
    function test_Rev030_MissedAfterCompleteRecoversOnPaidAward() public {
        _defaultRewardHook();
        MockTaskHookV2 t = _transformer();
        bytes32 taskId = _claimTaskWith(_one(address(t)));
        t.setResult(_awards1(worker, 25e6), 0, false);
        vm.mockCallRevert(address(hook2), abi.encodeWithSelector(ITMPHookV2.afterComplete.selector), "");
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        vm.clearMockedCalls();
        assertEq(hook2.claimable(worker), 0, "no bonus yet");
        assertFalse(_paid(taskId));
        assertEq(_reserve(taskId), FULL_BONUS, "reservation still held");

        hook2.recoverReserve(taskId);
        uint256 bonus = FULL_BONUS * 25e6 / REWARD;
        assertEq(hook2.claimable(worker), bonus * 8000 / 10000, "recovered on the paid award");
        assertEq(_reserve(taskId), 0, "nothing left reserved");
        vm.expectRevert(abi.encodeWithSelector(TaskTokenRewardHookV2.ReleaseNotDue.selector, taskId));
        hook2.recoverReserve(taskId);
    }
}
