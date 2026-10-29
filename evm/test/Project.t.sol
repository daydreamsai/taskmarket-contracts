// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPProject } from "../src/interfaces/ITMPProject.sol";
import { IDiamondLoupe } from "../src/interfaces/IDiamondLoupe.sol";
import { FundingPool } from "../src/FundingPool.sol";
import { ITMPFundingPool } from "../src/interfaces/ITMPFundingPool.sol";
import { TMP_AUCTION, TMP_AUCTION_DUTCH, TMP_BOUNTY, TMP_CLAIM } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev rev027: projects. Every task outcome that pays the requester is routed back to the
///      project while it is open, and to the backers' pot after; the unspent budget and the pot are
///      always booked. ProjectCrowdfunding.t.sol covers backers, the pot and claims in depth.
contract ProjectTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ITMPProject internal projects;
    ITMPFundingPool internal pools;
    FundingPool internal mockPool;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal admin = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal owner = address(0xB0);
    address internal worker = address(0xC0);
    address internal stranger = address(0xC1);
    address internal evaluator = address(0xE0);

    uint256 internal constant BUDGET = 10e6;
    uint256 internal constant REWARD = 4e6;
    uint256 internal constant DURATION = 7 days;
    uint64 internal constant LIFETIME = 30 days;
    bytes32 internal constant WORK = keccak256("work");

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
        usdc.mint(address(forwarder), 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _open() internal returns (uint256) {
        return _openWith(BUDGET);
    }

    function _openWith(uint256 budget) internal returns (uint256) {
        uint64 endsAt = uint64(block.timestamp) + LIFETIME;
        return abi.decode(
            _relay(owner, budget, abi.encodeCall(projects.createProject, (address(usdc), budget, endsAt, 30 days))),
            (uint256)
        );
    }

    function _taskCall(uint256 projectId, ITMPCore.TaskConfig memory cfg, ITMPCore.TaskEvaluatorConfig memory ev)
        internal
        view
        returns (bytes memory)
    {
        ITMPCore.TaskTerms memory t;
        t.version = 2;
        return abi.encodeCall(
            projects.createProjectTask,
            (
                projectId,
                cfg,
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                ev,
                t,
                address(0)
            )
        );
    }

    function _task(uint256 projectId, bytes4 mode, uint256 reward) internal returns (bytes32) {
        return abi.decode(
            _relay(owner, 0, _taskCall(projectId, taskConfig(reward, DURATION, mode), noEvaluatorConfig())), (bytes32)
        );
    }

    function _available(uint256 projectId) internal view returns (uint256) {
        return projects.getProject(projectId).available;
    }

    /// @dev The diamond holds exactly what it owes: the projects' budgets and the live tasks.
    function _assertBooked() internal view {
        assertEq(usdc.balanceOf(address(market)), market.totalLiabilities(), "balance equals liabilities");
        assertEq(usdc.balanceOf(address(mockPool)), mockPool.totalLiabilities(), "pool balance equals its books");
    }

    // -------------------------------------------------------------------------
    // Create, top up, close
    // -------------------------------------------------------------------------

    function test_CreateProject_BooksTheBudget() public {
        uint256 id = _open();
        ITMPProject.Project memory p = projects.getProject(id);
        assertEq(id, 1);
        assertEq(projects.projectCount(), 1);
        assertEq(p.owner, owner);
        assertEq(p.funded, BUDGET);
        assertEq(p.available, BUDGET);
        assertFalse(p.closed);
        uint256 shares = pools.sharesOf(projects.projectPoolId(id), owner);
        assertEq(shares, BUDGET * 1e12, "the opening budget buys the owner's shares");
        assertEq(market.totalLiabilities(), 0, "the diamond keeps none of the budget");
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET, "the budget is in the pool");
        _assertBooked();
    }

    function test_CreateProject_ForwardsTheBudgetToThePool() public {
        uint256 diamondBefore = usdc.balanceOf(address(market));
        uint256 id = _open();
        assertEq(usdc.balanceOf(address(market)), diamondBefore, "the diamond holds nothing after createProject");
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET);
        assertEq(pools.getPool(projects.projectPoolId(id)).funded, BUDGET);
    }

    function test_RevertWhen_CreateProject_TokenNotAllowed() public {
        bytes memory data =
            abi.encodeCall(projects.createProject, (address(0xDEAD), BUDGET, uint64(block.timestamp + 1), 30 days));
        vm.expectRevert(ITMPProject.ProjectTokenNotAllowed.selector);
        _relay(owner, BUDGET, data);
    }

    function test_RevertWhen_CreateProject_PaymentMismatch() public {
        bytes memory data = abi.encodeCall(
            projects.createProject, (address(usdc), BUDGET, uint64(block.timestamp + LIFETIME), 30 days)
        );
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(owner, BUDGET - 1, data);
    }

    function test_RevertWhen_CreateProject_ZeroBudgetOrPastEnd() public {
        bytes memory zero =
            abi.encodeCall(projects.createProject, (address(usdc), 0, uint64(block.timestamp + 1), 30 days));
        vm.expectRevert(ITMPProject.ProjectBudgetZero.selector);
        _relay(owner, 0, zero);

        bytes memory past =
            abi.encodeCall(projects.createProject, (address(usdc), BUDGET, uint64(block.timestamp), 30 days));
        vm.expectRevert(ITMPProject.ProjectEndNotInFuture.selector);
        _relay(owner, BUDGET, past);
    }

    function test_RevertWhen_CreateProject_NotThroughForwarder() public {
        vm.prank(owner);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        projects.createProject(address(usdc), BUDGET, uint64(block.timestamp + 1), 30 days);
    }

    function test_Fund_AddsToTheBudget() public {
        uint256 id = _open();
        _relay(owner, 5e6, abi.encodeCall(pools.fund, (projects.projectPoolId(id), 5e6, address(0))));
        ITMPProject.Project memory p = projects.getProject(id);
        assertEq(p.funded, BUDGET + 5e6);
        assertEq(p.available, BUDGET + 5e6);
        _assertBooked();
    }

    function test_Fund_ByAnyoneRecordsTheBacker() public {
        uint256 id = _open();
        bytes32 pool = projects.projectPoolId(id);
        vm.expectEmit(address(mockPool));
        emit ITMPFundingPool.PoolFunded(pool, stranger, stranger, 1e6, 1e6 * 1e12);
        _relay(stranger, 1e6, abi.encodeCall(pools.fund, (pool, 1e6, address(0))));
        uint256 shares = pools.sharesOf(pool, stranger);
        assertEq(shares, 1e6 * 1e12);
        assertEq(projects.getProject(id).funded, BUDGET + 1e6);
        _assertBooked();
    }

    function test_RevertWhen_Fund_PastEndDate() public {
        uint256 id = _open();
        bytes memory data = abi.encodeCall(pools.fund, (projects.projectPoolId(id), 1e6, address(0)));
        vm.warp(block.timestamp + LIFETIME);
        vm.expectRevert(ITMPFundingPool.PoolNotOpen.selector);
        _relay(owner, 1e6, data);
    }

    function test_Close_MakesTheUnspentBudgetThePot() public {
        uint256 id = _open();
        _task(id, TMP_BOUNTY, REWARD);
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectClosed(id, owner, BUDGET - REWARD);
        vm.prank(owner);
        projects.closeProject(id);
        assertEq(usdc.balanceOf(owner), 0, "close pays nobody");
        assertTrue(projects.getProject(id).closed);
        assertEq(_available(id), BUDGET - REWARD, "the unspent budget stays, now as the backers' pot");
        assertEq(market.totalLiabilities(), REWARD, "the open task stays booked");
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET - REWARD, "the pot is in the pool");
        _assertBooked();

        pools.claim(projects.projectPoolId(id), owner);
        assertEq(usdc.balanceOf(owner), BUDGET - REWARD, "the sole backer claims the whole pot");
        assertEq(market.totalLiabilities(), REWARD, "the open task stays booked");
        _assertBooked();
    }

    function test_RevertWhen_Close_ByStrangerBeforeTheEndDate() public {
        uint256 id = _open();
        vm.prank(stranger);
        vm.expectRevert(ITMPProject.NotProjectOwner.selector);
        projects.closeProject(id);
    }

    function test_Close_ByAnyoneAfterTheEndDate() public {
        uint256 id = _open();
        vm.warp(block.timestamp + LIFETIME);
        vm.prank(stranger);
        projects.closeProject(id);
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(_available(id), BUDGET);
        _assertBooked();
    }

    function test_RevertWhen_Close_Twice() public {
        uint256 id = _open();
        vm.startPrank(owner);
        projects.closeProject(id);
        vm.expectRevert(ITMPProject.ProjectAlreadyClosed.selector);
        projects.closeProject(id);
        vm.stopPrank();
    }

    function test_RevertWhen_UnknownProject() public {
        vm.expectRevert(ITMPProject.ProjectNotFound.selector);
        projects.getProject(7);
    }

    // -------------------------------------------------------------------------
    // Project tasks
    // -------------------------------------------------------------------------

    function test_CreateProjectTask_MovesTheRewardFromTheBudget() public {
        uint256 id = _open();
        bytes32 taskId = _task(id, TMP_BOUNTY, REWARD);
        assertEq(_available(id), BUDGET - REWARD);
        assertEq(projects.projectOf(taskId), id);
        assertEq(projects.taskCreatedBy(taskId), owner);
        assertEq(market.getTask(taskId).requester, owner);
        assertEq(market.getTask(taskId).reward, REWARD);
        assertEq(projects.projectTaskCount(id), 1);
        assertEq(projects.projectTasks(id, 0, 10)[0], taskId);
        assertEq(market.totalLiabilities(), REWARD, "the task escrow is booked in the diamond");
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET - REWARD, "the rest stays in the pool");
        _assertBooked();
    }

    function test_RevertWhen_CreateProjectTask_OverBudget() public {
        uint256 id = _open();
        bytes memory data = _taskCall(id, taskConfig(BUDGET + 1, DURATION, TMP_BOUNTY), noEvaluatorConfig());
        vm.expectRevert(abi.encodeWithSelector(ITMPFundingPool.PoolBalanceExceeded.selector, BUDGET, BUDGET + 1));
        _relay(owner, 0, data);
    }

    function test_RevertWhen_CreateProjectTask_ForwarderReportsAPayment() public {
        uint256 id = _open();
        bytes memory data = _taskCall(id, taskConfig(REWARD, DURATION, TMP_BOUNTY), noEvaluatorConfig());
        vm.expectRevert(ITMPCore.ForwardedPaymentMismatch.selector);
        _relay(owner, REWARD, data);
    }

    function test_RevertWhen_CreateProjectTask_NotOwnerOrOperator() public {
        uint256 id = _open();
        bytes memory data = _taskCall(id, taskConfig(REWARD, DURATION, TMP_BOUNTY), noEvaluatorConfig());
        vm.expectRevert(ITMPProject.NotProjectOperator.selector);
        _relay(stranger, 0, data);
    }

    function test_RevertWhen_CreateProjectTask_PastEndDate() public {
        uint256 id = _open();
        vm.warp(block.timestamp + LIFETIME);
        bytes memory data = _taskCall(id, taskConfig(REWARD, DURATION, TMP_BOUNTY), noEvaluatorConfig());
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _relay(owner, 0, data);
    }

    function test_RevertWhen_CreateProjectTask_Closed() public {
        uint256 id = _open();
        vm.prank(owner);
        projects.closeProject(id);
        bytes memory data = _taskCall(id, taskConfig(REWARD, DURATION, TMP_BOUNTY), noEvaluatorConfig());
        vm.expectRevert(ITMPProject.ProjectNotOpen.selector);
        _relay(owner, 0, data);
    }

    function test_CreateProjectTask_WithEvaluator_DrawsTheStakeToo() public {
        uint256 id = _open();
        ITMPCore.TaskEvaluatorConfig memory ev = ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: 1e6,
            evaluatorFeeBps: 0,
            evaluationWindow: 3 days,
            appealWindow: 2 days,
            disputeResolver: address(0xD0)
        });
        bytes32 taskId =
            abi.decode(_relay(owner, 0, _taskCall(id, taskConfig(REWARD, DURATION, TMP_BOUNTY), ev)), (bytes32));
        assertEq(_available(id), BUDGET - REWARD - 1e6);

        // A cancel returns the reward and the evaluator stake to the project.
        _relay(owner, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(_available(id), BUDGET);
        _assertBooked();
    }

    // -------------------------------------------------------------------------
    // Where a task's money goes
    // -------------------------------------------------------------------------

    function test_Accepted_SpendsTheReward() public {
        uint256 id = _open();
        bytes32 taskId = _task(id, TMP_BOUNTY, REWARD);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(owner, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(_available(id), BUDGET - REWARD);
        assertEq(market.totalLiabilities(), 0);
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET - REWARD);
        _assertBooked();
    }

    function test_CreateProjectTask_EmitsPoolDrawn() public {
        uint256 id = _open();
        vm.expectEmit(true, false, false, true, address(market));
        emit ITMPProject.ProjectPoolDrawn(id, bytes32(0), REWARD);
        _task(id, TMP_BOUNTY, REWARD);
    }

    function test_Fund_RelayedHoldsNothingAndCreditsTheBacker() public {
        uint256 id = _open();
        bytes32 pool = projects.projectPoolId(id);
        uint256 diamondBefore = usdc.balanceOf(address(market));
        _relay(stranger, 3e6, abi.encodeCall(projects.fund, (pool, 3e6, stranger)));
        assertEq(usdc.balanceOf(address(market)), diamondBefore, "the diamond holds nothing after fund");
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET + 3e6);
        assertEq(pools.sharesOf(pool, stranger), 3e6 * 1e12);
    }

    function test_RevertWhen_Fund_NotThroughForwarder() public {
        bytes32 pool = projects.projectPoolId(_open());
        vm.expectRevert();
        projects.fund(pool, 1e6, address(0));
    }

    function test_Claim_RelayedPaysTheBacker() public {
        uint256 id = _open();
        vm.prank(owner);
        projects.closeProject(id);
        _relay(stranger, 0, abi.encodeCall(projects.claim, (projects.projectPoolId(id), owner)));
        assertEq(usdc.balanceOf(owner), BUDGET, "the pool pays the backer, not the diamond");
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function test_InitFundingPool_OnlyOnceAndOnlyByOwner() public {
        assertEq(projects.fundingPool(), address(mockPool));
        vm.prank(admin);
        vm.expectRevert(ITMPProject.FundingPoolAlreadySet.selector);
        projects.initFundingPool(address(mockPool));
        vm.prank(stranger);
        vm.expectRevert();
        projects.initFundingPool(address(mockPool));
    }

    function test_RemovedPoolSelectorsAreGone() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(market));
        assertEq(loupe.facetAddress(ITMPFundingPool.getPool.selector), address(0));
        assertEq(loupe.facetAddress(ITMPFundingPool.sharesOf.selector), address(0));
        assertEq(loupe.facetAddress(ITMPFundingPool.claimable.selector), address(0));
    }

    function test_Cancelled_RefundsTheProject() public {
        uint256 id = _open();
        bytes32 taskId = _task(id, TMP_BOUNTY, REWARD);
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, taskId, REWARD);
        _relay(owner, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(_available(id), BUDGET);
        assertEq(usdc.balanceOf(owner), 0, "nothing left the diamond");
        _assertBooked();
    }

    function test_Expired_RefundsTheProject() public {
        uint256 id = _open();
        bytes32 taskId = _task(id, TMP_BOUNTY, REWARD);
        vm.warp(block.timestamp + DURATION + 1);
        _relay(owner, 0, abi.encodeCall(market.refundExpired, (taskId, 0)));
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(_available(id), BUDGET);
        _assertBooked();
    }

    function test_Auction_UnspentRemainderReturnsToTheProject() public {
        uint256 id = _open();
        bytes32 taskId = abi.decode(
            _relay(
                owner,
                0,
                _taskCall(
                    id, taskConfig(REWARD, DURATION, TMP_AUCTION, 0, 1 days, TMP_AUCTION_DUTCH), noEvaluatorConfig()
                )
            ),
            (bytes32)
        );
        uint256 price = 3e6;
        _relay(worker, 0, abi.encodeCall(market.acceptAuction, (taskId, price)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        _relay(owner, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker, WORK, 0)));
        assertEq(_available(id), BUDGET - price, "the unspent 1 USDC came back");
        _assertBooked();
    }

    function test_RequesterTimeout_RefundsTheProject() public {
        uint256 id = _open();
        bytes32 taskId = _task(id, TMP_BOUNTY, REWARD);
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, WORK)));
        // The decision window is seven days past the task's expiry; anyone may time the requester out.
        vm.warp(market.getTask(taskId).expiryTime + 7 days + 1);
        vm.prank(stranger);
        market.requesterTimeout(taskId);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(_available(id), BUDGET, "the refund came back to the project");
        assertEq(usdc.balanceOf(owner), 0);
        _assertBooked();
    }

    function test_RefundAfterTheEndDate_GoesToThePot() public {
        uint256 id = _open();
        bytes32 taskId = _task(id, TMP_BOUNTY, REWARD);
        // The end date stops new tasks, not this one: it runs to its own expiry.
        vm.warp(block.timestamp + LIFETIME + 1);
        vm.expectEmit(address(market));
        emit ITMPProject.ProjectRefunded(id, taskId, REWARD);
        _relay(owner, 0, abi.encodeCall(market.refundExpired, (taskId, 0)));
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(_available(id), BUDGET, "the refund joined the unspent budget in the pot");
        _assertBooked();
        // Nobody closed it, but past its end date the pot is the backers' already.
        pools.claim(projects.projectPoolId(id), owner);
        assertEq(usdc.balanceOf(owner), BUDGET);
        _assertBooked();
    }

    function test_RefundAfterClose_GoesToThePot() public {
        uint256 id = _open();
        bytes32 taskId = _task(id, TMP_BOUNTY, REWARD);
        vm.prank(owner);
        projects.closeProject(id);
        _relay(owner, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(usdc.balanceOf(owner), 0);
        assertEq(_available(id), BUDGET);
        assertEq(market.totalLiabilities(), 0, "the pot is in the pool");
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET);
        _assertBooked();
        pools.claim(projects.projectPoolId(id), owner);
        assertEq(usdc.balanceOf(owner), BUDGET);
        assertEq(market.totalLiabilities(), 0);
        _assertBooked();
    }

    function test_RefundedBudget_FundsTheNextTask() public {
        uint256 id = _open();
        bytes32 first = _task(id, TMP_BOUNTY, BUDGET);
        _relay(owner, 0, abi.encodeCall(market.cancelTask, (first, 0)));
        bytes32 second = _task(id, TMP_CLAIM, BUDGET);
        assertEq(_available(id), 0);
        assertEq(projects.projectTaskCount(id), 2);
        assertEq(projects.projectTasks(id, 1, 5)[0], second);
        _assertBooked();
    }

    function test_SweepSurplus_NeverTakesTheBudget() public {
        uint256 id = _open();
        _task(id, TMP_BOUNTY, REWARD);
        usdc.mint(address(market), 1e6);
        vm.prank(admin);
        market.sweepSurplus();
        assertEq(usdc.balanceOf(address(market)), REWARD, "only the task escrow is in the diamond");
        assertEq(usdc.balanceOf(address(mockPool)), BUDGET - REWARD, "the budget is in the pool");
        _assertBooked();
    }

    function test_OrdinaryTask_StillRefundsTheRequester() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, TMP_BOUNTY),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig(),
                _v2Terms()
            )
        );
        bytes32 taskId = abi.decode(_relay(owner, REWARD, data), (bytes32));
        assertEq(projects.projectOf(taskId), 0);
        _relay(owner, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        assertEq(usdc.balanceOf(owner), REWARD);
        _assertBooked();
    }

    function _v2Terms() internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 2;
    }
}
