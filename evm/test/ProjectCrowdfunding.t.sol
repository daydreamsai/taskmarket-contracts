// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
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
        pools = ITMPFundingPool(address(market));
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
            _relay(owner, budget, abi.encodeCall(projects.createProject, (address(usdc), budget, endsAt))), (uint256)
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
    function _assertSolvent() internal view {
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities(), "balance equals liabilities");
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
        vm.expectEmit(address(market));
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
        assertEq(market.totalLiabilities(), FUNDED + 1e6);
    }

    function test_Fund_OnBehalfOfSomeoneElse() public {
        vm.expectEmit(address(market));
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
        usdc.approve(address(market), 3e6);
        vm.expectEmit(address(market));
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
        assertEq(market.totalLiabilities(), 0);
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

        vm.expectEmit(address(market));
        emit ITMPFundingPool.PoolClosed(pool, leftover);
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectClosed(id, owner, leftover);
        _close(owner);
        assertTrue(_p().closed);
        assertTrue(_p().settled);
        assertEq(_p().potIn, leftover);
        assertEq(_p().available, leftover, "close moves no money");
        assertEq(market.totalLiabilities(), leftover, "the pot stays booked until claimed");
        assertEq(usdc.balanceOf(owner), 0, "close pays nobody");

        assertEq(pools.claimable(pool, owner), leftover * BUDGET / FUNDED);
        vm.expectEmit(address(market));
        emit ITMPFundingPool.PoolClaimed(pool, owner, 6e6);
        assertEq(_claim(owner), 6e6);
        assertEq(_claim(alice), 3.6e6);
        assertEq(_claim(bob), 2.4e6);
        assertEq(usdc.balanceOf(owner), 6e6);
        assertEq(usdc.balanceOf(alice), 3.6e6);
        assertEq(usdc.balanceOf(bob), 2.4e6);
        assertEq(_p().claimed, leftover);
        assertEq(_p().potIn, leftover, "claims do not change the pot");
        assertEq(market.totalLiabilities(), 0);
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
        assertEq(market.totalLiabilities(), 0);
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
        assertEq(market.totalLiabilities(), 0);
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
        assertEq(market.totalLiabilities(), 0);
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
        pools.claim(pool, alice);
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
        assertEq(usdc.balanceOf(address(market)), FUNDED, "only the surplus left");
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
        assertEq(market.totalLiabilities(), (3e6 + 1) + dust, "the live task and the dust stay booked");
        vm.expectRevert(ITMPFundingPool.NothingToClaim.selector);
        pools.claim(pool, owner);

        _cancel(later);
        leftover += 3e6 + 1; // 26,000,000
        uint256 total = leftover / 3; // 8,666,666
        assertEq(_claim(owner), total - each);
        assertEq(_claim(alice), total - each);
        assertEq(_claim(bob), total - each);
        assertEq(market.totalLiabilities(), leftover - 3 * total, "dust is what rounding leaves of the whole pot");
        assertLt(market.totalLiabilities(), 3, "under one base unit per backer");
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
        assertEq(market.totalLiabilities(), BUDGET + potIn - paid, "only the dust stays booked");
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
        vm.expectEmit(address(market));
        emit ITMPFundingPool.PoolSpent(pool, REWARD);
        bytes32 taskId = _task(REWARD);
        assertEq(_p().available, BUDGET - REWARD);
        assertEq(_p().outstanding, REWARD, "the live task's reward is outstanding");

        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(owner, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        assertEq(_p().outstanding, 0, "paid out: it left the pool's value");
        assertEq(_p().available, BUDGET - REWARD);

        bytes32 second = _task(1e6);
        vm.expectEmit(address(market));
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
        assertLe(market.totalLiabilities(), 1, "only rounding dust stays");
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
        assertEq(market.totalLiabilities(), 0);
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
        assertLe(market.totalLiabilities(), 2);
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

        vm.expectEmit(address(market));
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
        assertEq(market.totalLiabilities(), 0);
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
        bytes memory tooFar = abi.encodeCall(projects.createProject, (address(usdc), BUDGET, latest + 1));
        vm.expectRevert(ITMPProject.ProjectEndTooFar.selector);
        _relay(owner, BUDGET, tooFar);
        uint256 ok = abi.decode(
            _relay(owner, BUDGET, abi.encodeCall(projects.createProject, (address(usdc), BUDGET, latest))), (uint256)
        );
        assertEq(projects.getProject(ok).endsAt, latest, "exactly 365 days is allowed");
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
    // Many backers, interleaved
    // -------------------------------------------------------------------------

    /// @dev Any number of backers funding between spends, payouts and refunds, then claims
    ///      interleaved with refunds after the close: the diamond always holds exactly what it
    ///      owes, outstanding is what the live tasks hold, claims never exceed the pot and what
    ///      stays unclaimed is under one base unit per backer.
    function testFuzz_ManyBackers_InterleavedSpendsRefundsFundingAndClaims(uint256 seed, uint8 nB, uint8 nSteps)
        public
    {
        uint256 n = bound(nB, 1, 12);
        uint256 steps = bound(nSteps, 1, 24);
        address[] memory backers = new address[](n + 1);
        backers[0] = owner;
        for (uint256 i = 1; i <= n; ++i) {
            backers[i] = address(uint160(0x10000 + i));
        }
        bytes32[] memory live = new bytes32[](steps);
        uint256[] memory rewards = new uint256[](steps);
        uint256 nLive;
        uint256 held; // what the live tasks hold

        for (uint256 k; k < steps; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 action = r % 4;
            if (action == 1 && _p().available > 0) {
                uint256 reward = bound(r >> 16, 1, _p().available);
                live[nLive] = _task(reward);
                rewards[nLive++] = reward;
                held += reward;
            } else if (action >= 2 && nLive > 0) {
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
            } else {
                _back(backers[(r >> 8) % (n + 1)], bound(r >> 16, 1, 1e13));
            }
            assertEq(_p().outstanding, held, "outstanding is what the live tasks hold");
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
        for (uint256 i; i <= n; ++i) {
            if (pools.claimable(pool, backers[i]) > 0) paid += _claim(backers[i]);
        }
        uint256 potIn = _p().potIn;
        assertEq(_p().claimed, paid);
        assertLe(paid, potIn, "claims never exceed the pot");
        assertLe(potIn - paid, n + 1, "dust is under one base unit per backer");
        assertEq(market.totalLiabilities(), potIn - paid, "only the dust stays booked");
    }
}
