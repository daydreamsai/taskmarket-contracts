// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/TaskMarket.sol";
import "../src/interfaces/ITMP.sol";
import "../src/interfaces/IPGTRForwarder.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

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

/// @dev Test double for a PGTR forwarder (ERC-8194).
///      Holds USDC on behalf of payers and sets pgtrSender atomically
///      during each relayed call to the destination contract.
contract MockPGTRForwarder is IPGTRForwarder {
    IERC20 public usdc;
    address private _pgtrSenderValue;

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    function isPGTRForwarder() external pure override returns (bool) {
        return true;
    }

    function pgtrSender() external view override returns (address) {
        return _pgtrSenderValue;
    }

    function isTrustedForwarder(address addr) external view override returns (bool) {
        return addr == address(this);
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPGTRForwarder).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    /// @dev Transfer paymentAmount from this contract to target, then call
    ///      target with pgtrSender set to pgtrSenderAddr for the duration.
    ///      Reverts from the destination are propagated to the caller.
    function relay(
        address target,
        address pgtrSenderAddr,
        uint256 paymentAmount,
        bytes calldata data
    ) external returns (bytes memory) {
        if (paymentAmount > 0) {
            require(usdc.transfer(target, paymentAmount), "USDC transfer failed");
        }
        _pgtrSenderValue = pgtrSenderAddr;
        (bool success, bytes memory result) = target.call(data);
        _pgtrSenderValue = address(0);
        if (!success) {
            if (result.length > 0) {
                assembly { revert(add(result, 32), mload(result)) }
            }
            revert("relay failed");
        }
        return result;
    }
}

contract TaskMarketTest is Test {
    TaskMarket public market;
    MockERC20 public usdc;
    MockPGTRForwarder public forwarder;

    address public owner = address(1);
    address public feeRecipient = address(2);
    address public requester = address(3);
    address public worker1 = address(4);
    address public worker2 = address(5);
    // address(6) intentionally unused — reserved gap to avoid collisions with
    // contract addresses that Forge may deploy at low addresses during setUp.
    address public alice = address(7);

    uint16 public defaultFeeBps = 500;

    uint256 public constant REWARD = 100 * 10 ** 6;
    uint256 public constant DURATION = 7 days;

    /// @dev Pre-compute the next contract-generated task ID for a given requester
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

        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();

        // Forwarder holds USDC to escrow on behalf of requesters (received via X402)
        usdc.mint(address(forwarder), 10000 * 10 ** 6);
        usdc.mint(worker1, 1000 * 10 ** 6);
        usdc.mint(worker2, 1000 * 10 ** 6);
    }

    // -------------------------------------------------------------------------
    // Relay helpers
    // -------------------------------------------------------------------------

    function _relay(address pgtrSenderAddr, uint256 paymentAmount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), pgtrSenderAddr, paymentAmount, data);
    }

    function _createTask(address _req, uint256 _reward, uint256 _dur, bytes4 _mode, uint256 _pd, uint256 _bd) internal returns (bytes32) {
        return _createTask(_req, _reward, _dur, _mode, _pd, _bd, bytes4(0));
    }

    function _createTask(address _req, uint256 _reward, uint256 _dur, bytes4 _mode, uint256 _pd, uint256 _bd, bytes4 _auctionSubtype) internal returns (bytes32) {
        return abi.decode(
            _relay(_req, _reward, abi.encodeCall(market.createTask, (_reward, _dur, _mode, _pd, _bd, bytes32(0), "", _auctionSubtype))),
            (bytes32)
        );
    }

    function _claimTask(bytes32 taskId, address _worker, uint256 stakeAmount) internal {
        _relay(_worker, stakeAmount, abi.encodeCall(market.claimTask, (taskId, stakeAmount)));
    }

    function _selectWorker(bytes32 taskId, address _req, address _worker) internal {
        _relay(_req, 0, abi.encodeCall(market.selectWorker, (taskId, _worker)));
    }

    function _submitBid(bytes32 taskId, address _worker, uint256 price) internal {
        _relay(_worker, 0, abi.encodeCall(market.submitBid, (taskId, price)));
    }

    function _acceptAuction(bytes32 taskId, address _worker, uint256 price) internal {
        _relay(_worker, 0, abi.encodeCall(market.acceptAuction, (taskId, price)));
    }

    function _selectLowestBidder(bytes32 taskId) internal {
        _relay(address(0), 0, abi.encodeCall(market.selectLowestBidder, (taskId)));
    }

    function _submitWork(bytes32 taskId, address _worker, bytes32 deliverable) internal {
        _relay(_worker, 0, abi.encodeCall(market.submitWork, (taskId, deliverable)));
    }

    function _acceptSubmission(bytes32 taskId, address _req, address _worker) internal {
        _relay(_req, 0, abi.encodeCall(market.acceptSubmission, (taskId, _worker)));
    }

    function _forfeitAndReopen(bytes32 taskId, address _req) internal {
        _relay(_req, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function _rateTask(bytes32 taskId, address _req, uint8 _rating, uint256 _waid, uint256 _raid, string memory _uri, bytes32 _hash) internal {
        _relay(_req, 0, abi.encodeCall(market.rateTask, (taskId, _rating, _waid, _raid, _uri, _hash)));
    }

    function _cancelTask(bytes32 taskId, address _req) internal {
        _relay(_req, 0, abi.encodeCall(market.cancelTask, (taskId)));
    }

    function _updateTask(bytes32 taskId, address _req, uint256 additionalPayment, uint256 _newReward, uint256 _newExpiry, uint256 _newBidDl, uint256 _newPitchDl) internal {
        _relay(_req, additionalPayment, abi.encodeCall(market.updateTask, (taskId, _newReward, _newExpiry, _newBidDl, _newPitchDl)));
    }

    // -----------------------------------------------------------------------
    // Constructor / initialization
    // -----------------------------------------------------------------------

    function test_Constructor() public view {
        assertEq(address(market.usdcToken()), address(usdc));
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.defaultFeeBps(), defaultFeeBps);
        assertTrue(market.trustedForwarders(address(forwarder)));
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
    // isTrustedForwarder (ERC-8194 requirement)
    // -----------------------------------------------------------------------

    function test_IsTrustedForwarder_Registered() public view {
        assertTrue(market.isTrustedForwarder(address(forwarder)));
    }

    function test_IsTrustedForwarder_Unknown() public view {
        assertFalse(market.isTrustedForwarder(alice));
    }

    // -----------------------------------------------------------------------
    // createTask — basic happy paths
    // -----------------------------------------------------------------------

    function test_CreateTask_Bounty() public {
        bytes32 expectedId = _nextTaskId(requester);

        vm.expectEmit(true, true, false, true);
        emit ITMP.TaskCreated(expectedId, requester, REWARD, block.timestamp + DURATION, market.BOUNTY());

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        assertEq(taskId, expectedId);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
        assertEq(task.reward, REWARD);
        assertEq(task.mode, market.BOUNTY());
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Open));
    }

    function test_CreateTask_RequesterNonceIncrements() public {
        assertEq(market.requesterNonce(requester), 0);

        bytes32 id1 = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.requesterNonce(requester), 1);

        bytes32 id2 = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.requesterNonce(requester), 2);

        assertTrue(id1 != id2);
    }

    function test_AcceptSubmission_Bounty() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        uint256 workerBalanceBefore = usdc.balanceOf(worker1);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1), workerBalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + expectedFee);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
        assertEq(task.worker, worker1);

        assertEq(market.getWorkerStats(worker1).completedTasks, 1);
    }

    function test_ClaimTask_Claim() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint256 stakeAmount = REWARD / 10;

        vm.expectEmit(true, true, false, true);
        emit TaskMarket.TaskClaimed(taskId, worker1, stakeAmount);

        _claimTask(taskId, worker1, stakeAmount);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));
        assertEq(task.claimer, worker1);
        assertEq(task.stakeAmount, stakeAmount);
    }

    function test_AcceptSubmission_Claim_ReturnsStake() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint256 stakeAmount = REWARD / 10;
        _claimTask(taskId, worker1, stakeAmount);

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;
        uint256 workerBalanceBefore = usdc.balanceOf(worker1);

        _acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1), workerBalanceBefore + expectedWorkerPayment + stakeAmount);
    }

    function test_ForfeitAndReopen_Claim() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint256 stakeAmount = REWARD / 10;
        _claimTask(taskId, worker1, stakeAmount);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        _forfeitAndReopen(taskId, requester);

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + stakeAmount);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Open));
        assertEq(task.claimer, address(0));
        assertEq(task.stakeAmount, 0);
    }

    function test_SelectWorker_Pitch() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);

        vm.expectEmit(true, true, false, false);
        emit TaskMarket.TaskWorkerSelected(taskId, worker1);

        _selectWorker(taskId, requester, worker1);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.WorkerSelected));
        assertEq(task.worker, worker1);
    }

    function test_AcceptSubmission_Pitch() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        _acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1) - 1000 * 10 ** 6, expectedWorkerPayment);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    function test_AcceptSubmission_Benchmark() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        _acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1) - 1000 * 10 ** 6, expectedWorkerPayment);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    function test_RateTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);

        vm.expectEmit(true, true, false, true);
        emit ITMP.TaskRated(taskId, worker1, 5, 0);

        _rateTask(taskId, requester, 5, 0, 0, "", bytes32(0));

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.rating, 5);

        ITMP.WorkerStats memory ws = market.getWorkerStats(worker1);
        assertEq(ws.ratedTasks, 1);
        assertEq(ws.totalStars, 5);
    }

    function test_RefundExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Expired));
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
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not a Claim task");
        forwarder.relay(address(market), worker1, REWARD / 10, abi.encodeCall(market.claimTask, (taskId, REWARD / 10)));
    }

    function test_RevertWhen_SelectWorkerNonPitchTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not a Pitch task");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
    }

    function test_RevertWhen_ForfeitTooEarly() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, REWARD / 10);
        vm.expectRevert("Task not yet expired");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function test_RevertWhen_AcceptExpiredTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);
        vm.expectRevert("Task expired");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));
    }

    function test_RevertWhen_RateTaskTwice() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, 5, 0, 0, "", bytes32(0));
        vm.expectRevert("Already rated");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.rateTask, (taskId, 4, 0, 0, "", bytes32(0))));
    }

    // -----------------------------------------------------------------------
    // Access control (onlyTrustedForwarder) — non-forwarder caller
    // -----------------------------------------------------------------------

    function test_RevertWhen_NonServer_CreateTask() public {
        bytes4 bounty = market.BOUNTY();
        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.createTask(REWARD, DURATION, bounty, 0, 0, bytes32(0), "", bytes4(0));
    }

    function test_RevertWhen_NonServer_ClaimTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.claimTask(taskId, 0);
    }

    function test_RevertWhen_NonServer_SelectWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.selectWorker(taskId, worker1);
    }

    function test_RevertWhen_NonServer_AcceptSubmission() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.acceptSubmission(taskId, worker1);
    }

    function test_RevertWhen_NonServer_ForfeitAndReopen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, REWARD / 10);

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.forfeitAndReopen(taskId);
    }

    function test_RevertWhen_NonServer_RateTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.rateTask(taskId, 5, 0, 0, "", bytes32(0));
    }

    // -----------------------------------------------------------------------
    // addForwarder / removeForwarder
    // -----------------------------------------------------------------------

    function test_AddForwarder() public {
        MockPGTRForwarder newForwarder = new MockPGTRForwarder(address(usdc));
        usdc.mint(address(newForwarder), REWARD);

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit TaskMarket.ForwarderUpdated(address(newForwarder), true);
        market.addForwarder(address(newForwarder));
        vm.stopPrank();

        assertTrue(market.trustedForwarders(address(newForwarder)));

        bytes32 taskId = abi.decode(
            newForwarder.relay(address(market), requester, REWARD, abi.encodeCall(market.createTask, (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0)))),
            (bytes32)
        );

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
    }

    function test_RemoveForwarder() public {
        vm.prank(owner);
        market.removeForwarder(address(forwarder));

        assertFalse(market.trustedForwarders(address(forwarder)));

        bytes memory data = abi.encodeCall(market.createTask, (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0)));
        vm.expectRevert("Not trusted forwarder");
        forwarder.relay(address(market), requester, REWARD, data);
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
        bytes memory data = abi.encodeCall(market.createTask, (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0)));
        vm.expectRevert("Invalid requester");
        forwarder.relay(address(market), address(0), REWARD, data);
    }

    function test_RevertWhen_CreateTask_ZeroReward() public {
        bytes memory data = abi.encodeCall(market.createTask, (0, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0)));
        vm.expectRevert("Reward must be greater than 0");
        forwarder.relay(address(market), requester, 0, data);
    }

    function test_RevertWhen_CreateTask_ZeroDuration() public {
        bytes memory data = abi.encodeCall(market.createTask, (REWARD, 0, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0)));
        vm.expectRevert("Duration must be greater than 0");
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_RevertWhen_CreateTask_InvalidMode() public {
        bytes memory data = abi.encodeCall(market.createTask, (REWARD, DURATION, bytes4(0xdeadbeef), 0, 0, bytes32(0), "", bytes4(0)));
        vm.expectRevert("Invalid mode");
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_RevertWhen_CreateTask_Auction_InvalidSubtype() public {
        bytes memory data = abi.encodeCall(market.createTask, (REWARD, DURATION, market.AUCTION(), 0, 1 days, bytes32(0), "", bytes4(0xdeadbeef)));
        vm.expectRevert("Invalid auction subtype");
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_CreateTask_Auction_StoresSubtype() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.auctionSubtype, market.AUCTION_ENGLISH());
    }

    function test_CreateTask_NonAuction_SubtypeZero() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.auctionSubtype, bytes4(0));
    }

    // -----------------------------------------------------------------------
    // claimTask additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_ClaimTask_TaskExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert("Task expired");
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    function test_RevertWhen_ClaimTask_AlreadyClaimed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);

        vm.expectRevert("Task not available");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    // -----------------------------------------------------------------------
    // Wrong requester reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_SelectWorker_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.expectRevert("Not requester");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
    }

    function test_RevertWhen_AcceptSubmission_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not requester");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));
    }

    function test_RevertWhen_ForfeitAndReopen_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, REWARD / 10);

        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert("Not requester");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function test_RevertWhen_RateTask_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        vm.expectRevert("Not requester");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.rateTask, (taskId, 5, 0, 0, "", bytes32(0))));
    }

    // -----------------------------------------------------------------------
    // selectWorker additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_SelectWorker_DeadlinePassed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 1 days, 0);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert("Pitch deadline passed");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
    }

    function test_RevertWhen_SelectWorker_NotOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);
        vm.expectRevert("Task not available");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker2)));
    }

    // -----------------------------------------------------------------------
    // acceptSubmission additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_AcceptSubmission_Claim_WrongClaimer() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        vm.expectRevert("Worker must be claimer");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker2)));
    }

    function test_RevertWhen_AcceptSubmission_Pitch_WrongWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);
        vm.expectRevert("Worker mismatch");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker2)));
    }

    // -----------------------------------------------------------------------
    // submitWork
    // -----------------------------------------------------------------------

    function test_SubmitWork_Bounty_SetsPendingApproval() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 deliverable = keccak256("my work artifact");

        vm.expectEmit(true, true, false, true);
        emit ITMP.TaskSubmitted(taskId, worker1, deliverable);

        _submitWork(taskId, worker1, deliverable);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.PendingApproval));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_Benchmark_SetsPendingApproval() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        bytes32 deliverable = keccak256("benchmark result");

        _submitWork(taskId, worker1, deliverable);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.PendingApproval));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_Claim_NoStateChange() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);

        bytes32 deliverable = keccak256("claim work");
        _submitWork(taskId, worker1, deliverable);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_Pitch_NoStateChange() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);

        bytes32 deliverable = keccak256("pitch work");
        _submitWork(taskId, worker1, deliverable);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.WorkerSelected));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_ThenAcceptSubmission_Bounty() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        _acceptSubmission(taskId, requester, worker1);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    function test_RevertWhen_SubmitWork_TaskExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert("Task expired");
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function test_RevertWhen_SubmitWork_Claim_WrongWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);

        vm.expectRevert("Worker must be claimer");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function test_RevertWhen_SubmitWork_Pitch_WrongWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);

        vm.expectRevert("Worker mismatch");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        // State must be unchanged
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.WorkerSelected));
        assertEq(task.deliverable, bytes32(0));
    }

    // -----------------------------------------------------------------------
    // rateTask additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_RateTask_NotAccepted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Task not accepted");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.rateTask, (taskId, 3, 0, 0, "", bytes32(0))));
    }

    function test_RevertWhen_RateTask_InvalidRating() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        vm.expectRevert("Rating must be 0-100");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.rateTask, (taskId, 101, 0, 0, "", bytes32(0))));
    }

    // -----------------------------------------------------------------------
    // refundExpired edge cases
    // -----------------------------------------------------------------------

    function test_RevertWhen_RefundExpired_NotYetExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Task not expired");
        market.refundExpired(taskId);
    }

    function test_RevertWhen_RefundExpired_TaskDoesNotExist() public {
        vm.expectRevert("Task does not exist");
        market.refundExpired(keccak256("nonexistent"));
    }

    function test_RevertWhen_RefundExpired_AlreadyAccepted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);

        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert("Task already accepted");
        market.refundExpired(taskId);
    }

    function test_RefundExpired_Claim_ReturnsStake() public {
        uint256 stakeAmount = REWARD / 10;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, stakeAmount);

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
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not a Claim task");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function test_RevertWhen_ForfeitAndReopen_NotClaimed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.expectRevert("Task not claimed");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
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
        bytes32 taskId1 = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 taskId2 = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId2, worker1, 0);

        _acceptSubmission(taskId1, requester, worker1);
        _acceptSubmission(taskId2, requester, worker1);

        assertEq(market.getWorkerStats(worker1).completedTasks, 2);

        TaskMarket.Task memory t1 = market.getTask(taskId1);
        TaskMarket.Task memory t2 = market.getTask(taskId2);
        assertEq(t1.worker, worker1);
        assertEq(t2.worker, worker1);
    }

    // -----------------------------------------------------------------------
    // acceptAuction tests
    // -----------------------------------------------------------------------

    function test_AcceptAuction_success() public {
        uint256 acceptPrice = 40 * 10 ** 6;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());

        vm.expectEmit(true, true, false, true);
        emit TaskMarket.BidSubmitted(taskId, worker1, acceptPrice);
        vm.expectEmit(true, true, false, false);
        emit TaskMarket.TaskWorkerSelected(taskId, worker1);
        _acceptAuction(taskId, worker1, acceptPrice);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));
        assertEq(task.worker, worker1);
        assertEq(task.stakeAmount, acceptPrice);
    }

    function test_AcceptAuction_thenAcceptSubmission() public {
        uint256 acceptPrice = 40 * 10 ** 6;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, acceptPrice);

        uint256 fee = (acceptPrice * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = acceptPrice - fee;
        uint256 expectedRefund = REWARD - acceptPrice;

        uint256 workerBalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        _acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1), workerBalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + expectedRefund);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    function test_AcceptAuction_priceExceedsMax() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        vm.expectRevert("Price exceeds max price");
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD + 1)));
    }

    function test_AcceptAuction_notAuction() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not an Auction task");
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD / 2)));
    }

    function test_AcceptAuction_notOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, REWARD / 2);

        vm.expectRevert("Task not open");
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD / 3)));
    }

    // -----------------------------------------------------------------------
    // UUPS Upgrade tests
    // -----------------------------------------------------------------------

    function test_Upgrade_preservesState() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, REWARD / 2);

        vm.prank(owner);
        TaskMarket newImpl = new TaskMarket();
        vm.prank(owner);
        market.upgradeToAndCall(address(newImpl), "");

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
        assertEq(task.worker, worker1);
        assertEq(task.stakeAmount, REWARD / 2);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));
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
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        vm.warp(block.timestamp + DURATION + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Expired));
    }

    function test_RefundExpired_Auction_WithWinner() public {
        uint256 acceptPrice = 40 * 10 ** 6;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, acceptPrice);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 fee = (acceptPrice * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = acceptPrice - fee;
        uint256 expectedRequesterRefund = REWARD - acceptPrice;

        uint256 worker1BalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.expectEmit(true, true, true, true);
        emit ITMP.TaskAccepted(taskId, requester, worker1, expectedWorkerPayment, fee);
        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + expectedRequesterRefund);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + fee);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));

        assertEq(market.getWorkerStats(worker1).completedTasks, 1);
    }

    function test_RefundExpired_Auction_WithWinner_ZeroRefund() public {
        uint256 acceptPrice = REWARD;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, acceptPrice);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 fee = (acceptPrice * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = acceptPrice - fee;

        uint256 worker1BalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    // -----------------------------------------------------------------------
    // cancelTask tests
    // -----------------------------------------------------------------------

    function test_CancelTask_Bounty() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.expectEmit(true, true, false, true);
        emit ITMP.TaskCancelled(taskId, requester, REWARD);

        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Cancelled));
    }

    function test_CancelTask_Claim() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Cancelled));
    }

    function test_CancelTask_Auction_NoBids() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Cancelled));
    }

    function test_RevertWhen_CancelTask_AuctionHasBids() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _submitBid(taskId, worker1, REWARD / 2);
        vm.expectRevert("Bids exist");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId)));
    }

    function test_RevertWhen_CancelTask_NotOpen_Claimed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        vm.expectRevert("Task not open");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId)));
    }

    function test_RevertWhen_CancelTask_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert("Not requester");
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.cancelTask, (taskId)));
    }

    function test_RevertWhen_CancelTask_NonServer() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        vm.prank(alice);
        vm.expectRevert("Not trusted forwarder");
        market.cancelTask(taskId);
    }

    function test_RevertWhen_CancelTask_DoesNotExist() public {
        vm.expectRevert("Task does not exist");
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (keccak256("nonexistent"))));
    }

    // -----------------------------------------------------------------------
    // updateTask tests
    // -----------------------------------------------------------------------

    function test_UpdateTask_RewardIncrease() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 newReward = REWARD * 2;
        uint256 additionalPayment = newReward - REWARD;

        vm.expectEmit(true, false, false, false);
        emit TaskMarket.TaskUpdated(taskId, newReward, block.timestamp + DURATION);

        _updateTask(taskId, requester, additionalPayment, newReward, 0, 0, 0);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.reward, newReward);
    }

    function test_UpdateTask_RewardDecrease() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 newReward = REWARD / 2;
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        _updateTask(taskId, requester, 0, newReward, 0, 0, 0);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + (REWARD - newReward));

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.reward, newReward);
    }
}
