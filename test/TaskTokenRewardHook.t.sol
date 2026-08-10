// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { TaskTokenRewardHook } from "../src/hooks/TaskTokenRewardHook.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { EpochBudget } from "../src/hooks/EpochBudget.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import "./mocks/MockPGTRForwarder.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
// ─────────────────────────────────────────────────────────────────────────────
// Test suite
// ─────────────────────────────────────────────────────────────────────────────

contract TaskTokenRewardHookTest is DiamondTestHelper {
    using stdStorage for StdStorage;

    // DREAMS wei per 1 USDC. 10 DREAMS per $1 => 10e18.
    uint256 constant DREAMS_PER_USDC = 10e18;
    // $100 USDC reward = 100 * 1e6 (6 decimals)
    uint256 constant REWARD_100_USDC = 100 * 1e6;
    // expected token reward at full rate: rewardUsd * rate / 1e6 = 100e6 * 10e18 / 1e6 = 1000 DREAMS
    uint256 constant EXPECTED_REWARD_1000_DREAMS = 1000 * 1e18;

    uint256 constant EPOCH_DURATION = 7 days;
    uint256 constant GLOBAL_CAP_USD = 1_000_000 * 1e6;
    uint256 constant WORKER_CAP_USD = 100_000 * 1e6;
    uint256 constant REQUESTER_CAP_USD = 500_000 * 1e6;
    uint256 constant MAX_PER_TASK_USD = 10_000 * 1e6;
    uint16 constant WORKER_SPLIT_BPS = 10_000; // setUp uses 100% worker for backward compat
    // setUp uses a 100% bonus so bonusUsd == rewardUsd exactly, keeping every existing
    // dollar-figure assertion below unchanged. Dedicated tests further down use a
    // non-100% bonusBps (750 = 7.5%) to verify the two-step bonus%-then-rate math.
    uint16 constant BONUS_BPS = 10_000;

    ITMPDiamond market;
    MockPGTRForwarder forwarder;
    MockUSDC usdc;
    MockUSDC dreamsToken;

    RewardVault vault;
    EpochBudget budget;
    TaskTokenRewardHook hook;

    address owner = makeAddr("owner");
    address backend = makeAddr("backend");
    address requester = makeAddr("requester");
    address worker = makeAddr("worker");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockUSDC();
        dreamsToken = new MockUSDC(); // 18-decimal mock for DREAMS

        market = deployDiamond(owner, address(usdc), feeRecipient, 500);

        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));

        vault = new RewardVault(address(dreamsToken), owner);
        budget =
            new EpochBudget(EPOCH_DURATION, GLOBAL_CAP_USD, WORKER_CAP_USD, REQUESTER_CAP_USD, MAX_PER_TASK_USD, owner);
        hook = new TaskTokenRewardHook(
            address(vault),
            address(budget),
            address(market),
            18,
            DREAMS_PER_USDC,
            BONUS_BPS,
            address(dreamsToken),
            WORKER_SPLIT_BPS,
            backend,
            owner
        );

        vault.setHook(address(hook));
        budget.setHook(address(hook));

        // Use bypass ramp (age=0 gets full rate) so existing tests are not affected by the
        // default 2/4/8-week ramp. Ramp-specific tests override via setRamp().
        hook.setRamp(
            [uint40(1), uint40(2), uint40(3)], [uint16(10_000), uint16(10_000), uint16(10_000), uint16(10_000)]
        );

        // Fund vault with 100k DREAMS
        dreamsToken.mint(owner, 100_000 * 1e18);
        dreamsToken.transfer(address(vault), 100_000 * 1e18);

        vm.stopPrank();

        // Forwarder holds USDC on behalf of payers
        usdc.mint(address(forwarder), 10_000 * 1e6);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function _createClaimTask() internal returns (bytes32 taskId) {
        bytes memory result = _relay(
            requester,
            REWARD_100_USDC,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD_100_USDC, 1 days, market.CLAIM(), 0, 0, bytes4(0)),
                    ITMPCore.StakeConfig({ required: false, bps: 0 }),
                    ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: "" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig()
                )
            )
        );
        taskId = abi.decode(result, (bytes32));
    }

    function _createBountyTask() internal returns (bytes32 taskId) {
        bytes memory result = _relay(
            requester,
            REWARD_100_USDC,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD_100_USDC, 1 days, market.BOUNTY(), 0, 0, bytes4(0)),
                    ITMPCore.StakeConfig({ required: false, bps: 0 }),
                    ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: "" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig()
                )
            )
        );
        taskId = abi.decode(result, (bytes32));
    }

    function _createLongClaimTask() internal returns (bytes32 taskId) {
        bytes memory result = _relay(
            requester,
            REWARD_100_USDC,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD_100_USDC, 365 days, market.CLAIM(), 0, 0, bytes4(0)),
                    ITMPCore.StakeConfig({ required: false, bps: 0 }),
                    ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: "" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig()
                )
            )
        );
        taskId = abi.decode(result, (bytes32));
    }

    function _hookArr(address h) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = h;
    }

    // ─── ERC-165 ──────────────────────────────────────────────────────────────

    function test_supportsInterface() public view {
        assertTrue(hook.supportsInterface(type(ITMPHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(bytes4(0xdeadbeef)));
    }

    // ─── Constructor validation ───────────────────────────────────────────────

    function test_constructor_zeroVault_reverts() public {
        vm.expectRevert(TaskTokenRewardHook.ZeroAddress.selector);
        new TaskTokenRewardHook(
            address(0),
            address(budget),
            address(market),
            18,
            DREAMS_PER_USDC,
            BONUS_BPS,
            address(dreamsToken),
            WORKER_SPLIT_BPS,
            backend,
            owner
        );
    }

    function test_constructor_revertsIfTokenZero() public {
        vm.expectRevert(TaskTokenRewardHook.ZeroAddress.selector);
        new TaskTokenRewardHook(
            address(vault),
            address(budget),
            address(market),
            18,
            DREAMS_PER_USDC,
            BONUS_BPS,
            address(0),
            WORKER_SPLIT_BPS,
            backend,
            owner
        );
    }

    function test_constructor_revertsIfBpsOver10000() public {
        vm.expectRevert(TaskTokenRewardHook.InvalidBps.selector);
        new TaskTokenRewardHook(
            address(vault),
            address(budget),
            address(market),
            18,
            DREAMS_PER_USDC,
            BONUS_BPS,
            address(dreamsToken),
            10_001,
            backend,
            owner
        );
    }

    function test_constructor_revertsIfBonusBpsOver10000() public {
        vm.expectRevert(TaskTokenRewardHook.InvalidBps.selector);
        new TaskTokenRewardHook(
            address(vault),
            address(budget),
            address(market),
            18,
            DREAMS_PER_USDC,
            10_001,
            address(dreamsToken),
            WORKER_SPLIT_BPS,
            backend,
            owner
        );
    }

    function test_constructor_revertsIfBackendZero() public {
        vm.expectRevert(TaskTokenRewardHook.ZeroAddress.selector);
        new TaskTokenRewardHook(
            address(vault),
            address(budget),
            address(market),
            18,
            DREAMS_PER_USDC,
            BONUS_BPS,
            address(dreamsToken),
            WORKER_SPLIT_BPS,
            address(0),
            owner
        );
    }

    function test_constructor_revertsIfRateZero() public {
        vm.expectRevert(TaskTokenRewardHook.ZeroRate.selector);
        new TaskTokenRewardHook(
            address(vault),
            address(budget),
            address(market),
            18,
            0,
            BONUS_BPS,
            address(dreamsToken),
            WORKER_SPLIT_BPS,
            backend,
            owner
        );
    }

    function test_constructor_allowsZeroBonusBps() public {
        // Unlike dreamsPerUsdc, a zero bonus is a valid initial state (bonus paused).
        TaskTokenRewardHook freshHook = new TaskTokenRewardHook(
            address(vault),
            address(budget),
            address(market),
            18,
            DREAMS_PER_USDC,
            0,
            address(dreamsToken),
            WORKER_SPLIT_BPS,
            backend,
            owner
        );
        assertEq(freshHook.bonusBps(), 0);
    }

    // ─── setDreamsPerUsdc ─────────────────────────────────────────────────────

    function test_setDreamsPerUsdc_updatesRate() public {
        vm.expectEmit(true, true, true, true);
        emit TaskTokenRewardHook.PriceUpdated(20e18);
        vm.prank(owner);
        hook.setDreamsPerUsdc(20e18);
        assertEq(hook.dreamsPerUsdc(), 20e18);
    }

    function test_setDreamsPerUsdc_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(TaskTokenRewardHook.ZeroRate.selector);
        hook.setDreamsPerUsdc(0);
    }

    function test_setDreamsPerUsdc_onlyOwner() public {
        vm.expectRevert();
        hook.setDreamsPerUsdc(20e18);
    }

    function test_setDreamsPerUsdc_doesNotChangeBonusBps() public {
        vm.prank(owner);
        hook.setDreamsPerUsdc(20e18);
        assertEq(hook.bonusBps(), BONUS_BPS);
    }

    // ─── setBonusBps ──────────────────────────────────────────────────────────

    function test_setBonusBps_updatesValue() public {
        vm.expectEmit(true, true, true, true);
        emit TaskTokenRewardHook.BonusBpsUpdated(750);
        vm.prank(owner);
        hook.setBonusBps(750);
        assertEq(hook.bonusBps(), 750);
    }

    function test_setBonusBps_allowsZero() public {
        vm.prank(owner);
        hook.setBonusBps(0);
        assertEq(hook.bonusBps(), 0);
    }

    function test_setBonusBps_revertsOnOver10000() public {
        vm.prank(owner);
        vm.expectRevert(TaskTokenRewardHook.InvalidBps.selector);
        hook.setBonusBps(10_001);
    }

    function test_setBonusBps_onlyOwner() public {
        vm.expectRevert();
        hook.setBonusBps(750);
    }

    function test_setBonusBps_doesNotChangeRate() public {
        vm.prank(owner);
        hook.setBonusBps(750);
        assertEq(hook.dreamsPerUsdc(), DREAMS_PER_USDC);
    }

    // ─── Claim mode happy path ─────────────────────────────────────────────────

    function test_claimMode_fullHappyPath() public {
        bytes32 taskId = _createClaimTask();

        // Verify state stored
        (uint256 rewardUsd,,,, address req,, bool reserved, bool paid,) = hook.rewardStates(taskId);
        assertEq(rewardUsd, REWARD_100_USDC);
        assertEq(req, requester);
        assertFalse(reserved);
        assertFalse(paid);

        // Worker claims — rate locks, tokens reserved
        uint256 vaultBefore = vault.available();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        (,, uint256 startPrice, uint256 reservedAmt,, address lockedWorker, bool res,,) = hook.rewardStates(taskId);
        assertEq(startPrice, DREAMS_PER_USDC);
        assertEq(lockedWorker, worker);
        assertTrue(res);
        // reserved = rewardUsd * rate / 1e6 = 100e6 * 10e18 / 1e6 = 1000 DREAMS, deterministic (no drift)
        assertEq(reservedAmt, EXPECTED_REWARD_1000_DREAMS);
        assertLt(vault.available(), vaultBefore);

        // Worker submits
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        // Requester accepts — hook credits tokens to claimable (100% worker split in setUp)
        uint256 workerClaimableBefore = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        uint256 workerClaimableAfter = hook.claimable(worker);
        assertEq(workerClaimableAfter - workerClaimableBefore, EXPECTED_REWARD_1000_DREAMS);
        // Worker wallet balance unchanged — tokens are in hook escrow
        assertEq(dreamsToken.balanceOf(worker), 0);
        // Locked rate means the full reservation is paid out exactly — nothing left reserved.
        assertEq(vault.taskReserve(taskId), 0);

        // Verify paid flag
        (,,,,,,, bool paid2,) = hook.rewardStates(taskId);
        assertTrue(paid2);
    }

    // ─── Double-reservation guard (evaluator-reject reopen) ────────────────────
    // Regression test for a bug where EvaluatorFacet.finalizeVerdict's REJECT branch
    // reopens a claimed task (status -> Open, worker -> address(0)) without calling
    // any reward-hook release path. A second claim then re-entered _reserveForWorker
    // for the same taskId, and because RewardVault.reserve() is additive, the vault
    // ended up holding two reservations while the hook only tracked the latest one —
    // permanently orphaning the first reservation's tokens.
    // Regression test for a fixed bug where EvaluatorFacet.finalizeVerdict's REJECT
    // branch reopened a claimed task (status -> Open) after refunding the full escrow
    // to the requester, without releasing the reward hook's reservation. A second
    // claim would then stack a second reservation on top of the orphaned first one
    // (RewardVault.reserve is additive). The fix makes REJECT terminate the task
    // (Cancelled, matching cancelTask) and dispatch onCancel so the reservation is
    // released through the normal path -- this test verifies both halves of that fix.
    function test_evaluatorReject_releasesReservationAndTerminatesTask() public {
        address evaluator = makeAddr("evaluator");
        address worker2 = makeAddr("worker2");

        bytes32 taskId = _createClaimTask();
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), address(0))
            )
        );

        uint256 vaultBefore = vault.available();

        // Worker claims — reserves 1000 DREAMS.
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertEq(vault.taskReserve(taskId), EXPECTED_REWARD_1000_DREAMS);
        assertEq(vault.available(), vaultBefore - EXPECTED_REWARD_1000_DREAMS);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        // Evaluator rejects — no awards.
        ITMPCore.Award[] memory noAwards = new ITMPCore.Award[](0);
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (taskId, ITMPCore.VerdictType.REJECT, 0, 1000, bytes32(0), noAwards))
        );

        // Finalize after the appeal window — task terminates, reservation releases.
        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Cancelled));

        assertEq(vault.taskReserve(taskId), 0, "reservation must be released via onCancel, not left dangling");
        assertEq(vault.available(), vaultBefore, "vault tokens must not be orphaned");

        (,,,,,, bool reserved,,) = hook.rewardStates(taskId);
        assertFalse(reserved, "reward state must reflect the released reservation");

        // A cancelled task can never be reclaimed, so no double-reservation is possible.
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        _relay(worker2, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    // ─── Bounty mode (Path B) ─────────────────────────────────────────────────

    function test_bountyMode_paysAtComplete() public {
        bytes32 taskId = _createBountyTask();

        // Worker submits (no checkClaim fires)
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertGt(hook.claimable(worker), before);
        assertEq(dreamsToken.balanceOf(worker), 0);
    }

    // ─── Claimable escrow ─────────────────────────────────────────────────────

    function test_rewardsAccumulateInClaimable() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertGt(hook.claimable(worker), 0);
        assertEq(hook.totalClaimable(), hook.claimable(worker) + hook.claimable(requester));
        assertEq(dreamsToken.balanceOf(worker), 0);
    }

    function test_withdrawFor_happyPath() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        uint256 claimableAmt = hook.claimable(worker);
        assertGt(claimableAmt, 0);

        address destination = makeAddr("destination");
        vm.prank(backend);
        hook.withdrawFor(worker, destination);

        assertEq(dreamsToken.balanceOf(destination), claimableAmt);
        assertEq(hook.claimable(worker), 0);
        // totalClaimable decremented
        assertEq(hook.totalClaimable(), hook.claimable(requester));
    }

    function test_withdrawFor_revertsIfNotBackend() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        vm.expectRevert(TaskTokenRewardHook.NotBackend.selector);
        hook.withdrawFor(worker, worker);
    }

    function test_withdrawFor_revertsIfNothingToClaim() public {
        vm.prank(backend);
        vm.expectRevert(TaskTokenRewardHook.NothingToClaim.selector);
        hook.withdrawFor(worker, worker);
    }

    // ─── firstSeen ────────────────────────────────────────────────────────────

    function test_firstSeen_setOnCheckFund() public {
        assertEq(hook.firstSeen(requester), 0);
        _createClaimTask();
        assertGt(hook.firstSeen(requester), 0);
    }

    function test_firstSeen_setOnCheckClaim() public {
        bytes32 taskId = _createClaimTask();
        assertEq(hook.firstSeen(worker), 0);
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        assertGt(hook.firstSeen(worker), 0);
    }

    function test_firstSeen_neverOverwritten() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        uint40 seenFirst = hook.firstSeen(worker);
        assertGt(seenFirst, 0);

        // Submit and complete so worker can create another task
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // Fund forwarder and create a second task
        usdc.mint(address(forwarder), 10_000 * 1e6);
        vm.warp(block.timestamp + 1);
        bytes32 taskId2 = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId2, 0)));

        // firstSeen must not change
        assertEq(hook.firstSeen(worker), seenFirst);
    }

    function test_firstSeen_setForAuctionWorker() public {
        // checkSelectWorker fires for auction mode (same dispatch as pitch).
        // Call directly as the diamond to verify _touchFirstSeen runs.
        assertEq(hook.firstSeen(worker), 0);

        bytes32 taskId = _createClaimTask(); // need a seeded RewardState for _reserveForWorker
        vm.prank(address(market));
        ITMPCore.TaskContext memory ctx;
        ctx.requester = requester;
        hook.checkSelectWorker(taskId, ctx, worker);

        assertGt(hook.firstSeen(worker), 0);
    }

    function test_ageMultiplier_returnsZeroForNewWallet() public {
        // A wallet that has never interacted with the hook has firstSeen == 0 → multiplier 0.
        // Use the default ramp (restore it first).
        vm.prank(owner);
        hook.setRamp(
            [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)], [uint16(0), uint16(2500), uint16(5000), uint16(10_000)]
        );

        bytes32 taskId = _createClaimTask(); // requester firstSeen set here
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        // worker firstSeen just set — age = 0 < 2 weeks → rampMultipliers[0] = 0
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // Worker age = 0 seconds → multiplier[0] = 0 → claimable = 0
        assertEq(hook.claimable(worker), 0);
    }

    // ─── Age ramp ─────────────────────────────────────────────────────────────

    // Helper: complete a claim task and return worker's claimable delta.
    function _runClaimTask(uint16 _workerSplitBps) internal returns (uint256 workerClaimed) {
        vm.prank(owner);
        hook.setWorkerSplitBps(_workerSplitBps);

        usdc.mint(address(forwarder), REWARD_100_USDC);
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("w"))));

        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("w"), 0)));
        workerClaimed = hook.claimable(worker) - before;
    }

    function test_ageRamp_zeroBeforeTwoWeeks() public {
        // Restore default ramp
        vm.prank(owner);
        hook.setRamp(
            [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)], [uint16(0), uint16(2500), uint16(5000), uint16(10_000)]
        );

        // Touch firstSeen now, then complete task immediately (age < 2 weeks)
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertEq(hook.claimable(worker), 0);
    }

    function test_ageRamp_quarterXBetweenTwoAndFourWeeks() public {
        vm.prank(owner);
        hook.setRamp(
            [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)], [uint16(0), uint16(2500), uint16(5000), uint16(10_000)]
        );

        // Use a 365-day task so it doesn't expire during the warp.
        // Worker claims at T=0 (firstSeen set), then we warp into the 2–4 week window.
        usdc.mint(address(forwarder), REWARD_100_USDC);
        bytes32 taskId = _createLongClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        vm.warp(block.timestamp + 2 weeks + 1);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // 100% split to worker (setUp); 2500 bps = 25%: 1000 DREAMS * 0.25 = 250 DREAMS
        assertEq(hook.claimable(worker), 250 * 1e18);
    }

    function test_ageRamp_halfXBetweenFourAndEightWeeks() public {
        vm.prank(owner);
        hook.setRamp(
            [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)], [uint16(0), uint16(2500), uint16(5000), uint16(10_000)]
        );

        usdc.mint(address(forwarder), REWARD_100_USDC);
        bytes32 taskId = _createLongClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        vm.warp(block.timestamp + 4 weeks + 1);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // 5000 bps = 50%: 1000 DREAMS * 0.5 = 500 DREAMS
        assertEq(hook.claimable(worker), 500 * 1e18);
    }

    function test_ageRamp_fullXAfterEightWeeks() public {
        vm.prank(owner);
        hook.setRamp(
            [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)], [uint16(0), uint16(2500), uint16(5000), uint16(10_000)]
        );

        usdc.mint(address(forwarder), REWARD_100_USDC);
        bytes32 taskId = _createLongClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        vm.warp(block.timestamp + 8 weeks + 1);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // 10000 bps = 100%: 1000 DREAMS
        assertEq(hook.claimable(worker), 1000 * 1e18);
    }

    function test_creditWithSplit_zeroWhenRampIsZero() public {
        vm.prank(owner);
        hook.setRamp(
            [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)], [uint16(0), uint16(2500), uint16(5000), uint16(10_000)]
        );

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // Ramp at 0% for both parties — nothing credited
        assertEq(hook.claimable(worker), 0);
        assertEq(hook.claimable(requester), 0);
        assertEq(hook.totalClaimable(), 0);
        // Tokens were transferred from vault to hook — they sit as sweepable excess
        assertGt(dreamsToken.balanceOf(address(hook)), 0);
    }

    // ─── Worker/requester split ───────────────────────────────────────────────

    function test_requesterReceivesSplit() public {
        // Use 80/20 split; full-rate bypass ramp in setUp
        vm.prank(owner);
        hook.setWorkerSplitBps(8000);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // 1000 DREAMS total: worker 80% = 800, requester 20% = 200
        assertEq(hook.claimable(worker), 800 * 1e18);
        assertEq(hook.claimable(requester), 200 * 1e18);
        assertEq(hook.totalClaimable(), 1000 * 1e18);
    }

    function test_workerSplitBps_configurable() public {
        vm.prank(owner);
        hook.setWorkerSplitBps(6000); // 60/40

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        // 1000 DREAMS total: worker 60% = 600, requester 40% = 400
        assertEq(hook.claimable(worker), 600 * 1e18);
        assertEq(hook.claimable(requester), 400 * 1e18);
    }

    function test_setWorkerSplitBps_revertsIfOver10000() public {
        vm.prank(owner);
        vm.expectRevert(TaskTokenRewardHook.InvalidBps.selector);
        hook.setWorkerSplitBps(10_001);
    }

    // ─── Ban ──────────────────────────────────────────────────────────────────

    function test_ban_skipsWorkerCredit() public {
        vm.prank(owner);
        hook.banWallet(worker);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertEq(hook.claimable(worker), 0);
    }

    function test_ban_skipsRequesterCredit() public {
        vm.prank(owner);
        hook.setWorkerSplitBps(8000); // ensure requester would otherwise receive 20%
        vm.prank(owner);
        hook.banWallet(requester);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertEq(hook.claimable(requester), 0);
        assertGt(hook.claimable(worker), 0); // worker still earns
    }

    function test_ban_doesNotZeroExistingClaimable() public {
        // Earn some rewards first, then ban — existing balance must remain withdrawable.
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        uint256 earned = hook.claimable(worker);
        assertGt(earned, 0);

        vm.prank(owner);
        hook.banWallet(worker);

        // Existing balance intact
        assertEq(hook.claimable(worker), earned);

        // Backend can still withdraw on the worker's behalf
        address dest = makeAddr("dest");
        vm.prank(backend);
        hook.withdrawFor(worker, dest);
        assertEq(dreamsToken.balanceOf(dest), earned);
    }

    // ─── setRamp validation ───────────────────────────────────────────────────

    function test_setRamp_revertsOnNonIncreasingThresholds() public {
        vm.prank(owner);
        vm.expectRevert(TaskTokenRewardHook.InvalidRamp.selector);
        hook.setRamp(
            [uint40(4 weeks), uint40(2 weeks), uint40(8 weeks)], [uint16(0), uint16(2500), uint16(5000), uint16(10_000)]
        );
    }

    // ─── sweepUnclaimed ───────────────────────────────────────────────────────

    function test_sweepUnclaimed_cannotSweepWorkerFunds() public {
        // Earn rewards so totalClaimable > 0; then try to sweep more than excess
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        uint256 balance = dreamsToken.balanceOf(address(hook));
        vm.prank(owner);
        vm.expectRevert(TaskTokenRewardHook.InsufficientSweepable.selector);
        hook.sweepUnclaimed(owner, balance); // would sweep into totalClaimable
    }

    function test_sweepUnclaimed_canSweepRampExcess() public {
        // Use 0% ramp so all tokens become sweepable excess
        vm.prank(owner);
        hook.setRamp([uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)], [uint16(0), uint16(0), uint16(0), uint16(0)]);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        uint256 excess = dreamsToken.balanceOf(address(hook));
        assertGt(excess, 0);
        assertEq(hook.totalClaimable(), 0);

        uint256 ownerBefore = dreamsToken.balanceOf(owner);
        vm.prank(owner);
        hook.sweepUnclaimed(owner, excess); // should succeed
        assertEq(dreamsToken.balanceOf(owner) - ownerBefore, excess);
    }

    // ─── Locked-rate vs current-rate settlement ──────────────────────────────

    function test_checkComplete_usesLockedPriceForClaim() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        // Rate changes after the worker has claimed (locked at claim time).
        vm.prank(owner);
        hook.setDreamsPerUsdc(DREAMS_PER_USDC * 5);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        uint256 credited = hook.claimable(worker) - before;

        // Payout uses the rate locked at claim time, not the updated rate.
        assertEq(credited, EXPECTED_REWARD_1000_DREAMS);
    }

    function test_checkComplete_usesCurrentPriceForBounty() public {
        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        // Bounty has no lock — rate change before completion affects payout.
        vm.prank(owner);
        hook.setDreamsPerUsdc(DREAMS_PER_USDC * 2);

        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        uint256 credited = hook.claimable(worker) - before;

        assertEq(credited, EXPECTED_REWARD_1000_DREAMS * 2);
    }

    function test_checkComplete_usesLockedBonusBpsForClaim() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        // bonusBps changes after the worker has claimed (locked at claim time).
        vm.prank(owner);
        hook.setBonusBps(0);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        uint256 credited = hook.claimable(worker) - before;

        // Payout uses the bonusBps locked at claim time (100% from setUp), not the
        // updated (now-zero) bonusBps.
        assertEq(credited, EXPECTED_REWARD_1000_DREAMS);
    }

    function test_checkComplete_usesCurrentBonusBpsForBounty() public {
        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        // Bounty has no lock — bonusBps change before completion affects payout.
        vm.prank(owner);
        hook.setBonusBps(5_000); // 50%

        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        uint256 credited = hook.claimable(worker) - before;

        assertEq(credited, EXPECTED_REWARD_1000_DREAMS / 2);
    }

    function test_checkComplete_bounty_zeroBonusBps_skipsTokenReward() public {
        // Unlike dreamsPerUsdc, bonusBps == 0 is reachable through the real setter.
        vm.prank(owner);
        hook.setBonusBps(0);

        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 workerUsdcBefore = usdc.balanceOf(worker);
        uint256 workerClaimBefore = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertGt(usdc.balanceOf(worker), workerUsdcBefore);
        assertEq(hook.claimable(worker), workerClaimBefore);
    }

    function test_claimTask_zeroBonusBps_reservesNothing() public {
        vm.prank(owner);
        hook.setBonusBps(0);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        (, uint256 usdBonusValue, uint256 startPrice, uint256 reservedAmt,,, bool reserved,,) =
            hook.rewardStates(taskId);
        assertEq(usdBonusValue, 0);
        // Rate still locks even though the bonus is zero — the two are independent.
        assertEq(startPrice, DREAMS_PER_USDC);
        assertEq(reservedAmt, 0);
        assertTrue(reserved);
        assertEq(vault.taskReserve(taskId), 0);
    }

    // ─── Bonus % applied before rate conversion (non-100% bonus) ─────────────

    function test_bonusBps_appliedBeforeRateConversion() public {
        // 7.5% bonus (matches the platform fee default) instead of setUp's 100%.
        vm.prank(owner);
        hook.setBonusBps(750);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        (, uint256 usdBonusValue,,,,,,,) = hook.rewardStates(taskId);
        // $100 * 7.5% = $7.50 (7.5e6 USDC base units)
        assertEq(usdBonusValue, 7.5e6);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        uint256 credited = hook.claimable(worker) - before;

        // $7.50 * 10 DREAMS/USDC = 75 DREAMS
        assertEq(credited, 75 * 1e18);
    }

    function test_bonusBps_epochBudgetConsumesBonusValueNotRawReward() public {
        // With a 7.5% bonus, the epoch budget should be consumed for $7.50, not $100 —
        // the caps bound actual DREAMS emission value, not raw task volume.
        vm.prank(owner);
        hook.setBonusBps(750);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        assertEq(budget.workerUsed(worker), 7.5e6);
        assertEq(budget.requesterUsed(requester), 7.5e6);
        assertEq(budget.globalUsed(), 7.5e6);
    }

    // Neither the constructor nor setDreamsPerUsdc allow a zero rate, so the defensive
    // "no rate configured" branches are only reachable via a direct storage write —
    // exercised here with stdstore to simulate an unset/misconfigured rate.

    function test_checkComplete_bounty_zeroRate_skipsTokenReward() public {
        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        stdstore.target(address(hook)).sig("dreamsPerUsdc()").checked_write(uint256(0));

        uint256 workerUsdcBefore = usdc.balanceOf(worker);
        uint256 workerClaimBefore = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertGt(usdc.balanceOf(worker), workerUsdcBefore);
        assertEq(hook.claimable(worker), workerClaimBefore);
    }

    function test_claimTask_zeroRate_reservesNothing() public {
        stdstore.target(address(hook)).sig("dreamsPerUsdc()").checked_write(uint256(0));

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        (,, uint256 startPrice, uint256 reservedAmt,,, bool reserved,,) = hook.rewardStates(taskId);
        assertEq(startPrice, 0);
        assertEq(reservedAmt, 0);
        assertTrue(reserved);
        assertEq(vault.taskReserve(taskId), 0);

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        uint256 workerUsdcBefore = usdc.balanceOf(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        assertGt(usdc.balanceOf(worker), workerUsdcBefore);
        assertEq(hook.claimable(worker), 0);
    }

    // ─── Worker mismatch ─────────────────────────────────────────────────────

    function test_workerMismatch_revertsAtSubmit() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        address wrongWorker = makeAddr("wrongWorker");
        vm.expectRevert();
        _relay(wrongWorker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    // ─── Double payment blocked ───────────────────────────────────────────────

    function test_doublePayment_blocked() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        ITMPCore.Verdict memory verdict;
        ITMPCore.TaskContext memory ctx;
        ctx.requester = requester;
        vm.expectRevert(abi.encodeWithSelector(TaskTokenRewardHook.CallerNotDiamond.selector));
        hook.checkComplete(taskId, ctx, verdict);
    }

    // ─── Forfeit releases reserve ─────────────────────────────────────────────

    function test_forfeit_releasesReserve() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        uint256 reservedBefore = vault.taskReserve(taskId);
        assertGt(reservedBefore, 0);

        vm.warp(block.timestamp + 2 days);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        assertEq(vault.taskReserve(taskId), 0);
    }

    // ─── Cancel on unclaimed task: onCancel fires, no reserve to release ───────

    function test_cancel_noReserve_noRevert() public {
        bytes32 taskId = _createClaimTask();
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(vault.taskReserve(taskId), 0);
    }

    function test_expire_releasesReserve() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        uint256 reservedBefore = vault.taskReserve(taskId);
        assertGt(reservedBefore, 0);

        vm.warp(block.timestamp + 2 days);
        market.refundExpired(taskId, 0);

        assertEq(vault.taskReserve(taskId), 0);
    }

    // ─── Reserve release uses USD budget accounting ──────────────────────────

    function test_forfeit_releasesUsdBudgetNotTokenAmount() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        assertEq(budget.workerUsed(worker), REWARD_100_USDC);

        vm.warp(block.timestamp + 2 days);
        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        // Budget usage (USD) released back to zero, distinct from the token reserve.
        assertEq(budget.workerUsed(worker), 0);
    }

    // ─── Epoch budget exceeded ────────────────────────────────────────────────

    function test_epochBudget_globalCapExceeded_claimSucceedsNoReservation() public {
        vm.prank(owner);
        budget.setGlobalCapUsd(1); // 1 unit USD — too small for any reward

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        assertEq(vault.taskReserve(taskId), 0);
    }

    function test_epochBudget_capsInUsd() public {
        // Caps are denominated in USDC base units — a $100 reward consumes 100e6, not
        // a DREAMS-wei amount.
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        assertEq(budget.workerUsed(worker), REWARD_100_USDC);
        assertEq(budget.requesterUsed(requester), REWARD_100_USDC);
        assertEq(budget.globalUsed(), REWARD_100_USDC);
    }

    // ─── Epoch rollover resets per-account usage ──────────────────────────────

    function test_epochRollover_resetsUsage() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("w"))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("w"), 0)));

        assertGt(budget.workerUsed(worker), 0);

        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        assertEq(budget.workerUsed(worker), 0);
        assertEq(budget.requesterUsed(requester), 0);
        assertEq(budget.globalUsed(), 0);
        assertEq(budget.remaining(requester, worker), MAX_PER_TASK_USD);
    }

    // ─── Vault insufficient ───────────────────────────────────────────────────

    // A dry vault is an expected operational state, not an error: the pool drains as
    // rewards are paid, and the owner can sweep it outright. It must skip the bonus and
    // leave the USDC path alone — the same rule the Bounty sibling below and the
    // exhausted-EpochBudget test above already encode. Check hooks are NOT try-catch
    // wrapped by the Diamond, so a revert here blocked claimTask on EVERY hooked task
    // for as long as the vault was empty.
    function test_vaultInsufficient_claimSucceedsNoReservation() public {
        uint256 avail = vault.available();
        vm.prank(owner);
        vault.withdraw(owner, avail);
        assertEq(vault.available(), 0);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        (,,, uint256 reservedAmt,, address lockedWorker, bool reserved,,) = hook.rewardStates(taskId);
        assertEq(reservedAmt, 0, "no token reward may be owed against an empty vault");
        assertTrue(reserved, "the task is still worker-locked");
        assertEq(lockedWorker, worker);
        assertEq(vault.taskReserve(taskId), 0);

        // The budget was consumed for a reward that will never be owed, so it must be
        // handed back rather than stranded until the epoch rolls.
        assertEq(budget.workerUsed(worker), 0, "epoch budget must be released, not stranded");
        assertEq(budget.requesterUsed(requester), 0);
        assertEq(budget.globalUsed(), 0);
    }

    // The load-bearing half: with the vault dry, the task still runs to completion and
    // the worker is still paid in USDC. The bonus degrades, not the market.
    function test_vaultInsufficient_claim_paysUsdcWithoutBonus() public {
        uint256 avail = vault.available();
        vm.prank(owner);
        vault.withdraw(owner, avail);

        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 workerUsdcBefore = usdc.balanceOf(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertGt(usdc.balanceOf(worker), workerUsdcBefore, "USDC payout must not depend on the bonus vault");
        assertEq(hook.claimable(worker), 0, "no DREAMS may be credited when none were reserved");
    }

    function test_vaultInsufficient_bounty_skipsBonusNotUSDP() public {
        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 avail = vault.available();
        vm.prank(owner);
        vault.withdraw(owner, avail);

        uint256 workerUsdcBefore = usdc.balanceOf(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        assertGt(usdc.balanceOf(worker), workerUsdcBefore);
    }

    // Partial-fill round-trip: vault has SOME tokens available, but fewer than the
    // full USD-capped tokenReward. checkComplete must scale tokenReward down to
    // vaultAvail and recompute cappedUsd = tokenReward * 1e6 / rate so EpochBudget is
    // only consumed for what was actually paid out, not what was originally capped.
    function test_vaultInsufficient_bounty_partialFill_recomputesUsdRoundTrip() public {
        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        // Full payout would be rewardUsd(100e6) * bonusBps(100%) -> usdBonusValue=100e6,
        // then * rate(10e18) / 1e6 = 1000e18 DREAMS. Drain the vault down to 400e18
        // available (a partial fill), leaving enough that cappedUsd doesn't round to 0.
        uint256 avail = vault.available();
        uint256 partialAvail = 400 * 1e18;
        vm.prank(owner);
        vault.withdraw(owner, avail - partialAvail);
        assertEq(vault.available(), partialAvail);

        // Expected recomputed USD basis: 400e18 * 1e6 / 10e18 = 40e6 (40 USDC), not the
        // original 100e6 the budget check would otherwise have consumed.
        uint256 expectedRecomputedUsd = 40 * 1e6;

        vm.expectEmit(true, true, false, true);
        emit TaskTokenRewardHook.RewardPaid(
            taskId, worker, REWARD_100_USDC, expectedRecomputedUsd, DREAMS_PER_USDC, partialAvail
        );
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));

        assertEq(hook.claimable(worker), partialAvail, "worker must be credited exactly the vault-limited amount");
        assertEq(vault.available(), 0, "vault must be fully drained by the partial-fill payment");
    }

    // Multi-winner Bounty: one winner's per-worker EpochBudget is already exhausted
    // (cappedUsd resolves to 0 for them), the other winner has full budget headroom.
    // The exhausted winner's shortfall must `continue` past them without reverting
    // the loop or blocking payment to the other winner.
    function test_bounty_multiWinner_oneWorkerShortfall_doesNotBlockOthers() public {
        address worker2 = makeAddr("worker2");

        // Exhaust worker (worker1)'s entire per-worker epoch budget ahead of time, so
        // their cappedUsd for this task resolves to 0 via _min3(..., 0, ...). Lower the
        // worker cap first so a single checkAndConsume call (bounded by maxUsdPerTask)
        // can exhaust it without needing many chunked calls.
        vm.prank(owner);
        budget.setWorkerCapUsd(1 * 1e6);
        vm.prank(address(hook));
        budget.checkAndConsume(requester, worker, 1 * 1e6);
        assertEq(budget.remaining(requester, worker), 0);

        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("A"))));
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("B"))));

        address[] memory workers = new address[](2);
        workers[0] = worker;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000; // 50 USDC
        shares[1] = 5000; // 50 USDC
        bytes32[] memory deliverables = new bytes32[](2);
        deliverables[0] = keccak256("A");
        deliverables[1] = keccak256("B");

        uint256 worker2ClaimableBefore = hook.claimable(worker2);
        uint256 worker2UsdcBefore = usdc.balanceOf(worker2);

        // Must not revert despite worker's shortfall, and both workers' USDC payout
        // must still land regardless of the DREAMS-bonus outcome.
        _relay(requester, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, deliverables, 0)));

        assertEq(hook.claimable(worker), 0, "shortfall worker must receive no DREAMS bonus");
        assertGt(hook.claimable(worker2), worker2ClaimableBefore, "other worker's DREAMS bonus must not be blocked");
        assertGt(usdc.balanceOf(worker2), worker2UsdcBefore, "USDC payout must land for the unaffected worker");
    }

    // ─── EpochBudget branch coverage ─────────────────────────────────────────

    function test_epochBudget_taskCapExceeded_direct() public {
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(EpochBudget.TaskCapExceeded.selector, MAX_PER_TASK_USD + 1, MAX_PER_TASK_USD)
        );
        budget.checkAndConsume(requester, worker, MAX_PER_TASK_USD + 1);
    }

    function test_epochBudget_workerCapExceeded_direct() public {
        vm.prank(owner);
        budget.setWorkerCapUsd(100 * 1e6);
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(EpochBudget.WorkerCapExceeded.selector, worker, 200 * 1e6, 100 * 1e6));
        budget.checkAndConsume(requester, worker, 200 * 1e6);
    }

    function test_epochBudget_requesterCapExceeded_direct() public {
        vm.prank(owner);
        budget.setRequesterCapUsd(100 * 1e6);
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(EpochBudget.RequesterCapExceeded.selector, requester, 200 * 1e6, 100 * 1e6)
        );
        budget.checkAndConsume(requester, worker, 200 * 1e6);
    }

    function test_epochBudget_release_noOp_whenAmountExceedsUsed() public {
        // Hoist this out of the prank'd call: vm.prank only applies to the very next
        // external call, and evaluating budget.currentEpoch() inline as an argument would
        // consume it before release() runs, leaving release() to execute as the test
        // contract instead of the hook and revert with OnlyHook.
        uint64 epoch = budget.currentEpoch();
        vm.prank(address(hook));
        budget.release(requester, worker, 999 * 1e6, epoch);
        assertEq(budget.workerUsed(worker), 0);
    }

    function test_epochBudget_setEpochDuration_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(EpochBudget.EpochDurationZero.selector);
        budget.setEpochDuration(0);
    }

    function test_epochBudget_setGlobalCap_overflowReverts() public {
        vm.prank(owner);
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        budget.setGlobalCapUsd(uint256(type(uint192).max) + 1);
    }

    function test_epochBudget_setWorkerCap_overflowReverts() public {
        vm.prank(owner);
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        budget.setWorkerCapUsd(uint256(type(uint192).max) + 1);
    }

    function test_epochBudget_setRequesterCap_overflowReverts() public {
        vm.prank(owner);
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        budget.setRequesterCapUsd(uint256(type(uint192).max) + 1);
    }

    function test_epochBudget_setMaxUsdPerTask_overflowReverts() public {
        vm.prank(owner);
        vm.expectRevert(EpochBudget.CapExceedsUint192.selector);
        budget.setMaxUsdPerTask(uint256(type(uint192).max) + 1);
    }

    function test_onComplete_noOp_whenNotReserved() public {
        bytes32 taskId = _createBountyTask();
        vm.prank(address(market));
        ITMPCore.TaskContext memory ctx;
        ITMPCore.Verdict memory verdict;
        hook.onComplete(taskId, ctx, verdict);
        assertEq(vault.taskReserve(taskId), 0);
    }

    // ─── Bounty budget/vault clamp units ──────────────────────────────────────

    function test_bounty_budgetCapClampsBeforeConversion() public {
        // Cap the per-task USD budget below the task reward so the payout is scaled
        // down in USD terms, then converted to tokens — not clamped in token units.
        vm.prank(owner);
        budget.setMaxUsdPerTask(REWARD_100_USDC / 2); // cap at $50

        bytes32 taskId = _createBountyTask();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        uint256 before = hook.claimable(worker);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, keccak256("work"), 0)));
        uint256 credited = hook.claimable(worker) - before;

        // $50 * 10 DREAMS/USDC = 500 DREAMS
        assertEq(credited, 500 * 1e18);
    }

    // ─── Additional branch-coverage tests ────────────────────────────────────

    function test_checkComplete_bounty_noWorkerFound() public {
        bytes32 taskId = _createBountyTask();

        vm.prank(address(market));
        ITMPCore.TaskContext memory ctx;
        ctx.requester = requester;
        ITMPCore.Verdict memory verdict;
        vm.expectRevert(abi.encodeWithSelector(TaskTokenRewardHook.NoWorkerFound.selector, taskId));
        hook.checkComplete(taskId, ctx, verdict);
    }

    function test_onComplete_defensive_releasesReserveWhenPaidMissed() public {
        bytes32 taskId = _createClaimTask();
        _relay(worker, 0, abi.encodeCall(market.claimTask, (taskId, 0)));

        uint256 reservedBefore = vault.taskReserve(taskId);
        assertGt(reservedBefore, 0);

        vm.prank(address(market));
        ITMPCore.TaskContext memory ctx;
        ITMPCore.Verdict memory verdict;
        hook.onComplete(taskId, ctx, verdict);

        assertEq(vault.taskReserve(taskId), 0);
    }

    function test_onlyDiamond_nonDiamondCaller_reverts() public {
        ITMPCore.TaskContext memory ctx;
        ITMPCore.Verdict memory verdict;
        vm.expectRevert(TaskTokenRewardHook.CallerNotDiamond.selector);
        hook.checkComplete(bytes32(0), ctx, verdict);
    }
}
