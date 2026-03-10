// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/TaskMarket.sol";
import "../src/interfaces/ITMP.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10 ** 6);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract TaskMarketTest is Test {
    TaskMarket public market;
    MockERC20 public usdc;

    address public owner = address(1);
    address public feeRecipient = address(2);
    address public requester = address(3);
    address public worker1 = address(4);
    address public worker2 = address(5);
    address public server = address(6);

    uint16 public defaultFeeBps = 500;

    uint256 public constant REWARD = 100 * 10 ** 6;
    uint256 public constant DURATION = 7 days;

    /// @dev Helper: pre-compute the next contract-generated task ID for a given requester
    function _nextTaskId(address _requester) internal view returns (bytes32) {
        uint256 nonce = market.requesterNonce(_requester);
        return keccak256(abi.encode(block.chainid, address(market), _requester, nonce));
    }

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20();

        TaskMarket implementation = new TaskMarket();
        bytes memory initData = abi.encodeCall(
            TaskMarket.initialize, (address(usdc), feeRecipient, defaultFeeBps)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        market = TaskMarket(address(proxy));
        market.addForwarder(server);
        vm.stopPrank();

        // Server holds USDC to escrow on behalf of requesters (received via X402)
        usdc.mint(server, 10000 * 10 ** 6);
        usdc.mint(worker1, 1000 * 10 ** 6);
        usdc.mint(worker2, 1000 * 10 ** 6);
    }

    function test_Constructor() public view {
        assertEq(address(market.usdcToken()), address(usdc));
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.defaultFeeBps(), defaultFeeBps);
        assertTrue(market.trustedForwarders(server));
    }

    // -----------------------------------------------------------------------
    // ERC-165 / supportsInterface
    // -----------------------------------------------------------------------

    function test_SupportsInterface_ITMP() public view {
        assertTrue(market.supportsInterface(type(ITMP).interfaceId));
    }

    function test_SupportsInterface_ERC165() public view {
        assertTrue(market.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterface_Unknown() public view {
        assertFalse(market.supportsInterface(bytes4(0xdeadbeef)));
    }

    // -----------------------------------------------------------------------
    // createTask — basic happy paths
    // -----------------------------------------------------------------------

    function test_CreateTask_Bounty() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);

        bytes32 expectedId = _nextTaskId(requester);

        vm.expectEmit(true, true, false, true);
        emit TaskMarket.TaskCreated(expectedId, requester, REWARD, block.timestamp + DURATION, market.BOUNTY());

        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        assertEq(taskId, expectedId);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
        assertEq(task.reward, REWARD);
        assertEq(task.mode, market.BOUNTY());
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Open));
    }

    function test_CreateTask_RequesterNonceIncrements() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD * 3);

        assertEq(market.requesterNonce(requester), 0);

        bytes32 id1 = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.requesterNonce(requester), 1);

        bytes32 id2 = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.requesterNonce(requester), 2);

        assertTrue(id1 != id2);
        vm.stopPrank();
    }

    function test_AcceptSubmission_Bounty() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        uint256 workerBalanceBefore = usdc.balanceOf(worker1);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.prank(server);
        market.acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1), workerBalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + expectedFee);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Accepted));
        assertEq(task.worker, worker1);

        (uint256 completedTasks,,) = market.getWorkerStats(worker1);
        assertEq(completedTasks, 1);
    }

    function test_ClaimTask_Claim() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.stopPrank();

        uint256 stakeAmount = REWARD / 10;

        vm.startPrank(server);
        usdc.approve(address(market), stakeAmount);

        vm.expectEmit(true, true, false, true);
        emit TaskMarket.TaskClaimed(taskId, worker1, stakeAmount);

        market.claimTask(taskId, worker1, stakeAmount);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Claimed));
        assertEq(task.claimer, worker1);
        assertEq(task.stakeAmount, stakeAmount);
    }

    function test_AcceptSubmission_Claim_ReturnsStake() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.stopPrank();

        uint256 stakeAmount = REWARD / 10;

        vm.startPrank(server);
        usdc.approve(address(market), stakeAmount);
        market.claimTask(taskId, worker1, stakeAmount);
        vm.stopPrank();

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;
        uint256 workerBalanceBefore = usdc.balanceOf(worker1);

        vm.prank(server);
        market.acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1), workerBalanceBefore + expectedWorkerPayment + stakeAmount);
    }

    function test_ForfeitAndReopen_Claim() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.stopPrank();

        uint256 stakeAmount = REWARD / 10;

        vm.startPrank(server);
        usdc.approve(address(market), stakeAmount);
        market.claimTask(taskId, worker1, stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.prank(server);
        market.forfeitAndReopen(taskId, requester);

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + stakeAmount);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Open));
        assertEq(task.claimer, address(0));
        assertEq(task.stakeAmount, 0);
    }

    function test_SelectWorker_Pitch() public {
        uint256 pitchDeadline = 2 days;

        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), pitchDeadline, 0);
        vm.stopPrank();

        vm.expectEmit(true, true, false, false);
        emit TaskMarket.TaskWorkerSelected(taskId, worker1);

        vm.prank(server);
        market.selectWorker(taskId, requester, worker1);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.WorkerSelected));
        assertEq(task.worker, worker1);
    }

    function test_AcceptSubmission_Pitch() public {
        uint256 pitchDeadline = 2 days;

        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), pitchDeadline, 0);
        market.selectWorker(taskId, requester, worker1);
        vm.stopPrank();

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        vm.prank(server);
        market.acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1) - 1000 * 10 ** 6, expectedWorkerPayment);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Accepted));
    }

    function test_AcceptSubmission_Benchmark() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        vm.stopPrank();

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        vm.prank(server);
        market.acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1) - 1000 * 10 ** 6, expectedWorkerPayment);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Accepted));
    }

    function test_RateTask() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        market.acceptSubmission(taskId, requester, worker1);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true);
        emit TaskMarket.TaskRated(taskId, worker1, 5);

        vm.prank(server);
        market.rateTask(taskId, requester, 5, 0, "", bytes32(0));

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.rating, 5);

        (,uint256 avgRating, uint256 ratedTasks) = market.getWorkerStats(worker1);
        assertEq(ratedTasks, 1);
        assertEq(avgRating, 500);
    }

    function test_RefundExpired() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Expired));
    }

    function test_SetDefaultFeeBps() public {
        uint16 newFeeBps = 750;

        vm.prank(owner);
        market.setDefaultFeeBps(newFeeBps);

        assertEq(market.defaultFeeBps(), newFeeBps);
    }

    function test_SetFeeRecipient() public {
        address newRecipient = address(99);

        vm.prank(owner);
        market.setFeeRecipient(newRecipient);

        assertEq(market.feeRecipient(), newRecipient);
    }

    function test_RevertWhen_NonOwnerSetFees() public {
        vm.prank(worker1);
        vm.expectRevert();
        market.setDefaultFeeBps(1000);
    }

    function test_RevertWhen_ClaimNonClaimTask() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert();
        market.claimTask(taskId, worker1, REWARD / 10);
        vm.stopPrank();
    }

    function test_RevertWhen_SelectWorkerNonPitchTask() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert();
        market.selectWorker(taskId, requester, worker1);
        vm.stopPrank();
    }

    function test_RevertWhen_ForfeitTooEarly() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD + REWARD / 10);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, REWARD / 10);
        vm.expectRevert();
        market.forfeitAndReopen(taskId, requester);
        vm.stopPrank();
    }

    function test_RevertWhen_AcceptExpiredTask() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(server);
        vm.expectRevert();
        market.acceptSubmission(taskId, requester, worker1);
    }

    function test_RevertWhen_RateTaskTwice() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        market.acceptSubmission(taskId, requester, worker1);
        market.rateTask(taskId, requester, 5, 0, "", bytes32(0));
        vm.expectRevert();
        market.rateTask(taskId, requester, 4, 0, "", bytes32(0));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Access control (onlyServer) — non-server caller
    // -----------------------------------------------------------------------

    address public alice = address(7);

    function test_RevertWhen_NonServer_CreateTask() public {
        bytes4 bounty = market.BOUNTY();
        usdc.mint(alice, REWARD);
        vm.startPrank(alice);
        usdc.approve(address(market), REWARD);
        vm.expectRevert("Not trusted forwarder");
        market.createTask(requester, REWARD, DURATION, bounty, 0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_NonServer_ClaimTask() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.claimTask(taskId, worker1, 0);
    }

    function test_RevertWhen_NonServer_SelectWorker() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.selectWorker(taskId, requester, worker1);
    }

    function test_RevertWhen_NonServer_AcceptSubmission() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.acceptSubmission(taskId, requester, worker1);
    }

    function test_RevertWhen_NonServer_ForfeitAndReopen() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD + REWARD / 10);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, REWARD / 10);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.forfeitAndReopen(taskId, requester);
    }

    function test_RevertWhen_NonServer_RateTask() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        market.acceptSubmission(taskId, requester, worker1);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.rateTask(taskId, requester, 5, 0, "", bytes32(0));
    }

    // -----------------------------------------------------------------------
    // addForwarder / removeForwarder
    // -----------------------------------------------------------------------

    function test_AddForwarder() public {
        address newServer = address(8);

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit TaskMarket.ForwarderUpdated(newServer, true);
        market.addForwarder(newServer);
        vm.stopPrank();

        assertTrue(market.trustedForwarders(newServer));

        // Confirm new forwarder can call a server-only function
        usdc.mint(newServer, REWARD);
        vm.startPrank(newServer);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
    }

    function test_RemoveForwarder() public {
        bytes4 bounty = market.BOUNTY();
        vm.prank(owner);
        market.removeForwarder(server);

        assertFalse(market.trustedForwarders(server));

        usdc.mint(server, REWARD);
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        vm.expectRevert("Not trusted forwarder");
        market.createTask(requester, REWARD, DURATION, bounty, 0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_AddForwarder_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid forwarder address");
        market.addForwarder(address(0));
    }

    function test_RevertWhen_NonOwner_AddForwarder() public {
        vm.prank(alice);
        vm.expectRevert();
        market.addForwarder(address(8));
    }

    // -----------------------------------------------------------------------
    // Constructor validation (now via proxy deploy)
    // -----------------------------------------------------------------------

    function test_RevertWhen_Constructor_ZeroFeeRecipient() public {
        TaskMarket impl = new TaskMarket();
        bytes memory initData = abi.encodeCall(TaskMarket.initialize, (address(usdc), address(0), defaultFeeBps));
        vm.expectRevert("Invalid fee recipient");
        new ERC1967Proxy(address(impl), initData);
    }

    function test_RevertWhen_Constructor_FeeBpsTooHigh() public {
        TaskMarket impl = new TaskMarket();
        bytes memory initData = abi.encodeCall(TaskMarket.initialize, (address(usdc), feeRecipient, 10001));
        vm.expectRevert("Fee BPS too high");
        new ERC1967Proxy(address(impl), initData);
    }

    // -----------------------------------------------------------------------
    // createTask input validation
    // -----------------------------------------------------------------------

    function test_RevertWhen_CreateTask_ZeroRequester() public {
        bytes4 bounty = market.BOUNTY();
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        vm.expectRevert("Invalid requester");
        market.createTask(address(0), REWARD, DURATION, bounty, 0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateTask_ZeroReward() public {
        bytes4 bounty = market.BOUNTY();
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        vm.expectRevert("Reward must be greater than 0");
        market.createTask(requester, 0, DURATION, bounty, 0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateTask_ZeroDuration() public {
        bytes4 bounty = market.BOUNTY();
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        vm.expectRevert("Duration must be greater than 0");
        market.createTask(requester, REWARD, 0, bounty, 0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_CreateTask_InvalidMode() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        vm.expectRevert("Invalid mode");
        market.createTask(requester, REWARD, DURATION, bytes4(0xdeadbeef), 0, 0);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // claimTask additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_ClaimTask_TaskExpired() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(server);
        vm.expectRevert("Task expired");
        market.claimTask(taskId, worker1, 0);
    }

    function test_RevertWhen_ClaimTask_AlreadyClaimed() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, 0);
        vm.expectRevert("Task not available");
        market.claimTask(taskId, worker2, 0);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Wrong requester reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_SelectWorker_WrongRequester() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.expectRevert("Not requester");
        market.selectWorker(taskId, worker2, worker1);
        vm.stopPrank();
    }

    function test_RevertWhen_AcceptSubmission_WrongRequester() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not requester");
        market.acceptSubmission(taskId, worker2, worker1);
        vm.stopPrank();
    }

    function test_RevertWhen_ForfeitAndReopen_WrongRequester() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD + REWARD / 10);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, REWARD / 10);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(server);
        vm.expectRevert("Not requester");
        market.forfeitAndReopen(taskId, worker2);
    }

    function test_RevertWhen_RateTask_WrongRequester() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        market.acceptSubmission(taskId, requester, worker1);
        vm.expectRevert("Not requester");
        market.rateTask(taskId, worker2, 5, 0, "", bytes32(0));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // selectWorker additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_SelectWorker_DeadlinePassed() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), 1 days, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(server);
        vm.expectRevert("Pitch deadline passed");
        market.selectWorker(taskId, requester, worker1);
    }

    function test_RevertWhen_SelectWorker_NotOpen() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        market.selectWorker(taskId, requester, worker1);
        vm.expectRevert("Task not available");
        market.selectWorker(taskId, requester, worker2);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // acceptSubmission additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_AcceptSubmission_Claim_WrongClaimer() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, 0);
        vm.expectRevert("Worker must be claimer");
        market.acceptSubmission(taskId, requester, worker2);
        vm.stopPrank();
    }

    function test_RevertWhen_AcceptSubmission_Pitch_WrongWorker() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        market.selectWorker(taskId, requester, worker1);
        vm.expectRevert("Worker mismatch");
        market.acceptSubmission(taskId, requester, worker2);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // submitWork
    // -----------------------------------------------------------------------

    function test_SubmitWork_Bounty_SetsPendingApproval() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 deliverable = keccak256("my work artifact");

        vm.expectEmit(true, true, false, true);
        emit TaskMarket.TaskSubmitted(taskId, worker1, deliverable);

        market.submitWork(taskId, worker1, deliverable);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.PendingApproval));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_Benchmark_SetsPendingApproval() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        bytes32 deliverable = keccak256("benchmark result");

        market.submitWork(taskId, worker1, deliverable);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.PendingApproval));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_Claim_NoStateChange() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, 0);

        bytes32 deliverable = keccak256("claim work");
        market.submitWork(taskId, worker1, deliverable);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        // State stays Claimed
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Claimed));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_Pitch_NoStateChange() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        market.selectWorker(taskId, requester, worker1);

        bytes32 deliverable = keccak256("pitch work");
        market.submitWork(taskId, worker1, deliverable);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.WorkerSelected));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_ThenAcceptSubmission_Bounty() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        market.submitWork(taskId, worker1, keccak256("work"));
        market.acceptSubmission(taskId, requester, worker1);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Accepted));
    }

    function test_RevertWhen_SubmitWork_TaskExpired() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(server);
        vm.expectRevert("Task expired");
        market.submitWork(taskId, worker1, keccak256("work"));
    }

    function test_RevertWhen_SubmitWork_Claim_WrongWorker() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, 0);

        vm.expectRevert("Worker must be claimer");
        market.submitWork(taskId, worker2, keccak256("work"));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // rateTask additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_RateTask_NotAccepted() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Task not accepted");
        market.rateTask(taskId, requester, 3, 0, "", bytes32(0));
        vm.stopPrank();
    }

    function test_RevertWhen_RateTask_InvalidRating() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        market.acceptSubmission(taskId, requester, worker1);
        vm.expectRevert("Rating must be 0-100");
        market.rateTask(taskId, requester, 101, 0, "", bytes32(0));
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // refundExpired edge cases
    // -----------------------------------------------------------------------

    function test_RevertWhen_RefundExpired_NotYetExpired() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        vm.expectRevert("Task not expired");
        market.refundExpired(taskId);
    }

    function test_RevertWhen_RefundExpired_TaskDoesNotExist() public {
        vm.expectRevert("Task does not exist");
        market.refundExpired(keccak256("nonexistent"));
    }

    function test_RevertWhen_RefundExpired_AlreadyAccepted() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        market.acceptSubmission(taskId, requester, worker1);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert("Task already accepted");
        market.refundExpired(taskId);
    }

    function test_RefundExpired_Claim_ReturnsStake() public {
        uint256 stakeAmount = REWARD / 10;

        vm.startPrank(server);
        usdc.approve(address(market), REWARD + stakeAmount);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 worker1BalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + stakeAmount);
    }

    // -----------------------------------------------------------------------
    // forfeitAndReopen additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_ForfeitAndReopen_NotClaim() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not a Claim task");
        market.forfeitAndReopen(taskId, requester);
        vm.stopPrank();
    }

    function test_RevertWhen_ForfeitAndReopen_NotClaimed() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.expectRevert("Task not claimed");
        market.forfeitAndReopen(taskId, requester);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Admin setters
    // -----------------------------------------------------------------------

    function test_RevertWhen_SetDefaultFeeBps_TooHigh() public {
        vm.prank(owner);
        vm.expectRevert("Fee BPS too high");
        market.setDefaultFeeBps(10001);
    }

    function test_RevertWhen_NonOwner_SetFeeRecipient() public {
        vm.prank(alice);
        vm.expectRevert();
        market.setFeeRecipient(address(99));
    }

    function test_RevertWhen_SetFeeRecipient_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Invalid recipient");
        market.setFeeRecipient(address(0));
    }

    // -----------------------------------------------------------------------
    // Worker stats across multiple tasks
    // -----------------------------------------------------------------------

    function test_GetWorkerStats_MultipleAcceptedTasks() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD * 2);

        bytes32 taskId1 = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 taskId2 = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId2, worker1, 0);

        market.acceptSubmission(taskId1, requester, worker1);
        market.acceptSubmission(taskId2, requester, worker1);
        vm.stopPrank();

        (uint256 completedTasks,,) = market.getWorkerStats(worker1);
        assertEq(completedTasks, 2);

        TaskMarket.Task memory t1 = market.getTask(taskId1);
        TaskMarket.Task memory t2 = market.getTask(taskId2);
        assertEq(t1.worker, worker1);
        assertEq(t2.worker, worker1);
    }

    // -----------------------------------------------------------------------
    // acceptAuction tests
    // -----------------------------------------------------------------------

    function test_AcceptAuction_success() public {
        uint256 bidDeadline = 1 days;
        uint256 acceptPrice = 40 * 10 ** 6;

        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidDeadline);
        vm.stopPrank();

        vm.prank(server);
        vm.expectEmit(true, true, false, true);
        emit TaskMarket.BidSubmitted(taskId, worker1, acceptPrice);
        vm.expectEmit(true, true, false, false);
        emit TaskMarket.TaskWorkerSelected(taskId, worker1);
        market.acceptAuction(taskId, worker1, acceptPrice);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Claimed));
        assertEq(task.worker, worker1);
        assertEq(task.stakeAmount, acceptPrice);
    }

    function test_AcceptAuction_thenAcceptSubmission() public {
        uint256 bidDeadline = 1 days;
        uint256 acceptPrice = 40 * 10 ** 6;

        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidDeadline);
        market.acceptAuction(taskId, worker1, acceptPrice);
        vm.stopPrank();

        uint256 fee = (acceptPrice * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = acceptPrice - fee;
        uint256 expectedRefund = REWARD - acceptPrice;

        uint256 workerBalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.prank(server);
        market.acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1), workerBalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + expectedRefund);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Accepted));
    }

    function test_AcceptAuction_priceExceedsMax() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days);
        vm.stopPrank();

        vm.prank(server);
        vm.expectRevert("Price exceeds max price");
        market.acceptAuction(taskId, worker1, REWARD + 1);
    }

    function test_AcceptAuction_notAuction() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        vm.prank(server);
        vm.expectRevert("Not an Auction task");
        market.acceptAuction(taskId, worker1, REWARD / 2);
    }

    function test_AcceptAuction_notOpen() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days);
        market.acceptAuction(taskId, worker1, REWARD / 2);
        vm.stopPrank();

        vm.prank(server);
        vm.expectRevert("Task not open");
        market.acceptAuction(taskId, worker2, REWARD / 3);
    }

    // -----------------------------------------------------------------------
    // UUPS Upgrade tests
    // -----------------------------------------------------------------------

    function test_Upgrade_preservesState() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days);
        market.acceptAuction(taskId, worker1, REWARD / 2);
        vm.stopPrank();

        vm.prank(owner);
        TaskMarket newImpl = new TaskMarket();
        vm.prank(owner);
        market.upgradeToAndCall(address(newImpl), "");

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
        assertEq(task.worker, worker1);
        assertEq(task.stakeAmount, REWARD / 2);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Claimed));
        assertEq(task.mode, market.AUCTION());
    }

    function test_Upgrade_onlyOwner() public {
        TaskMarket newImpl = new TaskMarket();
        vm.prank(alice);
        vm.expectRevert();
        market.upgradeToAndCall(address(newImpl), "");
    }

    // -----------------------------------------------------------------------
    // refundExpired auction tests
    // -----------------------------------------------------------------------

    function test_RefundExpired_Auction_NoWinner() public {
        uint256 bidDeadline = 1 days;
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidDeadline);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Expired));
    }

    function test_RefundExpired_Auction_WithWinner() public {
        uint256 bidDeadline = 1 days;
        uint256 acceptPrice = 40 * 10 ** 6;

        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidDeadline);
        market.acceptAuction(taskId, worker1, acceptPrice);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 fee = (acceptPrice * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = acceptPrice - fee;
        uint256 expectedRequesterRefund = REWARD - acceptPrice;

        uint256 worker1BalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.expectEmit(true, true, true, true);
        emit TaskMarket.TaskAccepted(taskId, requester, worker1, expectedWorkerPayment, fee);
        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + expectedRequesterRefund);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + fee);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Accepted));

        (uint256 completedTasks,,) = market.getWorkerStats(worker1);
        assertEq(completedTasks, 1);
    }

    function test_RefundExpired_Auction_WithWinner_ZeroRefund() public {
        uint256 bidDeadline = 1 days;
        uint256 acceptPrice = REWARD;

        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidDeadline);
        market.acceptAuction(taskId, worker1, acceptPrice);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 fee = (acceptPrice * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = acceptPrice - fee;

        uint256 worker1BalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Accepted));
    }

    // -----------------------------------------------------------------------
    // cancelTask tests
    // -----------------------------------------------------------------------

    function test_CancelTask_Bounty() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.expectEmit(true, true, false, true);
        emit TaskMarket.TaskCancelled(taskId, requester, REWARD);

        vm.prank(server);
        market.cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Cancelled));
    }

    function test_CancelTask_Claim() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.stopPrank();

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.prank(server);
        market.cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Cancelled));
    }

    function test_CancelTask_Auction_NoBids() public {
        uint256 bidDeadline = 1 days;
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidDeadline);
        vm.stopPrank();

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.prank(server);
        market.cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(TaskMarket.TaskStatus.Cancelled));
    }

    function test_RevertWhen_CancelTask_AuctionHasBids() public {
        uint256 bidDeadline = 1 days;
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidDeadline);
        market.submitBid(taskId, worker1, REWARD / 2);
        vm.expectRevert("Bids exist");
        market.cancelTask(taskId, requester);
        vm.stopPrank();
    }

    function test_RevertWhen_CancelTask_NotOpen_Claimed() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        market.claimTask(taskId, worker1, 0);
        vm.expectRevert("Task not open");
        market.cancelTask(taskId, requester);
        vm.stopPrank();
    }

    function test_RevertWhen_CancelTask_WrongRequester() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not requester");
        market.cancelTask(taskId, worker1);
        vm.stopPrank();
    }

    function test_RevertWhen_CancelTask_NonServer() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.cancelTask(taskId, requester);
    }

    function test_RevertWhen_CancelTask_DoesNotExist() public {
        vm.prank(server);
        vm.expectRevert("Task does not exist");
        market.cancelTask(keccak256("nonexistent"), requester);
    }

    // -----------------------------------------------------------------------
    // updateTask tests
    // -----------------------------------------------------------------------

    function test_UpdateTask_RewardIncrease() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        usdc.approve(address(market), REWARD);

        uint256 newReward = REWARD * 2;
        vm.expectEmit(true, false, false, false);
        emit TaskMarket.TaskUpdated(taskId, newReward, block.timestamp + DURATION);

        market.updateTask(taskId, requester, newReward, 0, 0, 0);
        vm.stopPrank();

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.reward, newReward);
    }

    function test_UpdateTask_RewardDecrease() public {
        vm.startPrank(server);
        usdc.approve(address(market), REWARD);
        bytes32 taskId = market.createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.stopPrank();

        uint256 newReward = REWARD / 2;
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.prank(server);
        market.updateTask(taskId, requester, newReward, 0, 0, 0);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + (REWARD - newReward));

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.reward, newReward);
    }
}
