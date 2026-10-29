// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { TMP_BOUNTY, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { LibGuards } from "../src/libraries/LibGuards.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev027: crowdfunded projects through funding pools. A project's budget is its pool; anyone
///      funds it while it is open, for themselves or on behalf of someone else, relayed or
///      directly, buying shares at the pool's value: what it holds plus what its live tasks hold.
///      Once the project is closed or past its end date, what the pool holds and every later
///      refund of its tasks are a pot the backers claim pro rata to their shares. Every
///      step checks the diamond holds exactly what it owes, so the pot is booked until claimed and
///      rounding never overdraws it.
contract ProjectCrowdfundingTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    ITMPFundingPool internal pools;
    FundingPool internal mockPool;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal owner = address(0xB0);
    address internal alice = address(0xBA);
    address internal bob = address(0xBB);
    address internal worker = address(0xC0);
    address internal stranger = address(0xC1);
    address internal router = address(0xD1);

    uint256 internal constant BUDGET = 10e6;
    uint256 internal constant ALICE = 6e6;
    uint256 internal constant BOB = 4e6;
    uint256 internal constant FUNDED = BUDGET + ALICE + BOB;
    uint256 internal constant REWARD = 8e6;
    uint256 internal constant DURATION = 7 days;
    uint64 internal constant LIFETIME = 30 days;
    bytes32 internal constant WORK = keccak256("work");
    /// @dev Shares the first credit mints per base unit; a pool that has neither spent nor won
    ///      anything keeps that price.
    uint256 internal constant SCALE = 1e12;

    uint256 internal id;
    bytes32 internal pool;

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        market = deployDiamond(admin, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        projects = ITMPProject(address(market));
        mockPool = initMockPool(address(market), admin);
        pools = ITMPFundingPool(address(mockPool));
        usdc.mint(address(forwarder), 1e18);
        id = _open(BUDGET);
        pool = projects.projectPoolId(id);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _open(uint256 budget) internal returns (uint256) {
        uint64 endsAt = uint64(block.timestamp) + LIFETIME;
        return abi.decode(
            _relay(owner, budget, abi.encodeCall(projects.createProject, (address(usdc), budget, endsAt, 30 days))),
            (uint256)
        );
    }

    /// @dev `backer` funds the pool for itself through the forwarder.
    function _back(address backer, uint256 amount) internal {
        _relay(backer, amount, abi.encodeCall(pools.fund, (pool, amount, address(0))));
        _assertSolvent();
    }

    /// @dev Owner 10, alice 6, bob 4: funded 20.
    function _backAll() internal {
        _back(alice, ALICE);
        _back(bob, BOB);
    }

    function _taskCall(uint256 reward) internal view returns (bytes memory) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(reward, DURATION, TMP_BOUNTY),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
    }

    function _task(uint256 reward) internal returns (bytes32 taskId) {
        taskId = abi.decode(_relay(owner, 0, _taskCall(reward)), (bytes32));
        _assertSolvent();
    }

    /// @dev Spends `reward` of the budget: a task the owner accepts.
    function _spend(uint256 reward) internal {
        bytes32 taskId = _task(reward);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(owner, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        _assertSolvent();
    }

    function _cancel(bytes32 taskId) internal {
        _relay(owner, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        _assertSolvent();
    }

    function _close(address by) internal {
        vm.prank(by);
        projects.closeProject(id);
        _assertSolvent();
    }

    function _claim(address backer) internal returns (uint256 amount) {
        vm.prank(stranger);
        amount = pools.claim(pool, backer);
        _assertSolvent();
    }

    function _p() internal view returns (ITMPFundingPool.PoolInfo memory) {
        return pools.getPool(pool);
    }

    /// @dev Nothing but project money ever enters the diamond in these tests, so it holds exactly
    ///      what it owes: every live task, every budget and every unclaimed pot.
    /// @dev Everything booked, in the diamond (task escrow) and in the pool (budget and pot).
    function _booked() internal view returns (uint256) {
        return market.totalLiabilities() + mockPool.totalLiabilities();
    }

    function _assertSolvent() internal view {
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities(), "balance equals liabilities");
        assertEq(usdc.balanceOf(address(mockPool)), mockPool.totalLiabilities(), "pool balance equals its books");
    }

    // -------------------------------------------------------------------------
    // The project's pool
    // -------------------------------------------------------------------------

    function test_CreateProject_OpensItsPool() public view {
        ITMPFundingPool.PoolInfo memory p = _p();
        assertEq(pool, keccak256(abi.encode(keccak256("taskmarket.project"), id)), "the documented derivation");
        assertEq(p.token, address(usdc));
        assertEq(p.module, keccak256("taskmarket.project"));
        assertEq(p.closesAt, projects.getProject(id).endsAt, "the pool closes at the project's end date");
        assertFalse(p.closed);
        assertFalse(p.settled);
        assertEq(p.funded, BUDGET);
        assertEq(p.available, BUDGET);
        assertEq(p.potIn, 0);
        assertEq(pools.sharesOf(pool, owner), BUDGET * SCALE, "the opening budget buys the owner's shares");
        assertEq(p.totalShares, BUDGET * SCALE);
        assertEq(p.outstanding, 0);
    }

    function test_RevertWhen_ProjectPoolId_UnknownProject() public {
        vm.expectRevert(ITMPProject.ProjectNotFound.selector);
        projects.projectPoolId(id + 1);
    }

    // -------------------------------------------------------------------------
    // Funding
    // -------------------------------------------------------------------------

    function test_Backers_RecordTheirContributions() public {
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolFunded(pool, alice, alice, ALICE, ALICE * SCALE);
        _back(alice, ALICE);
        _back(bob, BOB);
        _back(alice, 1e6);

        assertEq(pools.sharesOf(pool, alice), (ALICE + 1e6) * SCALE, "a second funding adds to the first");
        assertEq(pools.sharesOf(pool, bob), BOB * SCALE);
        assertEq(_p().totalShares, (FUNDED + 1e6) * SCALE);
        assertEq(pools.claimable(pool, owner), 0, "nothing is claimable while the pool is open");
        assertEq(_p().funded, FUNDED + 1e6, "funded is the sum of the contributions");
        assertEq(_p().available, FUNDED + 1e6);
        assertEq(projects.getProject(id).available, FUNDED + 1e6, "getProject reads the pool");
        assertEq(_booked(), FUNDED + 1e6);
    }

    function test_Fund_OnBehalfOfSomeoneElse() public {
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolFunded(pool, alice, bob, 2e6, 2e6 * SCALE);
        _relay(alice, 2e6, abi.encodeCall(pools.fund, (pool, 2e6, bob)));
        _assertSolvent();
        assertEq(pools.sharesOf(pool, bob), 2e6 * SCALE, "the shares are bob's");
        assertEq(pools.sharesOf(pool, alice), 0, "alice paid but holds no share");

        _close(owner);
        assertEq(_claim(bob), 2e6);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, alice);
    }

    /// @dev A router or another contract funds directly: the diamond pulls the money from it with
    ///      transferFrom and credits the user it names.
    function test_Fund_DirectlyPullsFromTheCaller() public {
        usdc.mint(router, 3e6);
        vm.startPrank(router);
        usdc.approve(address(mockPool), 3e6);
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolFunded(pool, router, alice, 3e6, 3e6 * SCALE);
        pools.fund(pool, 3e6, alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(router), 0);
        assertEq(pools.sharesOf(pool, alice), 3e6 * SCALE);
        _assertSolvent();
    }

    function test_RevertWhen_Fund_DirectlyWithoutAllowance() public {
        usdc.mint(router, 3e6);
        vm.prank(router);
        vm.expectRevert();
        pools.fund(pool, 3e6, alice);
        assertEq(pools.sharesOf(pool, alice), 0);
    }

    function test_Owner_BacksItsOwnProject() public {
        _back(owner, 5e6);
        assertEq(pools.sharesOf(pool, owner), (BUDGET + 5e6) * SCALE);
        _back(alice, 5e6);
        _close(owner);
        assertEq(_claim(owner), 15e6, "the owner's share counts its opening budget and its later funding");
        assertEq(_claim(alice), 5e6);
        assertEq(_booked(), 0);
    }

    function test_RevertWhen_Fund_Closed() public {
        _close(owner);
        vm.expectRevert(ITMPFundingPool.PoolNotOpen.selector);
        _relay(alice, 1e6, abi.encodeCall(pools.fund, (pool, 1e6, address(0))));
    }

    function test_RevertWhen_Fund_PastClosesAt() public {
        vm.warp(_p().closesAt);
        vm.expectRevert(ITMPFundingPool.PoolNotOpen.selector);
        _relay(alice, 1e6, abi.encodeCall(pools.fund, (pool, 1e6, address(0))));
    }

    function test_RevertWhen_Fund_ZeroOrPaymentMismatch() public {
        vm.expectRevert(ITMPFundingPool.PoolAmountZero.selector);
        _relay(alice, 0, abi.encodeCall(pools.fund, (pool, 0, address(0))));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(alice, 1e6 - 1, abi.encodeCall(pools.fund, (pool, 1e6, address(0))));
    }

    function test_RevertWhen_UnknownPool() public {
        bytes32 unknown = keccak256("no such pool");
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        _relay(alice, 1e6, abi.encodeCall(pools.fund, (unknown, 1e6, address(0))));
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.claim(unknown, alice);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.getPool(unknown);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.sharesOf(unknown, alice);
        vm.expectRevert(ITMPFundingPool.PoolNotFound.selector);
        pools.claimable(unknown, alice);
    }

    function test_RevertWhen_Fund_Paused() public {
        vm.prank(admin);
        market.pause();
        vm.expectRevert(LibGuards.EnforcedPause.selector);
        _relay(alice, 1e6, abi.encodeCall(pools.fund, (pool, 1e6, address(0))));
    }

    // -------------------------------------------------------------------------
    // Spending
    // -------------------------------------------------------------------------

    function test_RevertWhen_Spend_OverAvailable() public {
        _backAll();
        _task(REWARD);
        uint256 left = FUNDED - REWARD;
        bytes memory data = _taskCall(left + 1);
        vm.expectRevert(abi.encodeWithSelector(ITMPFundingPool.PoolBalanceExceeded.selector, left, left + 1));
        _relay(owner, 0, data);
    }

    // -------------------------------------------------------------------------
    // Closing settles the pool; claims are pro rata
    // -------------------------------------------------------------------------

    function test_CloseEarlyByOwner_SharesTheLeftoverProRata() public {
        _backAll();
        _spend(REWARD);
        uint256 leftover = FUNDED - REWARD; // 12

        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolClosed(pool, leftover);
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectClosed(id, owner, leftover);
        _close(owner);
        assertTrue(_p().closed);
        assertTrue(_p().settled);
        assertEq(_p().potIn, leftover);
        assertEq(_p().available, leftover, "close moves no money");
        assertEq(_booked(), leftover, "the pot stays booked until claimed");
        assertEq(usdc.balanceOf(owner), 0, "close pays nobody");

        assertEq(pools.claimable(pool, owner), leftover * BUDGET / FUNDED);
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolClaimed(pool, owner, 6e6);
        assertEq(_claim(owner), 6e6);
        assertEq(_claim(alice), 3.6e6);
        assertEq(_claim(bob), 2.4e6);
        assertEq(usdc.balanceOf(owner), 6e6);
        assertEq(usdc.balanceOf(alice), 3.6e6);
        assertEq(usdc.balanceOf(bob), 2.4e6);
        assertEq(_p().claimed, leftover);
        assertEq(_p().potIn, leftover, "claims do not change the pot");
        assertEq(_booked(), 0);
    }

    function test_CloseByAnyoneAfterEndDate_SettlesThePool() public {
        _backAll();
        vm.warp(_p().closesAt);
        assertTrue(_p().settled, "past closesAt the pool is settled without a transaction");
        assertFalse(_p().closed);
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectClosed(id, stranger, FUNDED);
        _close(stranger);
        assertEq(_claim(owner), BUDGET);
        assertEq(_claim(alice), ALICE);
        assertEq(_claim(bob), BOB);
        assertEq(_booked(), 0);
    }

    function test_RevertWhen_CloseByStrangerBeforeEndDate() public {
        _backAll();
        vm.prank(alice);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        projects.closeProject(id);
    }

    // -------------------------------------------------------------------------
    // Refunds after the project stops being open
    // -------------------------------------------------------------------------

    function test_RefundsAfterClose_AddToThePotAndAreClaimable() public {
        _backAll();
        bytes32 first = _task(REWARD);
        bytes32 second = _task(2e6);
        _close(owner);
        uint256 leftover = FUNDED - REWARD - 2e6; // 10
        assertEq(_p().potIn, leftover);

        // Alice claims before any refund comes back.
        assertEq(_claim(alice), leftover * ALICE / FUNDED);

        // The first refund lands in the pot, booked, and is shared out the same way.
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, first, REWARD);
        _cancel(first);
        leftover += REWARD;
        assertEq(_p().potIn, leftover);
        assertEq(pools.claimable(pool, alice), REWARD * ALICE / FUNDED, "alice's share of the new money");
        assertEq(_claim(alice), REWARD * ALICE / FUNDED);

        // The second after that; bob and the owner have not claimed at all and get it all at once.
        _cancel(second);
        leftover += 2e6;
        assertEq(leftover, FUNDED, "everything came back");
        assertEq(_claim(owner), BUDGET);
        assertEq(_claim(bob), BOB);
        assertEq(_claim(alice), 2e6 * ALICE / FUNDED);
        assertEq(usdc.balanceOf(alice), ALICE, "three claims add up to alice's whole share");
        assertEq(_booked(), 0);
    }

    function test_RefundsPastEndDate_GoToThePotBeforeAndAfterClose() public {
        _backAll();
        bytes32 taskId = _task(REWARD);
        vm.warp(_p().closesAt);

        // Past the end date but not closed: the unspent budget is the pot already, and claimable.
        assertEq(_p().potIn, FUNDED - REWARD);
        assertEq(_claim(bob), (FUNDED - REWARD) * BOB / FUNDED, "the pot is claimable before anyone closes");

        // The task's refund joins the pot and is shared out the same way.
        _relay(owner, 0, abi.encodeCall(market.refundExpired, (taskId, 0)));
        _assertSolvent();
        assertEq(_p().potIn, FUNDED);
        assertEq(_claim(bob), REWARD * BOB / FUNDED);
        assertEq(usdc.balanceOf(bob), BOB);

        // Closing afterwards changes nothing in the shares.
        _close(stranger);
        assertEq(_p().potIn, FUNDED);
        assertEq(_claim(owner), BUDGET);
        assertEq(_claim(alice), ALICE);
        assertEq(_booked(), 0);
    }

    // -------------------------------------------------------------------------
    // Claims
    // -------------------------------------------------------------------------

    function test_Claim_ByAThirdPartyPaysTheBacker() public {
        _backAll();
        _close(owner);
        vm.prank(stranger);
        uint256 paid = pools.claim(pool, alice);
        assertEq(paid, ALICE);
        assertEq(usdc.balanceOf(alice), ALICE);
        assertEq(usdc.balanceOf(stranger), 0, "the caller gets nothing");
        assertEq(pools.claimable(pool, alice), 0);
        _assertSolvent();
    }

    function test_Claim_ThroughTheForwarderPaysTheBacker() public {
        _backAll();
        _close(owner);
        _relay(alice, 0, abi.encodeCall(pools.claim, (pool, bob)));
        assertEq(usdc.balanceOf(bob), BOB);
        assertEq(usdc.balanceOf(alice), 0);
        _assertSolvent();
    }

    function test_RevertWhen_ClaimTwice() public {
        _backAll();
        _close(owner);
        _claim(alice);
        assertEq(pools.claimable(pool, alice), 0, "a second claim has nothing to pay");
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, alice);
        assertEq(usdc.balanceOf(alice), ALICE, "paid once");
    }

    function test_RevertWhen_ClaimWhileOpen() public {
        _backAll();
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, alice);
    }

    function test_RevertWhen_ClaimByANonBacker() public {
        _backAll();
        _close(owner);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, stranger);
    }

    function test_RevertWhen_ClaimWhilePaused() public {
        _backAll();
        _close(owner);
        vm.prank(admin);
        market.pause();
        vm.expectRevert(LibGuards.EnforcedPause.selector);
        projects.claim(pool, alice);
        vm.prank(admin);
        market.unpause();
        assertEq(_claim(alice), ALICE);
    }

    function test_SweepSurplus_NeverTakesThePot() public {
        _backAll();
        _close(owner);
        usdc.mint(address(market), 1e6);
        vm.prank(admin);
        market.sweepSurplus();
        assertEq(usdc.balanceOf(address(mockPool)), FUNDED, "the pot is in the pool, out of the sweep's reach");
        assertEq(usdc.balanceOf(address(market)), 0, "only the surplus was in the diamond");
        _assertSolvent();
        assertEq(_claim(alice), ALICE);
    }

    // -------------------------------------------------------------------------
    // Rounding dust
    // -------------------------------------------------------------------------

    /// @dev Three equal backers and a pot that does not divide by three. Each share rounds down,
    ///      the remainder (under one base unit per backer) stays booked and unclaimable, and the
    ///      diamond still holds exactly its liabilities. A later refund is shared cumulatively, so
    ///      the dust does not grow with it.
    function test_Dust_StaysBookedAndBounded() public {
        _back(alice, BUDGET);
        _back(bob, BUDGET);
        bytes32 later = _task(3e6 + 1);
        _spend(4e6);
        _close(owner);
        uint256 leftover = 3 * BUDGET - 4e6 - 3e6 - 1; // 22,999,999
        assertEq(_p().potIn, leftover);

        uint256 each = leftover / 3; // 7,666,666
        assertEq(_claim(owner), each);
        assertEq(_claim(alice), each);
        assertEq(_claim(bob), each);
        uint256 dust = leftover - 3 * each;
        assertEq(dust, 1);
        assertEq(_p().claimed, 3 * each);
        assertEq(_booked(), (3e6 + 1) + dust, "the live task and the dust stay booked");
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, owner);

        _cancel(later);
        leftover += 3e6 + 1; // 26,000,000
        uint256 total = leftover / 3; // 8,666,666
        assertEq(_claim(owner), total - each);
        assertEq(_claim(alice), total - each);
        assertEq(_claim(bob), total - each);
        assertEq(_booked(), leftover - 3 * total, "dust is what rounding leaves of the whole pot");
        assertLt(_booked(), 3, "under one base unit per backer");
    }

    /// @dev Any contributions, any spend, refunds after the close, claims in between: the claims
    ///      never exceed the pot, what is left unclaimed after everyone claims is under one base
    ///      unit per backer, and the diamond always holds exactly what it owes.
    function testFuzz_ClaimsNeverExceedThePot(uint96 a, uint96 b, uint96 c, uint256 spend, uint256 back) public {
        uint256 ownerC = bound(a, 1, 1e15);
        uint256 aliceC = bound(b, 1, 1e15);
        uint256 bobC = bound(c, 1, 1e15);
        id = _open(ownerC);
        pool = projects.projectPoolId(id);
        _back(alice, aliceC);
        _back(bob, bobC);
        uint256 funded = ownerC + aliceC + bobC;
        vm.assume(funded >= 2e6);
        spend = bound(spend, 1e6, funded / 2);
        back = bound(back, 1e6, funded - spend);
        _spend(spend);
        bytes32 later = _task(back);
        _close(owner);

        uint256 paid;
        if (pools.claimable(pool, alice) > 0) paid += _claim(alice);
        _cancel(later);
        if (pools.claimable(pool, owner) > 0) paid += _claim(owner);
        if (pools.claimable(pool, alice) > 0) paid += _claim(alice);
        if (pools.claimable(pool, bob) > 0) paid += _claim(bob);

        uint256 potIn = _p().potIn;
        assertEq(potIn, funded - spend);
        assertEq(_p().claimed, paid);
        assertLe(paid, potIn, "claims never exceed the pot");
        assertLt(potIn - paid, 3, "dust is under one base unit per backer");
        // setUp's project still holds its budget; of this one only the dust stays booked.
        assertEq(_booked(), BUDGET + potIn - paid, "only the dust stays booked");
    }

    // -------------------------------------------------------------------------
    // Share pricing: a backer pays the pool's value when it joins
    // -------------------------------------------------------------------------

    /// @dev A Claim task whose worker stakes `stake` and forfeits it to the project, then is
    ///      cancelled: the reward comes back and the stake is a windfall the pool keeps.
    function _windfall(uint256 reward, uint256 stake) internal {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        t.penaltyTo = ITMPCore.PenaltyTo.Requester;
        bytes memory data = abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(reward, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
        bytes32 taskId = abi.decode(_relay(owner, 0, data), (bytes32));
        _relay(worker, stake, abi.encodeCall(market.claimTask, (taskId, stake)));
        vm.warp(market.getTask(taskId).expiryTime + 1);
        _relay(owner, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
        _cancel(taskId);
    }

    function test_Spend_MovesMoneyToOutstanding_UntilTheTaskFinishes() public {
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolSpent(pool, REWARD);
        bytes32 taskId = _task(REWARD);
        assertEq(_p().available, BUDGET - REWARD);
        assertEq(_p().outstanding, REWARD, "the live task's reward is outstanding");

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(owner, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        assertEq(_p().outstanding, 0, "paid out: it left the pool's value");
        assertEq(_p().available, BUDGET - REWARD);

        bytes32 second = _task(1e6);
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolRefunded(pool, 1e6);
        _cancel(second);
        assertEq(_p().outstanding, 0, "refunded: back in available");
        assertEq(_p().available, BUDGET - REWARD);
    }

    /// @dev Security review M1: the owner spends its whole opening budget, then alice backs the
    ///      project and the owner closes at once. The pool is worth nothing when alice joins, so
    ///      her shares are all but the whole pool and she gets her money back (rounding keeps
    ///      under one base unit), instead of half of it.
    function test_LateBacker_AfterTheBudgetWasSpent_GetsTheirMoneyBack() public {
        _spend(BUDGET);
        assertEq(_p().available + _p().outstanding, 0, "the pool is worth nothing");
        _back(alice, BUDGET);
        _close(owner);
        uint256 a = _claim(alice);
        assertGe(a, BUDGET - 1, "alice gets all but a base unit back");
        assertLe(a, BUDGET);
        assertEq(pools.claimable(pool, owner), 0, "the owner's spent budget buys nothing of alice's money");
        assertLe(_booked(), 1, "only rounding dust stays");
    }

    /// @dev Security review M1, partly spent: half the budget is gone when alice joins, so her 10
    ///      buys two thirds of a pool worth 15, and the close splits it 10 to her and 5 to the owner.
    function test_LateBacker_AfterPartOfTheBudgetWasSpent_PaysTheValueLeft() public {
        _spend(BUDGET / 2);
        _back(alice, BUDGET);
        assertEq(pools.sharesOf(pool, alice), 2 * BUDGET * SCALE, "10 buys at 0.5 per share unit");
        _close(owner);
        assertEq(_claim(alice), BUDGET);
        assertEq(_claim(owner), BUDGET / 2);
        assertEq(_booked(), 0);
    }

    /// @dev Front-run: the owner spends its whole budget on accepted work right before a large
    ///      backing lands, then closes. The backing pays the pool's value, nothing, so the backer
    ///      gets all of it back.
    function test_LateBacker_FrontRunBySpend_GetsTheirMoneyBack() public {
        _spend(BUDGET);
        _back(alice, 990e6);
        _close(owner);
        assertGe(_claim(alice), 990e6 - 1);
    }

    /// @dev Security review L1: a forfeited worker stake comes back to the open pool before alice
    ///      joins. The windfall raises the pool's value, so alice pays for it and does not take it
    ///      from the owner.
    function test_LateBacker_DoesNotCaptureAnEarlierWindfall() public {
        uint256 stake = 1e6;
        _windfall(BUDGET, stake);
        assertEq(_p().available, BUDGET + stake, "windfall in the pool");
        assertEq(_p().outstanding, 0);
        _back(alice, 990e6);
        _close(owner);
        uint256 a = _claim(alice);
        uint256 o = _claim(owner);
        assertLe(a, 990e6, "alice gets no more than she paid in");
        assertGe(a, 990e6 - 1);
        assertGe(o, BUDGET + stake - 1, "the owner keeps the windfall");
        assertLe(_booked(), 2);
    }

    /// @dev A first-depositor (inflation) attack: the owner opens with one base unit, then a
    ///      forfeited stake of its own worker pushes a large windfall into the pool, raising a
    ///      share's value as far as it can, and a donation straight to the diamond tries the same.
    ///      Value is internal bookkeeping, and a share starts at 10^-12 of a base unit, so a later
    ///      backer still gets its money back but under one base unit.
    function test_InflationAttack_DoesNotDiluteALaterBacker() public {
        id = _open(1);
        pool = projects.projectPoolId(id);
        _windfall(1, 1000e6);
        assertEq(_p().available, 1000e6 + 1);
        usdc.mint(address(market), 1000e6);
        uint256 amount = 1500e6 + 7;
        _relay(alice, amount, abi.encodeCall(pools.fund, (pool, amount, address(0))));
        vm.prank(owner);
        projects.closeProject(id);
        vm.prank(stranger);
        uint256 a = pools.claim(pool, alice);
        assertGe(a, amount - 1, "the attacker takes under one base unit");
        assertLe(a, amount);
    }

    /// @dev Pricing ignores tokens sent straight to the diamond: they are unbooked surplus, not
    ///      pool value.
    function test_Donation_DoesNotChangeTheSharePrice() public {
        usdc.mint(address(market), 50e6);
        _relay(alice, ALICE, abi.encodeCall(pools.fund, (pool, ALICE, address(0))));
        assertEq(pools.sharesOf(pool, alice), ALICE * SCALE);
    }

    /// @dev Security review L2: a reward increase on a project task is drawn from the pool, with
    ///      no payment from the requester's wallet, and comes back to the pool on cancel without
    ///      becoming a donation to the backers.
    function test_RewardIncrease_DrawsFromThePool() public {
        _back(alice, BUDGET);
        bytes32 taskId = _task(1e6);
        bytes memory raise = abi.encodeCall(market.updateTask, (taskId, 6e6, 0, 0, 0));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(owner, 5e6, raise);

        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolSpent(pool, 5e6);
        _relay(owner, 0, raise);
        _assertSolvent();
        assertEq(market.getTask(taskId).reward, 6e6);
        assertEq(_p().available, 2 * BUDGET - 6e6, "the increase came out of the pool");
        assertEq(_p().outstanding, 6e6);

        // Lowering it again refunds the pool and takes it out of outstanding.
        _relay(owner, 0, abi.encodeCall(market.updateTask, (taskId, 2e6, 0, 0, 0)));
        _assertSolvent();
        assertEq(_p().available, 2 * BUDGET - 2e6);
        assertEq(_p().outstanding, 2e6);

        _cancel(taskId);
        assertEq(_p().available, 2 * BUDGET);
        assertEq(_p().outstanding, 0);
        _close(owner);
        assertEq(_claim(alice), BUDGET, "alice gets her own money, no part of a top-up");
        assertEq(_claim(owner), BUDGET);
        assertEq(_booked(), 0);
    }

    /// @dev Security review L2: an evaluator stake added to a project task is drawn from the pool.
    function test_EvaluatorStake_DrawsFromThePool() public {
        bytes32 taskId = _task(REWARD);
        bytes memory assign =
            abi.encodeCall(market.assignEvaluator, (taskId, address(0xE0), 1e6, 0, 3 days, 2 days, address(0xD0)));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(owner, 1e6, assign);
        _relay(owner, 0, assign);
        _assertSolvent();
        assertEq(_p().available, BUDGET - REWARD - 1e6);
        assertEq(_p().outstanding, REWARD + 1e6);
        _cancel(taskId);
        assertEq(_p().available, BUDGET);
        assertEq(_p().outstanding, 0);
    }

    /// @dev A top-up needs an open project and the budget for it.
    function test_RevertWhen_TopUp_ProjectNotOpenOrOverBudget() public {
        bytes32 taskId = _task(REWARD);
        bytes memory over = abi.encodeCall(market.updateTask, (taskId, BUDGET + 1, 0, 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(ITMPFundingPool.PoolBalanceExceeded.selector, BUDGET - REWARD, BUDGET + 1 - REWARD)
        );
        _relay(owner, 0, over);
        _close(owner);
        bytes memory raise = abi.encodeCall(market.updateTask, (taskId, REWARD + 1, 0, 0, 0));
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _relay(owner, 0, raise);
    }

    /// @dev drawTopUp spends pool money, so only the diamond itself (updateTask) may call it.
    function test_RevertWhen_DrawTopUp_NotTheDiamond() public {
        bytes32 taskId = _task(REWARD);
        vm.expectRevert(ITMPProject.NotDiamond.selector);
        vm.prank(owner);
        projects.drawTopUp(taskId, owner, 1);
        bytes memory direct = abi.encodeCall(projects.drawTopUp, (taskId, owner, 1));
        vm.expectRevert(ITMPProject.NotDiamond.selector);
        _relay(owner, 0, direct);
        assertEq(_p().available, BUDGET - REWARD, "nothing was drawn");
    }

    // -------------------------------------------------------------------------
    // Lifetime cap, relayed payments, the diamond as a backer
    // -------------------------------------------------------------------------

    /// @dev Security review L3: a project ends at most 365 days after it is created.
    function test_RevertWhen_CreateProject_PastTheLifetimeCap() public {
        uint64 latest = uint64(block.timestamp + 365 days);
        bytes memory tooFar = abi.encodeCall(projects.createProject, (address(usdc), BUDGET, latest + 1, 30 days));
        vm.expectRevert(ITMPProject.ProjectEndTooFar.selector);
        _relay(owner, BUDGET, tooFar);
        uint256 ok = abi.decode(
            _relay(owner, BUDGET, abi.encodeCall(projects.createProject, (address(usdc), BUDGET, latest, 30 days))),
            (uint256)
        );
        assertEq(projects.getProject(ok).endsAt, latest, "exactly 365 days is allowed");
    }

    // -------------------------------------------------------------------------
    // Task grace period (second security review L-2)
    // -------------------------------------------------------------------------

    uint32 internal constant GRACE = 30 days;

    function _taskCallFor(uint256 projectId, uint256 reward, uint256 duration) internal pure returns (bytes memory) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.encodeCall(
            ITMPProject.createProjectTask,
            (
                projectId,
                taskConfig(reward, duration, TMP_BOUNTY),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
    }

    function _openWithGrace(uint32 grace) internal returns (uint256) {
        uint64 endsAt = uint64(block.timestamp) + LIFETIME;
        return abi.decode(
            _relay(owner, BUDGET, abi.encodeCall(projects.createProject, (address(usdc), BUDGET, endsAt, grace))),
            (uint256)
        );
    }

    /// @dev The grace period is the creator's choice, 0 to 90 days, fixed at creation, reported
    ///      by getProject and in ProjectCreated.
    function test_CreateProject_TaskGraceBounds() public {
        uint64 endsAt = uint64(block.timestamp) + LIFETIME;
        bytes memory tooLong =
            abi.encodeCall(projects.createProject, (address(usdc), BUDGET, endsAt, uint32(90 days + 1)));
        vm.expectRevert(ITMPProject.ProjectGraceTooLong.selector);
        _relay(owner, BUDGET, tooLong);

        vm.expectEmit(true, true, false, true, address(market));
        emit ITMPProject.ProjectCreated(id + 1, owner, BUDGET, endsAt, 90 days);
        uint256 longest = _openWithGrace(90 days);
        assertEq(projects.getProject(longest).taskGraceSecs, 90 days);
        uint256 none = _openWithGrace(0);
        assertEq(projects.getProject(none).taskGraceSecs, 0);
        assertEq(projects.getProject(id).taskGraceSecs, GRACE);
    }

    /// @dev A project task may expire at most at the end date plus the grace period.
    function test_ProjectTask_ExpiryAtMostEndPlusGrace() public {
        uint256 longest = LIFETIME + GRACE;
        vm.expectRevert(ITMPProject.ProjectTaskPastGrace.selector);
        _relay(owner, 0, _taskCallFor(id, 1e6, longest + 1));
        bytes32 taskId = abi.decode(_relay(owner, 0, _taskCallFor(id, 1e6, longest)), (bytes32));
        assertEq(market.getTask(taskId).expiryTime, projects.getProject(id).endsAt + GRACE);
        _assertSolvent();
    }

    /// @dev With no grace period every project task ends by the project's end date.
    function test_ProjectTask_ZeroGraceEndsByTheEndDate() public {
        id = _openWithGrace(0);
        vm.expectRevert(ITMPProject.ProjectTaskPastGrace.selector);
        _relay(owner, 0, _taskCallFor(id, 1e6, LIFETIME + 1));
        _relay(owner, 0, _taskCallFor(id, 1e6, LIFETIME));
        _assertSolvent();
    }

    /// @dev updateTask may not extend a project task's expiry past the end date plus the grace
    ///      period; shortening it and extending within it are fine.
    function test_RevertWhen_UpdateTask_ExtendsPastGrace() public {
        bytes32 taskId = _task(1e6);
        uint256 latest = projects.getProject(id).endsAt + GRACE;
        bytes memory tooFar = abi.encodeCall(market.updateTask, (taskId, 0, latest + 1, 0, 0));
        vm.expectRevert(ITMPProject.ProjectTaskPastGrace.selector);
        _relay(owner, 0, tooFar);
        _relay(owner, 0, abi.encodeCall(market.updateTask, (taskId, 0, latest, 0, 0)));
        assertEq(market.getTask(taskId).expiryTime, latest);
        _relay(owner, 0, abi.encodeCall(market.updateTask, (taskId, 0, block.timestamp + 1 days, 0, 0)));
        assertEq(market.getTask(taskId).expiryTime, block.timestamp + 1 days);
    }

    /// @dev Once the pool has settled no project task's expiry may be extended at all, even
    ///      within the grace period; shortening it still is allowed.
    function test_RevertWhen_UpdateTask_ExtendsAfterSettlement() public {
        bytes32 taskId = _task(1e6);
        uint256 expiry = market.getTask(taskId).expiryTime;
        _close(owner);
        bytes memory extend = abi.encodeCall(market.updateTask, (taskId, 0, expiry + 1, 0, 0));
        vm.expectRevert(ITMPProject.ProjectTaskPastGrace.selector);
        _relay(owner, 0, extend);
        _relay(owner, 0, abi.encodeCall(market.updateTask, (taskId, 0, expiry - 1, 0, 0)));
        assertEq(market.getTask(taskId).expiryTime, expiry - 1);
    }

    /// @dev Security review I1: claim and closeProject refuse a relayed payment, which would
    ///      otherwise land unbooked.
    function test_RevertWhen_ClaimOrClose_WithARelayedPayment() public {
        bytes memory close = abi.encodeCall(projects.closeProject, (id));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(owner, 3e6, close);
        _relay(owner, 0, close);
        bytes memory claim = abi.encodeCall(pools.claim, (pool, owner));
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(stranger, 3e6, claim);
        _relay(stranger, 0, claim);
        assertEq(usdc.balanceOf(owner), BUDGET);
        _assertSolvent();
    }

    /// @dev Security review I2: the diamond cannot hold shares of its own pools.
    function test_RevertWhen_Fund_OnBehalfOfTheDiamond() public {
        bytes memory data = abi.encodeCall(pools.fund, (pool, 2e6, address(market)));
        vm.expectRevert(ITMPFundingPool.PoolInvalidBacker.selector);
        _relay(alice, 2e6, data);
    }

    // -------------------------------------------------------------------------
    // Second security review: outstanding while a worker stake is held, share generations
    // -------------------------------------------------------------------------

    address internal constant EVALUATOR = address(0xE0);
    address internal constant RESOLVER = address(0xD0);

    function _claimTaskCall(uint256 reward) internal view returns (bytes memory) {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        t.penaltyTo = ITMPCore.PenaltyTo.Requester;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                id,
                taskConfig(reward, DURATION, TMP_CLAIM),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                t,
                address(0)
            )
        );
    }

    /// @dev A Claim project task with an evaluator staking `evalStake` from the pool, claimed by
    ///      the worker with `stake` and submitted, so it is in Review.
    function _claimTaskInReview(uint256 reward, uint256 evalStake, uint256 stake) internal returns (bytes32 taskId) {
        taskId = abi.decode(_relay(owner, 0, _claimTaskCall(reward)), (bytes32));
        _relay(
            owner,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, EVALUATOR, evalStake, 0, 3 days, 2 days, RESOLVER))
        );
        _relay(worker, stake, abi.encodeCall(market.claimTask, (taskId, stake)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _assertSolvent();
    }

    function _awardTo(uint256 amount) internal view returns (ITMPCore.Award[] memory a) {
        a = new ITMPCore.Award[](1);
        a[0] = ITMPCore.Award({ worker: worker, amount: amount, rank: 1 });
    }

    function _verdict(bytes32 taskId, ITMPCore.VerdictType v, ITMPCore.Award[] memory awards) internal {
        _relay(EVALUATOR, 0, abi.encodeCall(market.evaluate, (taskId, v, 10000, 10000, bytes32(0), awards)));
        _assertSolvent();
    }

    /// @dev Second security review M-1: the evaluator's verdict pays its stake back while the
    ///      task, Appealing, still holds the worker's stake. The worker's stake must not stand in
    ///      for the evaluator stake in outstanding, or a later backer buys at a value the pool
    ///      does not have. Fair split: the pool is worth 6 when alice pays 10, so she owns 10/16
    ///      of the 12 left after the worker is paid. Before the fix she claimed 6.
    function test_Outstanding_DropsWhenTheEvaluatorIsPaidWhileAWorkerStakeIsHeld() public {
        uint256 r = 4e6;
        uint256 e = 4e6;
        bytes32 taskId = _claimTaskInReview(r, e, 4e6);
        assertEq(_p().outstanding, r + e);
        _verdict(taskId, ITMPCore.VerdictType.APPROVE, _awardTo(r));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Appealing));
        assertEq(_p().outstanding, r, "only the reward is still pool money in the task");
        assertEq(_p().available + _p().outstanding, BUDGET - e, "the value lost the evaluator stake");

        _back(alice, BUDGET);
        vm.warp(block.timestamp + 3 days);
        market.finalizeVerdict(taskId);
        _assertSolvent();
        assertEq(_p().outstanding, 0);
        _close(owner);
        assertApproxEqAbs(_claim(alice), 7.5e6, 1, "alice pays the value the pool had");
        assertApproxEqAbs(_claim(owner), 4.5e6, 1);
        assertLe(_booked(), 2, "only rounding dust stays");
    }

    /// @dev Second security review M-1: an evaluator timeout sends the evaluator stake to the
    ///      protocol while the worker's stake is held; it leaves outstanding too.
    function test_Outstanding_DropsOnEvaluatorTimeoutWhileAWorkerStakeIsHeld() public {
        uint256 r = 4e6;
        uint256 e = 3e6;
        bytes32 taskId = _claimTaskInReview(r, e, 5e6);
        vm.warp(block.timestamp + 4 days);
        market.evaluatorTimeout(taskId);
        _assertSolvent();
        assertEq(_p().outstanding, r, "the forfeited evaluator stake left the value");
        assertEq(_p().available, BUDGET - r - e);
        _back(alice, 3e6);
        assertEq(pools.sharesOf(pool, alice), 3e6 * BUDGET * SCALE / (BUDGET - e), "3 buys at the value 7");
    }

    /// @dev Second security review M-1: on an appealed verdict the evaluator stake leaves
    ///      outstanding at the verdict, the appeal moves nothing, and the resolution pays the
    ///      reward out.
    function test_Outstanding_FollowsAnAppealedVerdict() public {
        uint256 r = 4e6;
        uint256 e = 2e6;
        bytes32 taskId = _claimTaskInReview(r, e, 1e6);
        _verdict(taskId, ITMPCore.VerdictType.REJECT, new ITMPCore.Award[](0));
        assertEq(_p().outstanding, r);
        _relay(worker, 0, abi.encodeCall(market.appeal, (taskId)));
        assertEq(_p().outstanding, r, "an appeal moves no money");
        vm.prank(RESOLVER);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, _awardTo(r));
        _assertSolvent();
        assertEq(_p().outstanding, 0);
        assertEq(_p().available, BUDGET - r - e);
    }

    /// @dev Second security review L-1: draining the pool to nothing and refilling it used to
    ///      multiply the share supply by the funded amount each cycle, until a credit overflowed
    ///      and funding reverted for good (from the seventh cycle of 1,000 USDC). A pool worth
    ///      nothing now starts a new share generation, so funding never bricks.
    function test_DrainAndRefill_NeverBricksFunding() public {
        _spend(BUDGET);
        for (uint256 i; i < 20; ++i) {
            uint256 amount = 1000e6;
            _back(alice, amount);
            assertEq(_p().totalShares, amount * SCALE, "a new generation mints at the first price");
            assertEq(pools.sharesOf(pool, alice), amount * SCALE);
            _spend(amount);
        }
        assertEq(_p().generation, 20);
    }

    /// @dev Second security review L-1: the old generation's backers hold nothing of the new
    ///      generation's money, and the new backers get all of it back.
    function test_NewGeneration_OldBackersTakeNothing() public {
        _backAll();
        _spend(FUNDED);
        assertEq(pools.sharesOf(pool, alice), ALICE * SCALE, "shares still read until a new generation");
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolSharesReset(pool, 1);
        _back(bob, 5e6);
        assertEq(pools.sharesOf(pool, owner), 0, "an old generation's shares count as zero");
        assertEq(pools.sharesOf(pool, alice), 0);
        assertEq(pools.sharesOf(pool, bob), 5e6 * SCALE, "bob's old shares were replaced");
        _back(alice, 5e6);
        assertEq(pools.sharesOf(pool, alice), 5e6 * SCALE);
        _close(owner);
        assertEq(pools.claimable(pool, owner), 0);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, owner);
        assertEq(_claim(alice), 5e6);
        assertEq(_claim(bob), 5e6);
        assertEq(_booked(), 0);
    }

    /// @dev Second security review L-1: a pool worth nothing that nobody funds again keeps its
    ///      generation and its backers' shares; there is nothing in the pot for them to claim.
    function test_ZeroValuePool_KeepsItsGenerationUntilFunded() public {
        _back(alice, BUDGET);
        _spend(2 * BUDGET);
        _close(owner);
        assertEq(_p().generation, 0);
        assertEq(pools.sharesOf(pool, alice), BUDGET * SCALE);
        assertEq(pools.claimable(pool, alice), 0);
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, alice);
    }

    // -------------------------------------------------------------------------
    // Many backers, interleaved
    // -------------------------------------------------------------------------

    /// @dev A Claim task of the many-backers fuzz test: its worker, the pool money it holds,
    ///      where it is in review and the deadline of that stage.
    struct ClaimCase {
        bytes32 id;
        address worker;
        uint256 reward;
        uint256 held;
        uint8 stage; // 0 Review, 1 Appealing, 2 delivered after an evaluator timeout, 3 Disputed
        bool rejected;
        uint256 deadline;
    }

    ClaimCase[] internal claimCases;

    /// @dev Creates a Claim task with an evaluator staking from the pool and a worker staking its
    ///      own money, through to Review. Windows are an hour, so the fuzz test can step past them.
    function _fuzzClaimTask(uint256 r, uint256 k) internal returns (uint256 drawn) {
        uint256 avail = _p().available;
        uint256 reward = bound(r >> 16, 1, avail);
        uint256 evalStake = bound(r >> 80, 0, avail - reward);
        uint256 stake = bound(r >> 144, 1, 1e13);
        address w = address(uint160(0x20000 + k));
        bytes32 taskId = abi.decode(_relay(owner, 0, _claimTaskCall(reward)), (bytes32));
        _relay(
            owner,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, EVALUATOR, evalStake, 0, 1 hours, 1 hours, RESOLVER))
        );
        _relay(w, stake, abi.encodeCall(market.claimTask, (taskId, stake)));
        _relay(w, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        drawn = reward + evalStake;
        claimCases.push(ClaimCase(taskId, w, reward, drawn, 0, false, block.timestamp + 1 hours));
    }

    function _awardFor(address w, uint256 amount) internal pure returns (ITMPCore.Award[] memory a) {
        a = new ITMPCore.Award[](1);
        a[0] = ITMPCore.Award({ worker: w, amount: amount, rank: 1 });
    }

    /// @dev Moves Claim task `j` one step on: a verdict (approve or reject) or an evaluator
    ///      timeout from Review; an appeal or the verdict's finalisation from Appealing; the
    ///      resolution of a dispute; the requester's acceptance after a timeout. Returns how much
    ///      pool money the task stopped holding; a finished task is removed.
    function _fuzzClaimStep(uint256 j, uint256 r) internal returns (uint256 released) {
        ClaimCase storage c = claimCases[j];
        released = c.held;
        uint256 choice = r % 3;
        bool done;
        if (c.stage == 0) {
            if (choice == 2 || block.timestamp > c.deadline) {
                if (block.timestamp <= c.deadline) vm.warp(c.deadline + 1);
                market.evaluatorTimeout(c.id);
                c.stage = 2;
            } else {
                c.rejected = choice == 1;
                _relay(
                    EVALUATOR,
                    0,
                    abi.encodeCall(
                        market.evaluate,
                        (
                            c.id,
                            c.rejected ? ITMPCore.VerdictType.REJECT : ITMPCore.VerdictType.APPROVE,
                            10000,
                            10000,
                            bytes32(0),
                            c.rejected ? new ITMPCore.Award[](0) : _awardFor(c.worker, c.reward)
                        )
                    )
                );
                c.stage = 1;
                c.deadline = block.timestamp + 1 hours;
            }
            c.held = c.reward;
            released -= c.reward;
        } else if (c.stage == 1) {
            if (choice == 0 && block.timestamp < c.deadline) {
                _relay(c.worker, 0, abi.encodeCall(market.appeal, (c.id)));
                c.stage = 3;
                released = 0;
            } else {
                if (block.timestamp < c.deadline) vm.warp(c.deadline);
                market.finalizeVerdict(c.id);
                done = true;
            }
        } else if (c.stage == 3) {
            vm.prank(RESOLVER);
            market.resolveDispute(c.id, ITMPCore.VerdictType.APPROVE, _awardFor(c.worker, c.reward));
            done = true;
        } else {
            _relay(owner, 0, abi.encodeCall(market.acceptSubmission, (c.id, c.worker, WORK, 0)));
            done = true;
        }
        if (done) {
            claimCases[j] = claimCases[claimCases.length - 1];
            claimCases.pop();
        }
    }

    /// @dev Any number of backers funding between spends, payouts and refunds, then claims
    ///      interleaved with refunds after the close: the diamond always holds exactly what it
    ///      owes, outstanding is what the live tasks hold, claims never exceed the pot and what
    ///      stays unclaimed is under one base unit per backer. Besides Bounty tasks, Claim tasks
    ///      with a worker stake and an evaluator stake go through approvals, rejections, evaluator
    ///      timeouts, appeals and dispute resolutions, so the worker's stake is held while the
    ///      evaluator stake leaves (second security review M-1) and forfeited stakes come back to
    ///      the pool as windfalls. A pool spent to nothing and funded again starts a new share
    ///      generation (L-1).
    function testFuzz_ManyBackers_InterleavedSpendsRefundsFundingAndClaims(uint256 seed, uint8 nB, uint8 nSteps)
        public
    {
        vm.prank(admin);
        market.setMinEvaluationWindowSecs(1 hours);
        uint256 n = bound(nB, 1, 12);
        uint256 steps = bound(nSteps, 1, 32);
        address[] memory backers = new address[](n + 1);
        backers[0] = owner;
        for (uint256 i = 1; i <= n; ++i) {
            backers[i] = address(uint160(0x10000 + i));
        }
        bytes32[] memory live = new bytes32[](steps);
        uint256[] memory rewards = new uint256[](steps);
        uint256 nLive;
        uint256 held; // the pool money the live tasks hold

        for (uint256 k; k < steps; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 action = r % 6;
            if (action == 1 && _p().available > 0) {
                uint256 reward = bound(r >> 16, 1, _p().available);
                live[nLive] = _task(reward);
                rewards[nLive++] = reward;
                held += reward;
            } else if ((action == 2 || action == 3) && nLive > 0) {
                uint256 j = (r >> 8) % nLive;
                bytes32 taskId = live[j];
                held -= rewards[j];
                if (action == 2) {
                    _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
                    _relay(owner, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
                } else {
                    _cancel(taskId);
                }
                live[j] = live[--nLive];
                rewards[j] = rewards[nLive];
            } else if (action == 4 && _p().available > 0) {
                held += _fuzzClaimTask(r, k);
            } else if (action == 5 && claimCases.length > 0) {
                held -= _fuzzClaimStep((r >> 8) % claimCases.length, r >> 200);
            } else {
                _back(backers[(r >> 8) % (n + 1)], bound(r >> 16, 1, 1e13));
            }
            assertEq(_p().outstanding, held, "outstanding is the pool money the live tasks hold");
            _assertSolvent();
        }

        _close(owner);
        uint256 paid;
        for (uint256 j; j < nLive; ++j) {
            for (uint256 i; i <= n; ++i) {
                if (uint256(keccak256(abi.encode(seed, j, i))) % 3 == 0 && pools.claimable(pool, backers[i]) > 0) {
                    paid += _claim(backers[i]);
                }
            }
            _cancel(live[j]);
        }
        // Settle every Claim task; refunds and forfeited stakes reach the pot between claims.
        for (uint256 guard; claimCases.length > 0 && guard < 8 * steps; ++guard) {
            uint256 r = uint256(keccak256(abi.encode(seed, "settle", guard)));
            _fuzzClaimStep(r % claimCases.length, r >> 8);
            _assertSolvent();
            uint256 i = (r >> 128) % (n + 1);
            if (pools.claimable(pool, backers[i]) > 0) paid += _claim(backers[i]);
        }
        assertEq(claimCases.length, 0, "every Claim task settled");
        assertEq(_p().outstanding, 0);
        for (uint256 i; i <= n; ++i) {
            if (pools.claimable(pool, backers[i]) > 0) paid += _claim(backers[i]);
        }
        uint256 potIn = _p().potIn;
        assertEq(_p().claimed, paid);
        assertLe(paid, potIn, "claims never exceed the pot");
        assertLe(potIn - paid, n + 1, "dust is under one base unit per backer");
        assertEq(_booked(), potIn - paid, "only the dust stays booked");
    }
}
