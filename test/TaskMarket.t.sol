// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/interfaces/ITMPCore.sol";
import "../src/interfaces/ITMPEvaluator.sol";
import "../src/interfaces/ITMPRegistry.sol";
import "../src/interfaces/ITMPHook.sol";
import "../src/interfaces/IPGTRForwarder.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./mocks/MockPGTRForwarder.sol";
import "./mocks/MockTaskHook.sol";
import "./mocks/MockUSDC.sol";
import "./mocks/MockReputationRegistry.sol";
import "./helpers/DiamondTestHelper.sol";
import "../src/interfaces/ITMPDiamond.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { CoreFacet } from "../src/facets/CoreFacet.sol";
import { AdminFacet } from "../src/facets/AdminFacet.sol";
import { Diamond } from "../src/Diamond.sol";

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

contract TaskMarketTest is DiamondTestHelper {
    ITMPDiamond public market;
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

        market = deployDiamond(owner, address(usdc), feeRecipient, defaultFeeBps);

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

    function _hookArr(address h) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = h;
    }

    function _createTask(address _req, uint256 _reward, uint256 _dur, bytes4 _mode, uint256 _pd, uint256 _bd)
        internal
        returns (bytes32)
    {
        return _createTask(_req, _reward, _dur, _mode, _pd, _bd, bytes4(0));
    }

    function _createTask(
        address _req,
        uint256 _reward,
        uint256 _dur,
        bytes4 _mode,
        uint256 _pd,
        uint256 _bd,
        bytes4 _auctionSubtype
    ) internal returns (bytes32) {
        return abi.decode(
            _relay(
                _req,
                _reward,
                abi.encodeCall(
                    market.createTask,
                    (
                        _reward,
                        _dur,
                        _mode,
                        _pd,
                        _bd,
                        _auctionSubtype,
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );
    }

    function _createTaskWithHook(address _req, uint256 _reward, uint256 _dur, bytes4 _mode, address _hook)
        internal
        returns (bytes32)
    {
        address[] memory hooks = new address[](1);
        hooks[0] = _hook;
        // Pass _dur as pitchDeadline/bidDeadline so PITCH and AUCTION modes satisfy the >0 check.
        // Non-PITCH/AUCTION modes ignore these values.
        return abi.decode(
            _relay(
                _req,
                _reward,
                abi.encodeCall(
                    market.createTask,
                    (
                        _reward,
                        _dur,
                        _mode,
                        _dur,
                        _dur,
                        bytes4(0),
                        ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );
    }

    function _assignEvaluator(
        bytes32 taskId,
        address _req,
        address _eval,
        uint16 _feeBps,
        uint32 _evalWindow,
        uint32 _appealWindow
    ) internal {
        _relay(
            _req,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, _eval, 0, _feeBps, _evalWindow, _appealWindow, address(0)))
        );
    }

    function _evaluate(
        bytes32 taskId,
        address _eval,
        ITMPCore.VerdictType _vt,
        uint16 _score,
        ITMPCore.Award[] memory _awards
    ) internal {
        _relay(_eval, 0, abi.encodeCall(market.evaluate, (taskId, _vt, _score, 1000, bytes32(0), _awards)));
    }

    function _appeal(bytes32 taskId, address _worker) internal {
        _relay(_worker, 0, abi.encodeCall(market.appeal, (taskId)));
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

    function _acceptSubmission(bytes32 taskId, address _req, address _worker, bytes32 _deliverable) internal {
        _relay(_req, 0, abi.encodeCall(market.acceptSubmission, (taskId, _worker, _deliverable, 0)));
    }

    /// Back-compat helper: for Claim/Pitch/Auction reads the deliverable from task storage.
    /// For Bounty/Benchmark, submits keccak256("work") via submitWork first (required by
    /// hash verification), then accepts it — keeps existing test flows working unchanged.
    function _acceptSubmission(bytes32 taskId, address _req, address _worker) internal {
        ITMPCore.Task memory _task = market.getTask(taskId);
        bytes32 _deliverable;
        if (_task.mode == market.BOUNTY() || _task.mode == market.BENCHMARK()) {
            _deliverable = keccak256("work");
            _submitWork(taskId, _worker, _deliverable);
        } else {
            _deliverable = _task.deliverable;
        }
        _relay(_req, 0, abi.encodeCall(market.acceptSubmission, (taskId, _worker, _deliverable, 0)));
    }

    function _forfeitAndReopen(bytes32 taskId, address _req) internal {
        _relay(_req, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function _rateTask(
        bytes32 taskId,
        address _req,
        address _worker,
        uint8 _rating,
        uint256 _waid,
        uint256 _raid,
        string memory _uri,
        bytes32 _hash
    ) internal {
        _relay(_req, 0, abi.encodeCall(market.rateTask, (taskId, _worker, _rating, _waid, _raid, _uri, _hash)));
    }

    /// Back-compat helper that defaults worker to task.worker (post-acceptance).
    function _rateTask(
        bytes32 taskId,
        address _req,
        uint8 _rating,
        uint256 _waid,
        uint256 _raid,
        string memory _uri,
        bytes32 _hash
    ) internal {
        address _worker = market.getTask(taskId).worker;
        _relay(_req, 0, abi.encodeCall(market.rateTask, (taskId, _worker, _rating, _waid, _raid, _uri, _hash)));
    }

    function _cancelTask(bytes32 taskId, address _req) internal {
        _relay(_req, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function _rejectSubmission(bytes32 taskId, address _req, address _worker) internal {
        _relay(_req, 0, abi.encodeCall(market.rejectSubmission, (taskId, _worker)));
    }

    function _updateTask(
        bytes32 taskId,
        address _req,
        uint256 additionalPayment,
        uint256 _newReward,
        uint256 _newExpiry,
        uint256 _newBidDl,
        uint256 _newPitchDl
    ) internal {
        _relay(
            _req,
            additionalPayment,
            abi.encodeCall(market.updateTask, (taskId, _newReward, _newExpiry, _newBidDl, _newPitchDl))
        );
    }

    // -----------------------------------------------------------------------
    // Constructor / initialization
    // -----------------------------------------------------------------------

    function test_Constructor() public view {
        assertEq(address(market.usdcToken()), address(usdc));
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.defaultFeeBps(), defaultFeeBps);
        assertTrue(market.isTrustedForwarder(address(forwarder)));
    }

    // -----------------------------------------------------------------------
    // ERC-165 / supportsInterface
    // -----------------------------------------------------------------------

    function test_SupportsInterface_ITMPCore() public view {
        assertTrue(market.supportsInterface(type(ITMPCore).interfaceId));
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

        vm.expectEmit(true, true, true, true);
        emit ITMPCore.TaskCreated(expectedId, requester, REWARD, market.BOUNTY(), block.timestamp + DURATION);

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        assertEq(taskId, expectedId);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
        assertEq(task.reward, REWARD);
        assertEq(task.mode, market.BOUNTY());
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open));
    }

    function test_TaskCreated_ModeIsIndexedTopic() public {
        bytes32 expectedId = _nextTaskId(requester);
        // topic3 = mode (indexed); checkData = reward + expiryTime
        vm.expectEmit(true, true, true, true);
        emit ITMPCore.TaskCreated(expectedId, requester, REWARD, market.BOUNTY(), block.timestamp + DURATION);
        _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
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

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
        assertEq(task.worker, worker1);

        assertEq(market.getWorkerStats(worker1).completedTasks, 1);
    }

    function test_ClaimTask_Claim() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint256 stakeAmount = REWARD / 10;

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.TaskClaimed(taskId, worker1, stakeAmount);

        _claimTask(taskId, worker1, stakeAmount);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Claimed));
        assertEq(task.worker, worker1);
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

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open));
        assertEq(task.worker, address(0));
        assertEq(task.stakeAmount, 0);
    }

    function test_SelectWorker_Pitch() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);

        vm.expectEmit(true, true, false, false);
        emit ITMPCore.TaskWorkerSelected(taskId, worker1);

        _selectWorker(taskId, requester, worker1);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.WorkerSelected));
        assertEq(task.worker, worker1);
    }

    function test_AcceptSubmission_Pitch() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        _acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1) - 1000 * 10 ** 6, expectedWorkerPayment);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_AcceptSubmission_Benchmark() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);

        uint256 expectedFee = (REWARD * defaultFeeBps) / 10000;
        uint256 expectedWorkerPayment = REWARD - expectedFee;

        _acceptSubmission(taskId, requester, worker1);

        assertEq(usdc.balanceOf(worker1) - 1000 * 10 ** 6, expectedWorkerPayment);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_RateTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.TaskRated(taskId, worker1, 5, 0);

        _rateTask(taskId, requester, 5, 0, 0, "", bytes32(0));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.rating, 5);

        ITMPCore.WorkerStats memory ws = market.getWorkerStats(worker1);
        assertEq(ws.ratedTasks, 1);
        assertEq(ws.totalStars, 5);
    }

    function test_RefundExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Expired));
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

    function test_SetReputationRegistry_UpdatesAddress() public {
        address newRegistry = address(0x1234);
        vm.prank(owner);
        market.setReputationRegistry(newRegistry);
        assertEq(market.reputationRegistry(), newRegistry);
    }

    function test_RevertWhen_SetReputationRegistry_NonOwner() public {
        vm.prank(worker1);
        vm.expectRevert();
        market.setReputationRegistry(address(0x1234));
    }

    function test_RevertWhen_ClaimNonClaimTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotAClaimTask.selector);
        forwarder.relay(address(market), worker1, REWARD / 10, abi.encodeCall(market.claimTask, (taskId, REWARD / 10)));
    }

    function test_RevertWhen_SelectWorkerNonPitchTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotAPitchTask.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
    }

    function test_RevertWhen_ForfeitTooEarly() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, REWARD / 10);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function test_AcceptExpiredBounty_WithSubmission_Succeeds() public {
        // Bounty expiryTime closes the submission window but not the acceptance window.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        vm.warp(block.timestamp + DURATION + 1);
        _acceptSubmission(taskId, requester, worker1, keccak256("work"));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_RevertWhen_AcceptExpiredTask_Claim() public {
        // Claim still enforces expiryTime on acceptSubmission.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        vm.warp(block.timestamp + DURATION + 1);
        vm.expectRevert(ITMPCore.TaskIsExpired.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker1, keccak256("work"), 0))
        );
    }

    function test_RevertWhen_RateSameWorkerTwice() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, 5, 0, 0, "", bytes32(0));
        vm.expectRevert(ITMPCore.WorkerAlreadyRated.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.rateTask, (taskId, worker1, 4, 0, 0, "", bytes32(0)))
        );
    }

    // -----------------------------------------------------------------------
    // Access control (onlyTrustedForwarder) — non-forwarder caller
    // -----------------------------------------------------------------------

    function test_RevertWhen_NonServer_CreateTask() public {
        bytes4 bounty = market.BOUNTY();
        vm.prank(alice);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.createTask(
            REWARD,
            DURATION,
            bounty,
            0,
            0,
            bytes4(0),
            ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
            ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
        );
    }

    function test_RevertWhen_NonServer_ClaimTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);

        vm.prank(alice);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.claimTask(taskId, 0);
    }

    function test_RevertWhen_NonServer_SelectWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);

        vm.prank(alice);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.selectWorker(taskId, worker1);
    }

    function test_RevertWhen_NonServer_AcceptSubmission() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        vm.prank(alice);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.acceptSubmission(taskId, worker1, keccak256("work"), 0);
    }

    function test_RevertWhen_NonServer_ForfeitAndReopen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, REWARD / 10);

        vm.warp(block.timestamp + DURATION + 1);

        vm.prank(alice);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.forfeitAndReopen(taskId);
    }

    function test_RevertWhen_NonServer_RateTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);

        vm.prank(alice);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.rateTask(taskId, worker1, 5, 0, 0, "", bytes32(0));
    }

    // -----------------------------------------------------------------------
    // addForwarder / removeForwarder
    // -----------------------------------------------------------------------

    function test_AddForwarder() public {
        MockPGTRForwarder newForwarder = new MockPGTRForwarder(address(usdc));
        usdc.mint(address(newForwarder), REWARD);

        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true);
        emit ITMPCore.ForwarderUpdated(address(newForwarder), true);
        market.addForwarder(address(newForwarder));
        vm.stopPrank();

        assertTrue(market.isTrustedForwarder(address(newForwarder)));

        bytes32 taskId = abi.decode(
            newForwarder.relay(
                address(market),
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.BOUNTY(),
                        0,
                        0,
                        bytes4(0),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
    }

    function test_RemoveForwarder() public {
        vm.prank(owner);
        market.removeForwarder(address(forwarder));

        assertFalse(market.isTrustedForwarder(address(forwarder)));

        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                DURATION,
                market.BOUNTY(),
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_RevertWhen_AddForwarder_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ITMPCore.InvalidForwarderAddress.selector);
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
        // Build the cuts array using the same selectors as setUp.
        AdminFacet adminFacet = new AdminFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(adminFacet), IDiamondCut.FacetCutAction.Add, _adminSelectors());
        bytes memory badInit = abi.encodeCall(AdminFacet.initialize, (address(usdc), address(0), defaultFeeBps));
        vm.expectRevert(ITMPCore.InvalidFeeRecipient.selector);
        new Diamond(owner, cuts, address(adminFacet), badInit);
    }

    function test_RevertWhen_Constructor_FeeBpsTooHigh() public {
        AdminFacet adminFacet = new AdminFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(adminFacet), IDiamondCut.FacetCutAction.Add, _adminSelectors());
        bytes memory badInit = abi.encodeCall(AdminFacet.initialize, (address(usdc), feeRecipient, 10001));
        vm.expectRevert(ITMPCore.FeeBpsTooHigh.selector);
        new Diamond(owner, cuts, address(adminFacet), badInit);
    }

    // -----------------------------------------------------------------------
    // createTask input validation
    // -----------------------------------------------------------------------

    function test_RevertWhen_CreateTask_ZeroRequester() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                DURATION,
                market.BOUNTY(),
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert(ITMPCore.InvalidRequester.selector);
        forwarder.relay(address(market), address(0), REWARD, data);
    }

    function test_RevertWhen_CreateTask_ZeroReward() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                0,
                DURATION,
                market.BOUNTY(),
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert(ITMPCore.RewardMustBeGreaterThanZero.selector);
        forwarder.relay(address(market), requester, 0, data);
    }

    function test_RevertWhen_CreateTask_ZeroDuration() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                0,
                market.BOUNTY(),
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert(ITMPCore.DurationMustBeGreaterThanZero.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_RevertWhen_CreateTask_InvalidMode() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                DURATION,
                bytes4(0xdeadbeef),
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert(ITMPCore.InvalidMode.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_RevertWhen_CreateTask_Auction_InvalidSubtype() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                DURATION,
                market.AUCTION(),
                0,
                1 days,
                bytes4(0xdeadbeef),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert(ITMPCore.InvalidAuctionSubtype.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_CreateTask_Auction_StoresSubtype() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        assertEq(market.getTaskAuctionConfig(taskId).auctionSubtype, market.AUCTION_ENGLISH());
    }

    function test_CreateTask_NonAuction_SubtypeZero() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.getTaskAuctionConfig(taskId).auctionSubtype, bytes4(0));
    }

    // -----------------------------------------------------------------------
    // claimTask additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_ClaimTask_TaskExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert(ITMPCore.TaskIsExpired.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    function test_RevertWhen_ClaimTask_AlreadyClaimed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);

        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    // -----------------------------------------------------------------------
    // Wrong requester reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_SelectWorker_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
    }

    function test_RevertWhen_AcceptSubmission_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        forwarder.relay(
            address(market),
            worker2,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker1, keccak256("work"), 0))
        );
    }

    function test_RevertWhen_ForfeitAndReopen_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, REWARD / 10);

        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert(ITMPCore.NotRequester.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function test_RevertWhen_RateTask_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        forwarder.relay(
            address(market), worker2, 0, abi.encodeCall(market.rateTask, (taskId, worker1, 5, 0, 0, "", bytes32(0)))
        );
    }

    // -----------------------------------------------------------------------
    // selectWorker additional reverts
    // -----------------------------------------------------------------------

    function test_SelectWorker_AfterPitchDeadline_Succeeds() public {
        // pitchDeadline closes new pitch submissions but does not block worker selection;
        // the requester may review received pitches and select after the window closes.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 1 days, 0);
        vm.warp(block.timestamp + 1 days + 1);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.WorkerSelected));
    }

    function test_RevertWhen_SelectWorker_NotOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker2)));
    }

    // -----------------------------------------------------------------------
    // acceptSubmission additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_AcceptSubmission_Claim_WrongClaimer() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        vm.expectRevert(ITMPCore.WorkerMismatch.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker2, bytes32(0), 0))
        );
    }

    function test_RevertWhen_AcceptSubmission_Pitch_WrongWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.WorkerMismatch.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker2, bytes32(0), 0))
        );
    }

    // -----------------------------------------------------------------------
    // submitWork
    // -----------------------------------------------------------------------

    function test_SubmitWork_Bounty_StaysOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 deliverable = keccak256("my work artifact");

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.TaskSubmitted(taskId, worker1, deliverable);

        _submitWork(taskId, worker1, deliverable);

        ITMPCore.Task memory task = market.getTask(taskId);
        // Bounty is an open contest: submitting does NOT flip the status. The task
        // stays Open until the requester accepts a winner (or it expires), so the
        // requester is never locked out of cancel/update.
        // task.deliverable stays zero until acceptSubmission (deferred-write model).
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open));
        assertEq(task.deliverable, bytes32(0));
    }

    function test_SubmitWork_Bounty_MultipleSubmissions_Allowed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 deliverableA = keccak256("worker A artifact");
        bytes32 deliverableB = keccak256("worker B artifact");
        bytes32 deliverableC = keccak256("worker C artifact");

        _submitWork(taskId, worker1, deliverableA);
        _submitWork(taskId, worker2, deliverableB);
        _submitWork(taskId, alice, deliverableC);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open), "bounty stays Open across submissions");
        assertEq(task.deliverable, bytes32(0), "task.deliverable must stay zero until acceptance");
    }

    function test_SubmitWork_Benchmark_StaysOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        bytes32 deliverable = keccak256("benchmark result");

        _submitWork(taskId, worker1, deliverable);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open));
        assertEq(task.deliverable, bytes32(0));
    }

    function test_SubmitWork_Benchmark_MultipleSubmissions_Allowed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);

        _submitWork(taskId, worker1, keccak256("proof A"));
        _submitWork(taskId, worker2, keccak256("proof B"));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Open));
        assertEq(task.deliverable, bytes32(0));
    }

    function test_UpdateTask_BountyWithSubmissions_StillOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        // Bounty stays Open after a submission, so the requester can still extend the
        // expiry and raise the reward while the contest is live.
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Open));

        uint256 newExpiry = block.timestamp + DURATION * 2;
        _updateTask(taskId, requester, 0, 0, newExpiry, 0, 0);
        assertEq(market.getTask(taskId).expiryTime, newExpiry);

        uint256 newReward = REWARD * 2;
        _updateTask(taskId, requester, newReward - REWARD, newReward, 0, 0, 0);
        assertEq(market.getTask(taskId).reward, newReward);
    }

    function test_UpdateTask_BenchmarkWithSubmissions_StillOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        _submitWork(taskId, worker1, keccak256("proof"));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Open));

        uint256 newExpiry = block.timestamp + DURATION * 2;
        _updateTask(taskId, requester, 0, 0, newExpiry, 0, 0);
        assertEq(market.getTask(taskId).expiryTime, newExpiry);
    }

    function test_RefundExpired_OpenBountyWithSubmissions_Reverts() public {
        // Once submissions exist the escrow is locked; auto-refund is blocked to protect workers.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Open));

        vm.warp(block.timestamp + DURATION + 1);
        vm.expectRevert(ITMPCore.SubmissionsExist.selector);
        market.refundExpired(taskId, 0);
    }

    function test_SubmitWork_Claim_NoStateChange() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);

        bytes32 deliverable = keccak256("claim work");
        _submitWork(taskId, worker1, deliverable);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Claimed));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_Pitch_NoStateChange() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);

        bytes32 deliverable = keccak256("pitch work");
        _submitWork(taskId, worker1, deliverable);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.WorkerSelected));
        assertEq(task.deliverable, deliverable);
    }

    function test_SubmitWork_ThenAcceptSubmission_Bounty() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        _acceptSubmission(taskId, requester, worker1);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_RevertWhen_SubmitWork_TaskExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert(ITMPCore.TaskIsExpired.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function test_RevertWhen_SubmitWork_Claim_WrongWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);

        vm.expectRevert(ITMPCore.WorkerMismatch.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function test_RevertWhen_SubmitWork_Pitch_WrongWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);

        vm.expectRevert(ITMPCore.WorkerMismatch.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));

        // State must be unchanged
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.WorkerSelected));
        assertEq(task.deliverable, bytes32(0));
    }

    // -----------------------------------------------------------------------
    // rateTask additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_RateTask_NotAccepted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.TaskNotAccepted.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.rateTask, (taskId, worker1, 3, 0, 0, "", bytes32(0)))
        );
    }

    function test_RevertWhen_RateTask_InvalidRating() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.RatingMustBe0To100.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.rateTask, (taskId, worker1, 101, 0, 0, "", bytes32(0)))
        );
    }

    // -----------------------------------------------------------------------
    // refundExpired edge cases
    // -----------------------------------------------------------------------

    function test_RevertWhen_RefundExpired_NotYetExpired() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);
    }

    function test_RevertWhen_RefundExpired_TaskDoesNotExist() public {
        vm.expectRevert(ITMPCore.TaskDoesNotExist.selector);
        market.refundExpired(keccak256("nonexistent"), 0);
    }

    function test_RevertWhen_RefundExpired_AlreadyAccepted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);

        vm.warp(block.timestamp + DURATION + 1);

        vm.expectRevert(ITMPCore.TaskAlreadyAccepted.selector);
        market.refundExpired(taskId, 0);
    }

    function test_RefundExpired_Claim_ReturnsStake() public {
        uint256 stakeAmount = REWARD / 10;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, stakeAmount);

        vm.warp(block.timestamp + DURATION + 1);

        uint256 worker1BalanceBefore = usdc.balanceOf(worker1);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        market.refundExpired(taskId, 0);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + stakeAmount);
    }

    function test_RefundExpired_Review_ForfeitsEvaluatorStake() public {
        uint256 stakeAmount = REWARD / 10;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindowSecs = uint32(2 days);

        // Requester pays evaluator stake directly to TaskMarket (not via forwarder).
        usdc.mint(requester, stakeAmount);
        vm.prank(requester);
        usdc.approve(address(market), stakeAmount);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, stakeAmount, 0, evalWindowSecs, uint32(1 days), address(0))
            )
        );

        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Review));

        // Warp past the original task expiry (7 days). evalWindowSecs (2 days) < DURATION (7 days),
        // so submitWork did not extend expiryTime; the original expiry still applies.
        vm.warp(block.timestamp + DURATION + 1);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 requesterBefore = usdc.balanceOf(requester);

        vm.expectEmit(true, true, false, true);
        emit ITMPEvaluator.EvaluatorTimedOut(taskId, evaluator, stakeAmount);

        market.refundExpired(taskId, 0);

        assertEq(
            usdc.balanceOf(feeRecipient), feeRecipientBefore + stakeAmount, "evaluator stake forfeited to fee recipient"
        );
        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD, "reward refunded to requester");
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, 0, "stake zeroed");
    }

    // -----------------------------------------------------------------------
    // forfeitAndReopen additional reverts
    // -----------------------------------------------------------------------

    function test_RevertWhen_ForfeitAndReopen_NotClaim() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotAClaimTask.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    function test_RevertWhen_ForfeitAndReopen_NotClaimed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.expectRevert(ITMPCore.TaskNotClaimed.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));
    }

    // -----------------------------------------------------------------------
    // Admin setters
    // -----------------------------------------------------------------------

    function test_RevertWhen_SetDefaultFeeBps_TooHigh() public {
        vm.prank(owner);
        vm.expectRevert(ITMPCore.FeeBpsTooHigh.selector);
        market.setDefaultFeeBps(10001);
    }

    function test_RevertWhen_NonOwner_SetFeeRecipient() public {
        vm.prank(alice);
        vm.expectRevert();
        market.setFeeRecipient(address(99));
    }

    function test_RevertWhen_SetFeeRecipient_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ITMPCore.InvalidRecipient.selector);
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

        ITMPCore.Task memory t1 = market.getTask(taskId1);
        ITMPCore.Task memory t2 = market.getTask(taskId2);
        assertEq(t1.worker, worker1);
        assertEq(t2.worker, worker1);
    }

    // -----------------------------------------------------------------------
    // View function tests: feeForTask, getBids, evaluatorFor
    // -----------------------------------------------------------------------

    function test_FeeForTask_ReturnsTaskFee() public {
        vm.prank(owner);
        market.setDefaultFeeBps(500);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.feeForTask(taskId), 500);
    }

    function test_GetBids_EmptyBeforeBid() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        assertEq(market.getBids(taskId).length, 0);
    }

    function test_GetBids_AfterBid() public {
        uint256 price = REWARD / 2;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        _submitBid(taskId, worker1, price);
        ITMPCore.Bid[] memory bids = market.getBids(taskId);
        assertEq(bids.length, 1);
        assertEq(bids[0].worker, worker1);
        assertEq(bids[0].price, price);
    }

    function test_EvaluatorFor_NoEvaluatorReturnsZero() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.evaluatorFor(taskId), address(0));
    }

    function test_EvaluatorFor_ReturnsAssignedEvaluator() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(1 days), uint32(1 days));
        assertEq(market.evaluatorFor(taskId), evaluator);
    }

    // -----------------------------------------------------------------------
    // acceptAuction tests
    // -----------------------------------------------------------------------

    function test_AcceptAuction_success() public {
        uint256 acceptPrice = 40 * 10 ** 6;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.AuctionAccepted(taskId, worker1, acceptPrice);
        _acceptAuction(taskId, worker1, acceptPrice);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Claimed));
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

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_AcceptAuction_priceExceedsMax() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        vm.expectRevert(ITMPCore.PriceExceedsMaxPrice.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD + 1)));
    }

    function test_AcceptAuction_notAuction() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotAnAuctionTask.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD / 2)));
    }

    function test_RevertWhen_AcceptAuction_EnglishSubtype() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        vm.expectRevert(ITMPCore.NotAClockPriceAuction.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD / 2)));
    }

    function test_RevertWhen_AcceptAuction_ReverseEnglishSubtype() public {
        bytes32 taskId =
            _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_REVERSE_ENGLISH());
        vm.expectRevert(ITMPCore.NotAClockPriceAuction.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD / 2)));
    }

    function test_AcceptAuction_notOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, REWARD / 2);

        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.acceptAuction, (taskId, REWARD / 3)));
    }

    function test_RevertWhen_SubmitBid_DutchSubtype() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        vm.expectRevert(ITMPCore.NotABidAuction.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.submitBid, (taskId, REWARD / 2)));
    }

    function test_RevertWhen_SubmitBid_ReverseDutchSubtype() public {
        bytes32 taskId =
            _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_REVERSE_DUTCH());
        vm.expectRevert(ITMPCore.NotABidAuction.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.submitBid, (taskId, REWARD / 2)));
    }

    function test_RevertWhen_SelectLowestBidder_DutchSubtype() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        vm.expectRevert(ITMPCore.NotABidAuction.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectLowestBidder, (taskId)));
    }

    // -----------------------------------------------------------------------
    // Diamond upgrade tests (replaces UUPS upgrade tests)
    // -----------------------------------------------------------------------

    function test_DiamondCut_PreservesState() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, REWARD / 2);

        // Re-deploy CoreFacet and replace one selector — state must be preserved.
        CoreFacet newCore = new CoreFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CoreFacet.claimTask.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newCore), IDiamondCut.FacetCutAction.Replace, sels);
        vm.prank(owner);
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.requester, requester);
        assertEq(task.worker, worker1);
        assertEq(task.stakeAmount, REWARD / 2);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Claimed));
        assertEq(task.mode, market.AUCTION());
    }

    function test_DiamondCut_OnlyOwner() public {
        CoreFacet newCore = new CoreFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CoreFacet.claimTask.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newCore), IDiamondCut.FacetCutAction.Replace, sels);
        vm.prank(alice);
        vm.expectRevert();
        IDiamondCut(address(market)).diamondCut(cuts, address(0), "");
    }

    // -----------------------------------------------------------------------
    // refundExpired auction tests
    // -----------------------------------------------------------------------

    function test_RefundExpired_Auction_NoWinner() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        vm.warp(block.timestamp + DURATION + 1);

        uint256 requesterBalanceBefore = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Expired));
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
        emit ITMPCore.TaskCompleted(taskId, requester, worker1, expectedWorkerPayment, fee);
        market.refundExpired(taskId, 0);

        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + expectedRequesterRefund);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + fee);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));

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

        market.refundExpired(taskId, 0);

        assertEq(usdc.balanceOf(worker1), worker1BalanceBefore + expectedWorkerPayment);
        assertEq(usdc.balanceOf(requester), requesterBalanceBefore);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    // -----------------------------------------------------------------------
    // cancelTask tests
    // -----------------------------------------------------------------------

    function test_CancelTask_Bounty() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.TaskCancelled(taskId, requester, REWARD);

        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Cancelled));
    }

    function test_CancelTask_OpenBountyWithSubmissions_Reverts() public {
        // Once a submission exists the escrow is locked; cancel is blocked to protect workers.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Open));

        vm.expectRevert(ITMPCore.SubmissionsExist.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_CancelTask_OpenBenchmarkWithSubmissions_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        _submitWork(taskId, worker1, keccak256("proof"));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Open));

        vm.expectRevert(ITMPCore.SubmissionsExist.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_CancelTask_Claim() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Cancelled));
    }

    function test_CancelTask_Auction_NoBids() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + REWARD);
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Cancelled));
    }

    function test_RevertWhen_CancelTask_AuctionHasBids() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        _submitBid(taskId, worker1, REWARD / 2);
        vm.expectRevert(ITMPCore.BidsExist.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_RevertWhen_CancelTask_NotOpen_Claimed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_RevertWhen_CancelTask_WrongRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_RevertWhen_CancelTask_NonServer() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        vm.prank(alice);
        vm.expectRevert(ITMPCore.NotTrustedForwarder.selector);
        market.cancelTask(taskId, 0);
    }

    function test_RevertWhen_CancelTask_DoesNotExist() public {
        vm.expectRevert(ITMPCore.TaskDoesNotExist.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (keccak256("nonexistent"), 0)));
    }

    // -----------------------------------------------------------------------
    // rejectSubmission tests
    // -----------------------------------------------------------------------

    function test_rejectSubmission_allowsCancelWhenAllRejected() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work1"));
        _submitWork(taskId, worker2, keccak256("work2"));

        // One submission rejected; the other is still active => cancel must still revert.
        _rejectSubmission(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.SubmissionsExist.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));

        // Reject the remaining submission; now cancel must succeed and return escrow.
        uint256 balanceBefore = usdc.balanceOf(requester);
        _rejectSubmission(taskId, requester, worker2);
        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), balanceBefore + REWARD);
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Cancelled));
    }

    function test_rejectSubmission_blocksWorkerFromResubmitting() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work1"));
        _rejectSubmission(taskId, requester, worker1);

        vm.expectRevert(ITMPCore.SubmissionAlreadyRejected.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work2"))));
    }

    function test_rejectSubmission_revertsIfAlreadyRejected() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work1"));
        _rejectSubmission(taskId, requester, worker1);

        vm.expectRevert(ITMPCore.SubmissionAlreadyRejected.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker1)));
    }

    function test_rejectSubmission_revertsIfNotRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work1"));

        vm.expectRevert(ITMPCore.NotRequester.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker1)));
    }

    function test_rejectSubmission_revertsIfNotBountyBenchmark() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);

        vm.expectRevert(ITMPCore.InvalidMode.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.rejectSubmission, (taskId, worker1)));
    }

    function test_cancelTask_stillBlockedWhenActiveSubmissionsRemain() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work1"));
        _submitWork(taskId, worker2, keccak256("work2"));

        // Reject only worker1; worker2's submission is still active.
        _rejectSubmission(taskId, requester, worker1);

        vm.expectRevert(ITMPCore.SubmissionsExist.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_rejectSubmission_multiSubmitSingleWorker_clearFullCount() public {
        // Worker submits three times; a single rejectSubmission must clear all three
        // counts so cancelTask becomes available. Regression for the bug where
        // rejectSubmission decremented by 1 regardless of how many times the worker
        // had submitted, permanently locking escrow when count > 1.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work v1"));
        _submitWork(taskId, worker1, keccak256("work v2"));
        _submitWork(taskId, worker1, keccak256("work v3"));

        uint256 balanceBefore = usdc.balanceOf(requester);
        _rejectSubmission(taskId, requester, worker1);
        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), balanceBefore + REWARD);
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Cancelled));
    }

    function test_rejectSubmission_multiSubmitMixedWorkers_cancelUnblocked() public {
        // worker1 submits once; worker2 submits three times. Rejecting both once
        // must fully drain the active count (1 + 3 = 4 total, all cleared by 2 rejects).
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("w1 v1"));
        _submitWork(taskId, worker2, keccak256("w2 v1"));
        _submitWork(taskId, worker2, keccak256("w2 v2"));
        _submitWork(taskId, worker2, keccak256("w2 v3"));

        // Reject worker1 only — 3 of worker2's submissions still active.
        _rejectSubmission(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.SubmissionsExist.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));

        // Reject worker2 — all 3 of their submissions cleared in one call.
        uint256 balanceBefore = usdc.balanceOf(requester);
        _rejectSubmission(taskId, requester, worker2);
        _cancelTask(taskId, requester);

        assertEq(usdc.balanceOf(requester), balanceBefore + REWARD);
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Cancelled));
    }

    // -----------------------------------------------------------------------
    // updateTask tests
    // -----------------------------------------------------------------------

    function test_UpdateTask_RewardIncrease() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 newReward = REWARD * 2;
        uint256 additionalPayment = newReward - REWARD;

        vm.expectEmit(true, false, false, false);
        emit ITMPCore.TaskUpdated(taskId, newReward, block.timestamp + DURATION);

        _updateTask(taskId, requester, additionalPayment, newReward, 0, 0, 0);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.reward, newReward);
    }

    function test_UpdateTask_RewardDecrease() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 newReward = REWARD / 2;
        uint256 requesterBalanceBefore = usdc.balanceOf(requester);

        _updateTask(taskId, requester, 0, newReward, 0, 0, 0);

        assertEq(usdc.balanceOf(requester), requesterBalanceBefore + (REWARD - newReward));

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.reward, newReward);
    }

    function test_UpdateTask_ExpiryUpdate() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 newExpiry = block.timestamp + DURATION * 2;
        _updateTask(taskId, requester, 0, 0, newExpiry, 0, 0);
        assertEq(market.getTask(taskId).expiryTime, newExpiry);
    }

    function test_RevertWhen_UpdateTask_ExpiryInPast() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + 1000);
        vm.expectRevert(ITMPCore.ExpiryMustBeInFuture.selector);
        _updateTask(taskId, requester, 0, 0, block.timestamp - 1, 0, 0);
    }

    function test_UpdateTask_BidDeadline_Auction() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        uint256 newBidDeadline = block.timestamp + 2 days;
        _updateTask(taskId, requester, 0, 0, 0, newBidDeadline, 0);
        assertEq(market.getTaskAuctionConfig(taskId).bidDeadline, newBidDeadline);
    }

    function test_RevertWhen_UpdateTask_BidDeadlineInPast() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        vm.warp(block.timestamp + 1000);
        vm.expectRevert(ITMPCore.BidDeadlineMustBeInFuture.selector);
        _updateTask(taskId, requester, 0, 0, 0, block.timestamp - 1, 0);
    }

    function test_UpdateTask_PitchDeadline() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 1 days, 0);
        uint256 newPitchDeadline = block.timestamp + 2 days;
        _updateTask(taskId, requester, 0, 0, 0, 0, newPitchDeadline);
        assertEq(market.getTaskPitchConfig(taskId).pitchDeadline, newPitchDeadline);
    }

    function test_RevertWhen_UpdateTask_PitchDeadlineInPast() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 1 days, 0);
        vm.warp(block.timestamp + 1000);
        vm.expectRevert(ITMPCore.PitchDeadlineMustBeInFuture.selector);
        _updateTask(taskId, requester, 0, 0, 0, 0, block.timestamp - 1);
    }

    function test_RevertWhen_UpdateTask_NotRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        _updateTask(taskId, worker1, 0, REWARD * 2, 0, 0, 0);
    }

    function test_RevertWhen_UpdateTask_TaskNotOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        _updateTask(taskId, requester, 0, REWARD * 2, 0, 0, 0);
    }

    function test_RevertWhen_UpdateTask_AuctionHasBids() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        _submitBid(taskId, worker1, REWARD / 2);
        vm.expectRevert(ITMPCore.BidsExist.selector);
        _updateTask(taskId, requester, 0, REWARD * 2, 0, 0, 0);
    }

    function test_UpdateTask_Auction_UpdatesMaxPrice() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        uint256 newReward = REWARD * 2;
        uint256 additionalPayment = newReward - REWARD;
        _updateTask(taskId, requester, additionalPayment, newReward, 0, 0, 0);
        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(task.reward, newReward);
        assertEq(market.getTaskAuctionConfig(taskId).maxPrice, newReward);
    }

    function test_UpdateTask_NoEmit_WhenNothingChanges() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.recordLogs();
        _updateTask(taskId, requester, 0, 0, 0, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 taskUpdatedSig = keccak256("TaskUpdated(bytes32,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], taskUpdatedSig);
        }
    }

    function test_UpdateTask_BidDeadline_IgnoredForNonAuction() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 1 days, 0);
        uint256 originalBidDeadline = market.getTaskAuctionConfig(taskId).bidDeadline;
        _updateTask(taskId, requester, 0, 0, 0, block.timestamp + 2 days, 0);
        assertEq(market.getTaskAuctionConfig(taskId).bidDeadline, originalBidDeadline);
    }

    function test_UpdateTask_PitchDeadline_IgnoredForNonPitch() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 originalPitchDeadline = market.getTaskPitchConfig(taskId).pitchDeadline;
        _updateTask(taskId, requester, 0, 0, 0, 0, block.timestamp + 2 days);
        assertEq(market.getTaskPitchConfig(taskId).pitchDeadline, originalPitchDeadline);
    }

    // -----------------------------------------------------------------------
    // submitPitch tests
    // -----------------------------------------------------------------------

    function _submitPitch(bytes32 taskId, address _worker, bytes32 pitchHash) internal {
        _relay(_worker, 0, abi.encodeCall(market.submitPitch, (taskId, pitchHash)));
    }

    function test_SubmitPitch_emitsEventAndStoresHash() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        bytes32 pitchHash = keccak256(abi.encode(taskId, worker1, "my pitch text"));

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.PitchSubmitted(taskId, worker1, pitchHash);
        _submitPitch(taskId, worker1, pitchHash);

        assertEq(market.taskPitchHashes(taskId, 0), pitchHash);
    }

    function test_SubmitPitch_appendsMultiple() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        bytes32 hash1 = keccak256(abi.encode(taskId, worker1, "pitch 1"));
        bytes32 hash2 = keccak256(abi.encode(taskId, worker2, "pitch 2"));

        _submitPitch(taskId, worker1, hash1);
        _submitPitch(taskId, worker2, hash2);

        assertEq(market.taskPitchHashes(taskId, 0), hash1);
        assertEq(market.taskPitchHashes(taskId, 1), hash2);
    }

    function test_SubmitPitch_revertsOnWrongMode() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotAPitchTask.selector);
        _submitPitch(taskId, worker1, keccak256("pitch"));
    }

    function test_SubmitPitch_revertsAfterPitchDeadline() public {
        // Task has a 2-day pitch window inside a 7-day expiry.
        // Warping past the pitch deadline (but not the expiry) must revert.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert(ITMPCore.PitchDeadlinePassed.selector);
        _submitPitch(taskId, worker1, keccak256("late pitch"));
    }

    function test_SubmitPitch_revertsWhenBothDeadlinesPassed() public {
        // Warping past the full task duration (7 days) exceeds both the pitch
        // deadline (2 days) and the expiry time. The pitch-deadline check fires
        // first; this test just confirms the overall "too late" path reverts.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.warp(block.timestamp + DURATION + 1);
        vm.expectRevert(ITMPCore.PitchDeadlinePassed.selector);
        _submitPitch(taskId, worker1, keccak256("pitch"));
    }

    function test_SubmitPitch_revertsOnEmptyHash() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.expectRevert(ITMPCore.EmptyPitchHash.selector);
        _submitPitch(taskId, worker1, bytes32(0));
    }

    // -----------------------------------------------------------------------
    // submitProof tests
    // -----------------------------------------------------------------------

    function _submitProof(bytes32 taskId, address _worker, bytes32 proofHash, bytes32 proofType, uint256 metricValue)
        internal
    {
        _relay(_worker, 0, abi.encodeCall(market.submitProof, (taskId, proofHash, proofType, metricValue)));
    }

    function test_SubmitProof_emitsEventAndStoresHash() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        bytes32 proofHash = keccak256(abi.encode(taskId, worker1, "proof data"));
        bytes32 proofType = keccak256("eval");
        uint256 metricValue = 9500;

        vm.expectEmit(true, true, false, true);
        emit ITMPCore.ProofSubmitted(taskId, worker1, proofHash, proofType, metricValue);
        _submitProof(taskId, worker1, proofHash, proofType, metricValue);

        assertEq(market.taskProofHashes(taskId, 0), proofHash);
    }

    function test_SubmitProof_revertsOnWrongMode() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotABenchmarkTask.selector);
        _submitProof(taskId, worker1, keccak256("proof"), keccak256("eval"), 0);
    }

    function test_SubmitProof_revertsAfterExpiry() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);
        vm.expectRevert(ITMPCore.TaskIsExpired.selector);
        _submitProof(taskId, worker1, keccak256("proof"), keccak256("eval"), 0);
    }

    function test_SubmitProof_revertsOnEmptyHash() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        vm.expectRevert(ITMPCore.EmptyProofHash.selector);
        _submitProof(taskId, worker1, bytes32(0), keccak256("eval"), 0);
    }

    // -----------------------------------------------------------------------
    // Diamond AppStorage layout — state is stored at a fixed keccak256 slot,
    // not at sequential slots 0-N. Verify the AppStorage slot holds the USDC
    // token address written during initialize().
    // -----------------------------------------------------------------------

    function test_AppStorageSlot_HoldsUSDCToken() public view {
        // AppStorage is at keccak256("taskmarket.appstorage.v1").
        // The first field (usdcToken) lives at that slot.
        bytes32 slot = keccak256("taskmarket.appstorage.v1");
        bytes32 raw = vm.load(address(market), slot);
        address storedUsdc = address(uint160(uint256(raw)));
        assertEq(storedUsdc, address(usdc));
    }

    // =======================================================================
    // Multi-submission payouts (acceptSubmissions) + new acceptSubmission semantics + rateTask
    // multi-winner. New surface added in this PR.
    // =======================================================================

    function _acceptSubmissions(
        bytes32 taskId,
        address _req,
        address[] memory workers,
        uint16[] memory shares,
        bytes32[] memory deliverables
    ) internal {
        // Submit work for each worker first (required by on-chain hash verification).
        for (uint256 i = 0; i < workers.length; i++) {
            _submitWork(taskId, workers[i], deliverables[i]);
        }
        bytes32[] memory emptyDeliverables = new bytes32[](0);
        _relay(_req, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, emptyDeliverables, 0)));
    }

    function test_AcceptSubmission_Bounty_RequiresNonZeroDeliverable() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.DeliverableRequired.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, bytes32(0), 0))
        );
    }

    function test_AcceptSubmission_Benchmark_RequiresNonZeroDeliverable() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        vm.expectRevert(ITMPCore.DeliverableRequired.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, bytes32(0), 0))
        );
    }

    function test_AcceptSubmission_LockedWorkerMode_CrossChecksDeliverable() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("the right one"));

        vm.expectRevert(ITMPCore.DeliverableMismatch.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker1, keccak256("wrong"), 0))
        );
    }

    function test_AcceptSubmissions_HappyPath_ThreeWinners_Bounty() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        address[] memory workers = new address[](3);
        workers[0] = worker1;
        workers[1] = worker2;
        workers[2] = alice;

        uint16[] memory shares = new uint16[](3);
        shares[0] = 5000;
        shares[1] = 3000;
        shares[2] = 2000;

        bytes32[] memory deliverables = new bytes32[](3);
        deliverables[0] = keccak256("A");
        deliverables[1] = keccak256("B");
        deliverables[2] = keccak256("C");

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 w1Before = usdc.balanceOf(worker1);
        uint256 w2Before = usdc.balanceOf(worker2);
        uint256 aliceBefore = usdc.balanceOf(alice);

        _acceptSubmissions(taskId, requester, workers, shares, deliverables);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
        assertEq(task.worker, worker1, "task.worker = workers[0]");
        assertEq(task.deliverable, keccak256("A"), "task.deliverable = deliverables[0]");

        uint256 pay1 = (REWARD * 5000) / 10000;
        uint256 pay2 = (REWARD * 3000) / 10000;
        uint256 pay3 = (REWARD * 2000) / 10000;
        uint256 fee1 = (pay1 * defaultFeeBps) / 10000;
        uint256 fee2 = (pay2 * defaultFeeBps) / 10000;
        uint256 fee3 = (pay3 * defaultFeeBps) / 10000;

        assertEq(usdc.balanceOf(worker1) - w1Before, pay1 - fee1);
        assertEq(usdc.balanceOf(worker2) - w2Before, pay2 - fee2);
        assertEq(usdc.balanceOf(alice) - aliceBefore, pay3 - fee3);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, fee1 + fee2 + fee3, "Fees batched into a single transfer");
    }

    function test_AcceptSubmissions_HappyPath_Benchmark() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);

        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 7000;
        shares[1] = 3000;
        bytes32[] memory deliverables = new bytes32[](2);
        deliverables[0] = keccak256("proof A");
        deliverables[1] = keccak256("proof B");

        _acceptSubmissions(taskId, requester, workers, shares, deliverables);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_AcceptSubmissions_RevertsOnSharesSumMismatch_Under() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000; // sum 9000
        shares[1] = 4000;
        _submitWork(taskId, worker1, keccak256("A"));
        _submitWork(taskId, worker2, keccak256("B"));

        vm.expectRevert(ITMPCore.SharesMustSumTo10000.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_RevertsOnSharesSumMismatch_Over() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000; // sum 11000
        shares[1] = 5000;
        _submitWork(taskId, worker1, keccak256("A"));
        _submitWork(taskId, worker2, keccak256("B"));

        vm.expectRevert(ITMPCore.SharesMustSumTo10000.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_RevertsOnArrayLengthMismatch() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](3);
        shares[0] = 5000;
        shares[1] = 3000;
        shares[2] = 2000;

        vm.expectRevert(ITMPCore.LengthMismatch.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_RevertsOnEmptyArrays() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](0);
        uint16[] memory shares = new uint16[](0);
        bytes32[] memory deliverables = new bytes32[](0);

        vm.expectRevert(ITMPCore.NoWinners.selector);
        _acceptSubmissions(taskId, requester, workers, shares, deliverables);
    }

    function test_AcceptSubmissions_RevertsOnNoSubmission() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;

        vm.expectRevert(ITMPCore.SubmissionNotFound.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_RevertsOnLockedWorkerMode_Pitch() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);
        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;

        vm.expectRevert(ITMPCore.MultiSubmissionOnlyForBountyBenchmark.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_RevertsOnLockedWorkerMode_Claim() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;

        vm.expectRevert(ITMPCore.MultiSubmissionOnlyForBountyBenchmark.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_SingleWinner_Equivalent() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;
        bytes32[] memory deliverables = new bytes32[](1);
        deliverables[0] = keccak256("the work");

        uint256 w1Before = usdc.balanceOf(worker1);
        _acceptSubmissions(taskId, requester, workers, shares, deliverables);

        ITMPCore.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMPCore.TaskStatus.Accepted));
        assertEq(task.worker, worker1);
        assertEq(task.deliverable, keccak256("the work"));
        uint256 fee = (REWARD * defaultFeeBps) / 10000;
        assertEq(usdc.balanceOf(worker1) - w1Before, REWARD - fee);
    }

    function test_AcceptSubmissions_RejectsDuplicateWorkers() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        // Submit work for each worker first (required by on-chain hash verification).
        _submitWork(taskId, worker1, keccak256("A"));
        _submitWork(taskId, worker1, keccak256("B"));
        _submitWork(taskId, worker2, keccak256("C"));

        address[] memory workers = new address[](3);
        workers[0] = worker1;
        workers[1] = worker1; // duplicate — must be rejected
        workers[2] = worker2;
        uint16[] memory shares = new uint16[](3);
        shares[0] = 3000;
        shares[1] = 2000;
        shares[2] = 5000;

        vm.expectRevert(abi.encodeWithSelector(ITMPCore.DuplicateAwardWorker.selector));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0)));
    }

    function test_AcceptSubmissions_RevertsOnZeroPayoutPerPair() public {
        // reward small enough that a tiny share rounds payment to 0
        uint256 tinyReward = 100; // 100 base units USDC
        bytes32 taskId = _createTask(requester, tinyReward, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 9999; // share=1 rounds 100*1/10000 = 0
        shares[1] = 1;
        _submitWork(taskId, worker1, keccak256("A"));
        _submitWork(taskId, worker2, keccak256("B"));

        vm.expectRevert(ITMPCore.ZeroPayoutPerPair.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_FeeMath_FeeZero() public {
        // override default fee to 0
        vm.prank(owner);
        market.setDefaultFeeBps(0);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;
        bytes32[] memory deliverables = new bytes32[](2);
        deliverables[0] = keccak256("A");
        deliverables[1] = keccak256("B");

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 w1Before = usdc.balanceOf(worker1);
        uint256 w2Before = usdc.balanceOf(worker2);

        _acceptSubmissions(taskId, requester, workers, shares, deliverables);

        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "no fee when feeBps=0");
        assertEq(usdc.balanceOf(worker1) - w1Before, REWARD / 2);
        assertEq(usdc.balanceOf(worker2) - w2Before, REWARD / 2);
    }

    // --- Submission pinning (rev009) ---

    function test_AcceptSubmissions_PinnedHash_PaysOnV1() public {
        // Worker submits v1 then v2. Requester pins v1 explicitly.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hashV1 = keccak256("deliverable-v1");
        bytes32 hashV2 = keccak256("deliverable-v2");
        _submitWork(taskId, worker1, hashV1);
        _submitWork(taskId, worker1, hashV2);

        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;
        bytes32[] memory pinned = new bytes32[](1);
        pinned[0] = hashV1; // pin v1 explicitly

        uint256 balBefore = usdc.balanceOf(worker1);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, pinned, 0))
        );
        assertGt(usdc.balanceOf(worker1), balBefore, "worker should receive reward");
        assertEq(market.getTask(taskId).deliverable, hashV1, "pinned deliverable should be v1 hash");
    }

    function test_AcceptSubmissions_PinnedWrongHash_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("real-hash"));

        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;
        bytes32[] memory badPin = new bytes32[](1);
        badPin[0] = keccak256("hash-that-was-never-submitted");

        vm.expectRevert(ITMPCore.SubmissionNotFound.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, badPin, 0))
        );
    }

    function test_AcceptSubmissions_ZeroDeliverable_AutoResolvesLatest() public {
        // bytes32(0) in the deliverables array means auto-resolve for that slot.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hashV1 = keccak256("v1");
        bytes32 hashV2 = keccak256("v2");
        _submitWork(taskId, worker1, hashV1);
        _submitWork(taskId, worker1, hashV2);

        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;
        bytes32[] memory autoResolve = new bytes32[](1);
        autoResolve[0] = bytes32(0); // explicit zero = auto-resolve

        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, autoResolve, 0))
        );
        assertEq(market.getTask(taskId).deliverable, hashV2, "auto-resolve should pick latest (v2)");
    }

    function test_AcceptSubmissions_DeliverableLengthMismatch_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("h1"));
        _submitWork(taskId, worker2, keccak256("h2"));

        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;
        bytes32[] memory badLen = new bytes32[](1); // wrong length
        badLen[0] = keccak256("only-one");

        vm.expectRevert(ITMPCore.LengthMismatch.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, badLen, 0))
        );
    }

    function test_RateTask_Bounty_PerWinner() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        // accept submissions to set up two winners
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        bytes32[] memory deliverables = new bytes32[](2);
        deliverables[0] = keccak256("A");
        deliverables[1] = keccak256("B");
        _acceptSubmissions(taskId, requester, workers, shares, deliverables);

        // rate both winners independently
        _rateTask(taskId, requester, worker1, 90, 0, 0, "", bytes32(0));
        _rateTask(taskId, requester, worker2, 60, 0, 0, "", bytes32(0));

        ITMPCore.WorkerStats memory s1 = market.getWorkerStats(worker1);
        ITMPCore.WorkerStats memory s2 = market.getWorkerStats(worker2);
        assertEq(s1.ratedTasks, 1);
        assertEq(s1.totalStars, 90);
        assertEq(s2.ratedTasks, 1);
        assertEq(s2.totalStars, 60);
    }

    function test_RateTask_LockedWorkerMode_RequiresTaskWorker() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);
        _acceptSubmission(taskId, requester, worker1);

        vm.expectRevert(ITMPCore.WorkerMismatch.selector);
        _rateTask(taskId, requester, worker2, 50, 0, 0, "", bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Hook tests
    // -------------------------------------------------------------------------

    function test_HookRegistered_EmittedOnCreate() public {
        MockTaskHook hook = new MockTaskHook();
        vm.expectEmit(true, false, false, true);
        emit ITMPCore.HookRegistered(_nextTaskId(requester), address(hook));
        _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
    }

    function test_HookCheckFund_Revert_BlocksCreate() public {
        MockTaskHook hook = new MockTaskHook();
        hook.setRevertOnCheckFund(true);
        bytes4 mode = market.BOUNTY();
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                DURATION,
                mode,
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert();
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_HookCheckFund_RejectFalse_BlocksCreate() public {
        MockTaskHook hook = new MockTaskHook();
        hook.setRejectOnCheckFund(true);
        bytes4 mode = market.BOUNTY();
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                DURATION,
                mode,
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert(ITMPCore.HookCheckFundRejected.selector);
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_HookCheckClaim_Revert_BlocksClaim() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.CLAIM(), address(hook));
        hook.setRevertOnCheckClaim(true);
        vm.expectRevert();
        _claimTask(taskId, worker1, 0);
    }

    function test_HookCheckSubmit_Revert_BlocksSubmit() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
        hook.setRevertOnCheckSubmit(true);
        vm.expectRevert();
        _submitWork(taskId, worker1, keccak256("work"));
    }

    function test_HookOnComplete_Failure_DoesNotBlockPayment() public {
        // Deploy a hook whose onComplete always reverts
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));

        uint256 before = usdc.balanceOf(worker1);
        // onComplete swallowed — payment should still succeed
        _acceptSubmission(taskId, requester, worker1);
        assertGt(usdc.balanceOf(worker1), before);
        assertEq(hook.onCompleteCalls(), 1);
    }

    function test_HookOnCancel_CalledOnCancel() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
        _cancelTask(taskId, requester);
        assertEq(hook.onCancelCalls(), 1);
    }

    function test_HookOnExpire_DoesNotBlockRefund() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
        vm.warp(block.timestamp + DURATION + 1);
        uint256 before = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);
        assertGt(usdc.balanceOf(requester), before);
        assertEq(hook.onExpireCalls(), 1);
    }

    function test_HookCheckSelectWorker_Revert_BlocksSelectWorker() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.PITCH(), address(hook));
        hook.setRevertOnCheckSelectWorker(true);
        vm.expectRevert();
        _selectWorker(taskId, requester, worker1);
    }

    function test_HookCheckSelectWorker_SeesCommittedState() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.PITCH(), address(hook));
        _submitPitch(taskId, worker1, keccak256(abi.encode(taskId, worker1, "pitch")));
        _selectWorker(taskId, requester, worker1);
        assertEq(hook.checkSelectWorkerCalls(), 1);
        assertEq(uint8(market.getTask(taskId).status), uint8(ITMPCore.TaskStatus.WorkerSelected));
    }

    function test_HookOnForfeit_CalledOnForfeit() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.CLAIM(), address(hook));
        _claimTask(taskId, worker1, 0);
        vm.warp(block.timestamp + DURATION + 1);
        _forfeitAndReopen(taskId, requester);
        assertEq(hook.onForfeitCalls(), 1);
    }

    // -------------------------------------------------------------------------
    // Multi-hook tests (Rev008)
    // -------------------------------------------------------------------------

    function test_MultiHook_BothFire() public {
        MockTaskHook hookA = new MockTaskHook();
        MockTaskHook hookB = new MockTaskHook();
        address[] memory hooks = new address[](2);
        hooks[0] = address(hookA);
        hooks[1] = address(hookB);
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.BOUNTY(),
                        0,
                        0,
                        bytes4(0),
                        ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );
        assertEq(market.getTaskHooks(taskId).length, 2);
        assertEq(market.getTaskHooks(taskId)[0], address(hookA));
        assertEq(market.getTaskHooks(taskId)[1], address(hookB));
        _acceptSubmission(taskId, requester, worker1);
        assertEq(hookA.onCompleteCalls(), 1);
        assertEq(hookB.onCompleteCalls(), 1);
    }

    function test_MultiHook_CheckRejectBlocksAll() public {
        MockTaskHook hookA = new MockTaskHook();
        MockTaskHook hookB = new MockTaskHook();
        hookB.setRejectOnCheckFund(true);
        address[] memory hooks = new address[](2);
        hooks[0] = address(hookA);
        hooks[1] = address(hookB);
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                REWARD,
                DURATION,
                market.BOUNTY(),
                0,
                0,
                bytes4(0),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
            )
        );
        vm.expectRevert();
        forwarder.relay(address(market), requester, REWARD, data);
    }

    function test_DefaultHooks_PrependedToEveryTask() public {
        MockTaskHook defaultHook = new MockTaskHook();
        address[] memory dh = new address[](1);
        dh[0] = address(defaultHook);
        vm.prank(owner);
        market.setDefaultHooks(dh);

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory resolved = market.getTaskHooks(taskId);
        assertEq(resolved.length, 1);
        assertEq(resolved[0], address(defaultHook));
        _acceptSubmission(taskId, requester, worker1);
        assertEq(defaultHook.onCompleteCalls(), 1);
    }

    function test_DefaultHooks_PrependedBeforeRequesterHooks() public {
        MockTaskHook defaultHook = new MockTaskHook();
        MockTaskHook reqHook = new MockTaskHook();
        address[] memory dh = new address[](1);
        dh[0] = address(defaultHook);
        vm.prank(owner);
        market.setDefaultHooks(dh);

        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(reqHook));
        address[] memory resolved = market.getTaskHooks(taskId);
        assertEq(resolved.length, 2);
        assertEq(resolved[0], address(defaultHook));
        assertEq(resolved[1], address(reqHook));
    }

    function test_DefaultHooks_DoNotAffectPreviousTasks() public {
        // Create task before setting default hooks
        bytes32 taskIdBefore = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.getTaskHooks(taskIdBefore).length, 0);

        MockTaskHook defaultHook = new MockTaskHook();
        address[] memory dh = new address[](1);
        dh[0] = address(defaultHook);
        vm.prank(owner);
        market.setDefaultHooks(dh);

        // New task gets the default hook
        bytes32 taskIdAfter = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.getTaskHooks(taskIdAfter).length, 1);

        // Old task still has no hooks
        assertEq(market.getTaskHooks(taskIdBefore).length, 0);
    }

    // -------------------------------------------------------------------------
    // Task registry tests
    // -------------------------------------------------------------------------

    function test_GetTaskState_ReturnsCorrectStatus() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Open));
        _acceptSubmission(taskId, requester, worker1);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_GetTaskContext_IncludesTags() public {
        bytes32[] memory tags = new bytes32[](2);
        tags[0] = keccak256("defi");
        tags[1] = keccak256("audit");
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.BOUNTY(),
                        0,
                        0,
                        bytes4(0),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: tags })
                    )
                )
            ),
            (bytes32)
        );
        ITMPCore.TaskContext memory ctx = market.getTaskContext(taskId);
        assertEq(ctx.tags.length, 2);
        assertEq(ctx.tags[0], keccak256("defi"));
    }

    function test_GetTaskVerdict_NotIssuedByDefault() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        ITMPCore.Verdict memory v = market.getTaskVerdict(taskId);
        assertFalse(v.issued);
    }

    // -------------------------------------------------------------------------
    // Evaluator tests
    // -------------------------------------------------------------------------

    address public evaluator = address(10);

    function test_AssignEvaluator_OnlyRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        _relay(
            worker1, 0, abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, 1 days, 1 days, address(0)))
        );
    }

    function test_AssignEvaluator_EmitsEvent() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectEmit(true, true, false, true);
        emit ITMPEvaluator.EvaluatorAssigned(taskId, evaluator, 0);
        _assignEvaluator(taskId, requester, evaluator, 500, uint32(1 days), uint32(1 days));
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, evaluator);
    }

    function test_EvaluatorFlow_Approve_ClaimMode() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Review));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        uint256 before = usdc.balanceOf(worker1);
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 950, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing));

        // finalize after appeal window
        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker1), before);
    }

    function test_EvaluatorFlow_Reject_CancelsTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory noAwards = new ITMPCore.Award[](0);
        uint256 reqBefore = usdc.balanceOf(requester);
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.REJECT, 0, noAwards);

        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);
        // REJECT refunds the full remainder to the requester, so the task terminates
        // (Cancelled) rather than falsely reopening with no escrow left behind it.
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Cancelled));
        assertGt(usdc.balanceOf(requester), reqBefore);
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, address(0));

        // A rejected-and-cancelled task can never be reclaimed.
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        _claimTask(taskId, worker2, 0);
    }

    function test_EvaluatorFlow_Appeal_ThenResolve() public {
        address resolver = address(20);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), resolver))
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);

        // Worker appeals
        _appeal(taskId, worker1);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Disputed));

        // Dispute resolver resolves
        uint256 before = usdc.balanceOf(worker1);
        _relay(resolver, 0, abi.encodeCall(market.resolveDispute, (taskId, ITMPCore.VerdictType.APPROVE, awards)));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker1), before);
    }

    function test_EvaluatorTimeout_ForfeitsStakeAndOpensPendingApproval() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindowSecs = uint32(2 days);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, evalWindowSecs, uint32(1 days), address(0))
            )
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Review));

        // Advance past evaluation window
        vm.warp(block.timestamp + evalWindowSecs + 1);
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.PendingApproval));
    }

    function test_EvaluatorTimeout_ClearsEvaluator_AllowsAcceptSubmission() public {
        // Bug fix: evaluatorTimeout must zero task.evaluator so acceptSubmission can proceed.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindowSecs = uint32(2 days);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, evalWindowSecs, uint32(1 days), address(0))
            )
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        vm.warp(block.timestamp + evalWindowSecs + 1);
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.PendingApproval));

        // Evaluator field must be cleared or acceptSubmission will revert.
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, address(0));

        // Requester should now be able to accept without hitting "Use evaluate(): evaluator assigned".
        uint256 before = usdc.balanceOf(worker1);
        _acceptSubmission(taskId, requester, worker1);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker1), before);
    }

    function test_RefundExpired_Auction_WithWinner_CallsOnCompleteHook() public {
        // Bug fix: the AUCTION+Claimed path in refundExpired must call onComplete hook.
        MockTaskHook hook = new MockTaskHook();
        uint256 acceptPrice = 40 * 10 ** 6;
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.AUCTION(),
                        0,
                        1 days,
                        market.AUCTION_DUTCH(),
                        ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );
        _acceptAuction(taskId, worker1, acceptPrice);

        vm.warp(block.timestamp + DURATION + 1);
        assertEq(hook.onCompleteCalls(), 0);
        market.refundExpired(taskId, 0);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertEq(hook.onCompleteCalls(), 1);
        // onExpire must NOT have been called — this is a completion, not an expiry.
        assertEq(hook.onExpireCalls(), 0);
    }

    function test_RefundExpired_Auction_NoWinner_CallsOnExpireHook() public {
        // AUCTION with no winner (no acceptAuction call) should still call onExpire.
        MockTaskHook hook = new MockTaskHook();
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.AUCTION(),
                        0,
                        1 days,
                        market.AUCTION_DUTCH(),
                        ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );

        vm.warp(block.timestamp + DURATION + 1);
        assertEq(hook.onExpireCalls(), 0);
        market.refundExpired(taskId, 0);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Expired));
        assertEq(hook.onExpireCalls(), 1);
    }

    function test_EvaluatorBountyMode_EvaluateOnOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _submitWork(taskId, worker1, keccak256("work1"));

        // Bounty stays Open after submit; the evaluator can still evaluate from Open.
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Open));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        uint256 before = usdc.balanceOf(worker1);
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing));

        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker1), before);
    }

    function test_HookCheckEvaluate_Revert_BlocksEvaluate() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.CLAIM(), address(hook));
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        hook.setRevertOnCheckEvaluate(true);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        vm.expectRevert();
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);
    }

    function test_SupportsInterface_ITMPRegistry() public view {
        assertTrue(market.supportsInterface(type(ITMPRegistry).interfaceId));
    }

    function test_SupportsInterface_ITMPEvaluator() public view {
        assertTrue(market.supportsInterface(type(ITMPEvaluator).interfaceId));
    }

    function test_GetCredibility_ZeroWithNoRatings() public view {
        assertEq(market.getCredibility(worker1), 0);
    }

    function test_GetCredibility_CorrectAfterRatings() public {
        // 10 rated tasks → credibility = floor(10 / (10+10) * 1000) = 500
        for (uint256 i = 0; i < 10; i++) {
            bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
            _claimTask(taskId, worker1, 0);
            _submitWork(taskId, worker1, keccak256(abi.encode("work", i)));
            _acceptSubmission(taskId, requester, worker1);
            _rateTask(taskId, requester, worker1, 80, 0, 0, "", bytes32(0));
        }
        assertEq(market.getCredibility(worker1), 500);
    }

    function test_GetAverageRating_ZeroWithNoRatings() public view {
        assertEq(market.getAverageRating(worker1), 0);
    }

    function test_GetAverageRating_CorrectAfterRatings() public {
        // 10 ratings of 80 → totalStars = 800, averageRating = 800 * 10 / 10 = 800
        for (uint256 i = 0; i < 10; i++) {
            bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
            _claimTask(taskId, worker1, 0);
            _submitWork(taskId, worker1, keccak256(abi.encode("work", i)));
            _acceptSubmission(taskId, requester, worker1);
            _rateTask(taskId, requester, worker1, 80, 0, 0, "", bytes32(0));
        }
        assertEq(market.getAverageRating(worker1), 800);
    }

    // -------------------------------------------------------------------------
    // Bug-fix tests: refundExpired state guards
    // -------------------------------------------------------------------------

    // expiryTime is extended to max(expiryTime, block.timestamp + evaluationWindow) on Review
    // entry, so refundExpired must NOT fire before the extended deadline when a worker submits
    // close to the original expiry and the evaluation window would push past it.
    function test_RevertWhen_RefundExpired_DuringReview_BeforeExtendedExpiry() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindow = uint32(2 days);
        _assignEvaluator(taskId, requester, evaluator, 0, evalWindow, uint32(1 days));
        _claimTask(taskId, worker1, 0);
        // Submit near the original expiry so the evaluation window extends past it.
        vm.warp(block.timestamp + DURATION - 1 hours);
        _submitWork(taskId, worker1, keccak256("work"));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Review));

        // Warp past the original expiryTime but still inside the evaluation window.
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);
    }

    function test_RefundExpired_DuringReview_AfterExtendedExpiry() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindow = uint32(2 days);
        _assignEvaluator(taskId, requester, evaluator, 0, evalWindow, uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Review));

        // Warp past both the original expiryTime and the evaluationWindow extension.
        vm.warp(block.timestamp + DURATION + evalWindow + 1);
        uint256 before = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);
        assertGt(usdc.balanceOf(requester), before);
    }

    function test_RevertWhen_RefundExpired_DuringAppealing_BeforeExtendedExpiry() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(3 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing));

        // Still inside the appeal window (phaseDeadline), which is also the new expiryTime.
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);
    }

    function test_RefundExpired_DuringAppealing_AfterExtendedExpiry() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindow = uint32(2 days);
        uint32 appealWindow = uint32(3 days);
        _assignEvaluator(taskId, requester, evaluator, 0, evalWindow, appealWindow);
        _claimTask(taskId, worker1, 0);
        // Submit near the original expiry so the appeal window extends past it.
        vm.warp(block.timestamp + DURATION - 1 hours);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing));

        // Warp past the appeal window extension.
        vm.warp(block.timestamp + appealWindow + 1);
        uint256 before = usdc.balanceOf(requester);
        market.refundExpired(taskId, 0);
        assertGt(usdc.balanceOf(requester), before);
    }

    function test_RevertWhen_RefundExpired_DuringDisputed_BeforeExtendedExpiry() public {
        address resolver = address(20);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindow = uint32(2 days);
        uint32 appealWindow = uint32(3 days);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, evalWindow, appealWindow, resolver))
        );
        _claimTask(taskId, worker1, 0);
        // Submit near the original expiry so evaluation + appeal windows extend past it.
        vm.warp(block.timestamp + DURATION - 1 hours);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        _appeal(taskId, worker1);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Disputed));

        // Still inside the appeal window extension — must not be refundable.
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(ITMPCore.TaskNotYetExpired.selector);
        market.refundExpired(taskId, 0);
    }

    // -------------------------------------------------------------------------
    // Bug-fix tests: resolveDispute auth, finalizeVerdict timing, appeal timing
    // -------------------------------------------------------------------------

    function test_ResolveDispute_Reverts_WrongCaller() public {
        address resolver = address(20);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), resolver))
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        _appeal(taskId, worker1);

        // worker1 is not the dispute resolver
        vm.prank(worker1);
        vm.expectRevert(ITMPCore.NotDisputeResolver.selector);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, awards);
    }

    function test_FinalizeVerdict_Reverts_BeforeAppealWindow() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing));

        // Appeal window is 1 day — calling immediately should revert.
        vm.expectRevert(ITMPCore.AppealWindowStillOpen.selector);
        market.finalizeVerdict(taskId);
    }

    function test_Appeal_Reverts_AfterWindowClosed() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);

        // Advance past appeal window
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ITMPCore.AppealWindowClosed.selector);
        _appeal(taskId, worker1);
    }

    function test_DoubleEvaluate_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing));

        // Second evaluate call must revert (task no longer in Review).
        vm.expectRevert();
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
    }

    // -------------------------------------------------------------------------
    // Hook coverage: checkComplete/onComplete via _payAwards paths
    // -------------------------------------------------------------------------

    function test_Hook_CheckAndOnComplete_CalledViaFinalizeVerdict() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.CLAIM(), address(hook));
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);

        vm.warp(block.timestamp + 1 days + 1);
        assertEq(hook.checkCompleteCalls(), 0);
        assertEq(hook.onCompleteCalls(), 0);
        market.finalizeVerdict(taskId);
        assertEq(hook.checkCompleteCalls(), 1);
        assertEq(hook.onCompleteCalls(), 1);
    }

    function test_Hook_CheckAndOnComplete_CalledViaResolveDispute() public {
        MockTaskHook hook = new MockTaskHook();
        address resolver = address(20);
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.CLAIM(),
                        0,
                        0,
                        bytes4(0),
                        ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), resolver))
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        _appeal(taskId, worker1);

        assertEq(hook.checkCompleteCalls(), 0);
        assertEq(hook.onCompleteCalls(), 0);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, awards);
        assertEq(hook.checkCompleteCalls(), 1);
        assertEq(hook.onCompleteCalls(), 1);
    }

    // -------------------------------------------------------------------------
    // CEI order verification: check* hook fires after state is committed
    // -------------------------------------------------------------------------

    function test_Hook_CheckComplete_SeesCommittedState() public {
        MockTaskHook hook = new MockTaskHook();
        hook.setTaskMarket(address(market));
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));

        _acceptSubmission(taskId, requester, worker1);

        // The hook must have observed task.status == Accepted when checkComplete fired,
        // proving state was committed before the hook call (CEI-compliant order).
        assertEq(hook.lastSeenStatusOnCheckComplete(), uint8(ITMPCore.TaskStatus.Accepted));
    }

    // -------------------------------------------------------------------------
    // Evaluator: BOUNTY REJECT reopens task; non-zero stake transfer
    // -------------------------------------------------------------------------

    function test_EvaluatorFlow_Reject_BountyMode_CancelsTask() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory noAwards = new ITMPCore.Award[](0);
        uint256 reqBefore = usdc.balanceOf(requester);
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.REJECT, 0, noAwards);

        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Cancelled));
        assertGt(usdc.balanceOf(requester), reqBefore);
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluator, address(0));
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluationWindow, 0);
        assertEq(market.getTaskEvaluatorConfig(taskId).appealWindow, 0);
    }

    function test_AssignEvaluator_NonZeroStake_TransfersFromRequester() public {
        uint256 stakeAmount = 10 * 10 ** 6;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);

        // Stake is pulled from the requester (not the evaluator parameter) to avoid
        // the arbitrary-from vulnerability: a malicious requester could otherwise drain
        // any address that has pre-approved this contract.
        usdc.mint(requester, stakeAmount);
        vm.prank(requester);
        usdc.approve(address(forwarder), stakeAmount);
        // The forwarder pulls payment from requester; the contract pulls stake from requester too.
        vm.prank(requester);
        usdc.approve(address(market), stakeAmount);

        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 contractBefore = usdc.balanceOf(address(market));

        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, stakeAmount, 0, uint32(2 days), uint32(1 days), address(0))
            )
        );

        assertEq(usdc.balanceOf(requester), reqBefore - stakeAmount);
        assertEq(usdc.balanceOf(address(market)), contractBefore + stakeAmount);
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, stakeAmount);
    }

    function test_EvaluatorFlow_NonZeroStake_ReturnedOnEvaluate() public {
        uint256 stakeAmount = 10 * 10 ** 6;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);

        // Stake is pulled from requester (not evaluator) — see test_AssignEvaluator_NonZeroStake_TransfersFromRequester.
        usdc.mint(requester, stakeAmount);
        vm.prank(requester);
        usdc.approve(address(market), stakeAmount);

        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, stakeAmount, 0, uint32(2 days), uint32(1 days), address(0))
            )
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });

        uint256 evalBefore = usdc.balanceOf(evaluator);
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        // Stake is returned to evaluator immediately on evaluate().
        assertEq(usdc.balanceOf(evaluator), evalBefore + stakeAmount);
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, 0);
    }

    // -------------------------------------------------------------------------
    // resolveDispute: direct call (not via forwarder)
    // -------------------------------------------------------------------------

    function test_ResolveDispute_DirectCall_FromDisputeResolver() public {
        address resolver = address(20);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), resolver))
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        _appeal(taskId, worker1);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Disputed));

        // resolveDispute accepts a direct call from task.disputeResolver without going via forwarder.
        uint256 before = usdc.balanceOf(worker1);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker1), before);
    }

    // -------------------------------------------------------------------------
    // evaluate: APPROVE verdict with empty awards
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // _payAwards: bounds, fee math, remainder, multi-award, adversarial
    // -------------------------------------------------------------------------

    function test_PayAwards_Reverts_WhenAwardsExceedEscrow() public {
        // Awards summing above (reward - evalFee) must revert before any transfer.
        // No evalFee assigned here so remaining = REWARD; REWARD+1 must revert.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD + 1, rank: 1 });

        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ITMPCore.AwardsExceedEscrow.selector);
        market.finalizeVerdict(taskId);
    }

    function test_PayAwards_Reverts_WhenAwardsExceedEscrow_ViaResolveDispute() public {
        // Same escrow bound applies through the resolveDispute path.
        address resolver = address(0xBEEF);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), resolver))
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD + 1, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);
        _appeal(taskId, worker1);

        vm.expectRevert(ITMPCore.AwardsExceedEscrow.selector);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.APPROVE, awards);
    }

    function test_PayAwards_Reverts_WhenAwardsExceedEscrowAfterEvalFee() public {
        // Escrow = reward - evalFee. Awards equal to the full reward must revert when evalFee > 0.
        uint16 evalFeeBps = 1000; // 10%
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, evalFeeBps, uint32(2 days), uint32(1 days));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });

        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ITMPCore.AwardsExceedEscrow.selector);
        market.finalizeVerdict(taskId);
    }

    function test_PayAwards_AwardsEqualRemaining_Succeeds() public {
        // Awards exactly equal to (reward - evalFee) must succeed — boundary check.
        uint16 evalFeeBps = 1000; // 10%
        uint256 evalFee = (REWARD * evalFeeBps) / 10000;
        uint256 remaining = REWARD - evalFee;

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, evalFeeBps, uint32(2 days), uint32(1 days));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: remaining, rank: 1 });

        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_PayAwards_FeeMath_PerAward() public {
        // Platform fee deducted per award; worker receives net, fee recipient receives fee.
        uint16 platformFeeBps = 500; // 5%
        vm.prank(market.owner());
        market.setDefaultFeeBps(platformFeeBps);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        uint256 workerBefore = usdc.balanceOf(worker1);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);

        uint256 expectedFee = (REWARD * platformFeeBps) / 10000;
        uint256 expectedNet = REWARD - expectedFee;
        assertEq(usdc.balanceOf(worker1), workerBefore + expectedNet);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + expectedFee);
    }

    function test_PayAwards_MultipleAwards_RemainderRefundedToRequester() public {
        // Partial awards: sum < remaining; workers receive net (after fee); unawarded portion refunds to requester.
        // Use zero platform fee for this test to isolate the remainder logic.
        vm.prank(market.owner());
        market.setDefaultFeeBps(0);

        uint256 award1 = REWARD / 3;
        uint256 award2 = REWARD / 4;

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: award1, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: worker2, amount: award2, rank: 2 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        uint256 w1Before = usdc.balanceOf(worker1);
        uint256 w2Before = usdc.balanceOf(worker2);
        uint256 reqBefore = usdc.balanceOf(requester);

        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);

        // With zero fee, workers receive gross amounts and requester gets unawarded remainder.
        assertEq(usdc.balanceOf(worker1), w1Before + award1);
        assertEq(usdc.balanceOf(worker2), w2Before + award2);
        assertEq(usdc.balanceOf(requester), reqBefore + (REWARD - award1 - award2));
    }

    function test_PayAwards_MultipleAwards_ExceedEscrow_Reverts() public {
        // Two awards that individually seem fine but together exceed escrow.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](2);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD / 2 + 1, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: worker2, amount: REWARD / 2 + 1, rank: 2 });

        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ITMPCore.AwardsExceedEscrow.selector);
        market.finalizeVerdict(taskId);
    }

    function test_PayAwards_ZeroAmountAwards_Skipped() public {
        // Zero-amount awards in the array do not cause reverts or bad state.
        // Use zero platform fee to keep balance math simple.
        vm.prank(market.owner());
        market.setDefaultFeeBps(0);

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](3);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD / 2, rank: 1 });
        awards[1] = ITMPCore.Award({ worker: worker2, amount: 0, rank: 2 }); // zero — skipped
        awards[2] = ITMPCore.Award({ worker: worker1, amount: REWARD / 4, rank: 3 });

        uint256 totalAwarded = REWARD / 2 + REWARD / 4;
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        uint256 w2Before = usdc.balanceOf(worker2);
        uint256 reqBefore = usdc.balanceOf(requester);
        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);

        // worker2 received nothing; requester gets unawarded remainder
        assertEq(usdc.balanceOf(worker2), w2Before);
        assertEq(usdc.balanceOf(requester), reqBefore + (REWARD - totalAwarded));
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    function test_Evaluate_ApproveWithEmptyAwards_FullRefundToRequester() public {
        // Evaluator issues APPROVE with no awards — all remaining escrow refunds to requester.
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory noAwards = new ITMPCore.Award[](0);
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, noAwards);

        vm.warp(block.timestamp + 1 days + 1);
        uint256 reqBefore = usdc.balanceOf(requester);
        market.finalizeVerdict(taskId);
        // All reward refunded to requester since awards array is empty.
        assertEq(usdc.balanceOf(requester), reqBefore + REWARD);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
    }

    // -------------------------------------------------------------------------
    // assignEvaluator: revert guards
    // -------------------------------------------------------------------------

    function test_RevertWhen_AssignEvaluator_NotRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        _relay(
            worker1,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(1 days), uint32(1 days), address(0))
            )
        );
    }

    function test_RevertWhen_AssignEvaluator_TaskNotOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(1 days), uint32(1 days), address(0))
            )
        );
    }

    function test_RevertWhen_AssignEvaluator_AlreadyAssigned() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        vm.expectRevert(ITMPCore.EvaluatorAlreadyAssigned.selector);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(1 days), uint32(1 days), address(0))
            )
        );
    }

    function test_RevertWhen_AssignEvaluator_ZeroEvaluatorAddress() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.InvalidEvaluator.selector);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, address(0), 0, 0, uint32(1 days), uint32(1 days), address(0))
            )
        );
    }

    function test_RevertWhen_AssignEvaluator_FeeBpsTooHigh() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.FeeBpsTooHigh.selector);
        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, 0, 10001, uint32(1 days), uint32(1 days), address(0))
            )
        );
    }

    // -------------------------------------------------------------------------
    // evaluatorTimeout: revert guards
    // -------------------------------------------------------------------------

    function test_RevertWhen_EvaluatorTimeout_NotRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert(ITMPCore.NotRequester.selector);
        _relay(worker1, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));
    }

    function test_RevertWhen_EvaluatorTimeout_NotInReview() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        vm.expectRevert(ITMPCore.NotInReviewState.selector);
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));
    }

    function test_RevertWhen_EvaluatorTimeout_WindowStillOpen() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindowSecs = uint32(2 days);
        _assignEvaluator(taskId, requester, evaluator, 0, evalWindowSecs, uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        vm.expectRevert(ITMPCore.EvaluationWindowNotExpired.selector);
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));
    }

    // -------------------------------------------------------------------------
    // resolveDispute: REJECT verdict must revert
    // -------------------------------------------------------------------------

    function test_RevertWhen_ResolveDispute_RejectVerdict() public {
        address resolver = address(20);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), resolver))
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        _appeal(taskId, worker1);

        vm.prank(resolver);
        vm.expectRevert(ITMPCore.DisputeResolutionMustAwardWorkers.selector);
        market.resolveDispute(taskId, ITMPCore.VerdictType.REJECT, awards);
    }

    // -------------------------------------------------------------------------
    // PARTIAL verdict: VerdictType.PARTIAL must follow the same _payAwards path
    // -------------------------------------------------------------------------

    function test_EvaluatorFlow_Partial_PayAwards() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        uint256 partialAmount = REWARD / 2;
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: partialAmount, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.PARTIAL, 500, awards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Appealing));

        uint256 workerBefore = usdc.balanceOf(worker1);
        uint256 reqBefore = usdc.balanceOf(requester);
        vm.warp(block.timestamp + 1 days + 1);
        market.finalizeVerdict(taskId);

        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker1), workerBefore);
        assertGt(usdc.balanceOf(requester), reqBefore);

        ITMPCore.Verdict memory v = market.getTaskVerdict(taskId);
        assertEq(uint8(v.verdictType), uint8(ITMPCore.VerdictType.PARTIAL));
    }

    function test_EvaluatorFlow_Partial_ResolveDispute() public {
        address resolver = address(20);
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(
            requester,
            0,
            abi.encodeCall(market.assignEvaluator, (taskId, evaluator, 0, 0, uint32(2 days), uint32(1 days), resolver))
        );
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 900, awards);
        _appeal(taskId, worker1);

        ITMPCore.Award[] memory partialAwards = new ITMPCore.Award[](1);
        partialAwards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD / 2, rank: 1 });

        uint256 workerBefore = usdc.balanceOf(worker1);
        vm.prank(resolver);
        market.resolveDispute(taskId, ITMPCore.VerdictType.PARTIAL, partialAwards);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker1), workerBefore);
    }

    // -------------------------------------------------------------------------
    // submitBid / selectLowestBidder: revert guards
    // -------------------------------------------------------------------------

    function test_RevertWhen_SubmitBid_NotAuction() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.NotAnAuctionTask.selector);
        _submitBid(taskId, worker1, REWARD / 2);
    }

    function test_RevertWhen_SubmitBid_AfterBidDeadline() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ITMPCore.BidDeadlinePassed.selector);
        _submitBid(taskId, worker1, REWARD / 2);
    }

    function test_RevertWhen_SubmitBid_PriceExceedsMax() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        vm.expectRevert(ITMPCore.BidExceedsMaxPrice.selector);
        _submitBid(taskId, worker1, REWARD + 1);
    }

    function test_RevertWhen_SelectLowestBidder_NoBids() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ITMPCore.NoBidsSubmitted.selector);
        _selectLowestBidder(taskId);
    }

    function test_RevertWhen_SelectLowestBidder_BeforeDeadline() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_ENGLISH());
        _submitBid(taskId, worker1, REWARD / 2);
        vm.expectRevert(ITMPCore.BidDeadlineNotPassed.selector);
        _selectLowestBidder(taskId);
    }

    // -------------------------------------------------------------------------
    // Pause circuit breaker
    // -------------------------------------------------------------------------

    function test_Pause_OnlyOwner() public {
        vm.prank(requester);
        vm.expectRevert();
        market.pause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(owner);
        market.pause();
        vm.prank(requester);
        vm.expectRevert();
        market.unpause();
    }

    function test_WhenPaused_CreateTask_Reverts() public {
        bytes4 bountyMode = market.BOUNTY();
        vm.prank(owner);
        market.pause();
        assertTrue(market.paused());
        bytes32[] memory emptyTags = new bytes32[](0);
        // Use _relay directly to avoid abi.decode on empty return after vm.expectRevert swallows the revert.
        vm.expectRevert();
        _relay(
            requester,
            REWARD,
            abi.encodeCall(
                market.createTask,
                (
                    REWARD,
                    DURATION,
                    bountyMode,
                    0,
                    0,
                    bytes4(0),
                    ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                )
            )
        );
    }

    function test_WhenPaused_ClaimTask_Reverts() public {
        bytes4 claimMode = market.CLAIM();
        bytes32 taskId = _createTask(requester, REWARD, DURATION, claimMode, 0, 0);
        vm.prank(owner);
        market.pause();
        vm.expectRevert();
        _claimTask(taskId, worker1, 0);
    }

    function test_WhenPaused_RefundExpired_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(owner);
        market.pause();
        vm.expectRevert();
        market.refundExpired(taskId, 0);
    }

    function test_WhenUnpaused_CreateTask_Succeeds() public {
        vm.startPrank(owner);
        market.pause();
        market.unpause();
        vm.stopPrank();
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(uint8(market.getTaskState(taskId)), uint8(ITMPCore.TaskStatus.Open));
    }

    // -------------------------------------------------------------------------
    // Ownable2Step
    // -------------------------------------------------------------------------

    function test_Ownable2Step_RequiresAccept() public {
        address newOwner = address(0x9999);
        vm.prank(owner);
        market.transferOwnership(newOwner);
        assertEq(market.pendingOwner(), newOwner);
        assertEq(market.owner(), owner);
        vm.prank(newOwner);
        market.acceptOwnership();
        assertEq(market.owner(), newOwner);
    }

    // -------------------------------------------------------------------------
    // Bid limit (MAX_BIDS_PER_TASK)
    // -------------------------------------------------------------------------

    function test_RevertWhen_SubmitBid_LimitReached() public {
        bytes32 taskId =
            _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 14 days, market.AUCTION_ENGLISH());
        uint256 limit = market.MAX_BIDS_PER_TASK();
        // AppStorage is at keccak256("taskmarket.appstorage.v1"). taskBids is at offset 5 within
        // the struct. For mapping(bytes32 => Bid[]) at slot p, the array length for key k is at
        // keccak256(abi.encode(k, p)). Writing the limit directly avoids 500 gas-heavy bids.
        uint256 taskBidsSlot = uint256(keccak256("taskmarket.appstorage.v1")) + 5;
        bytes32 arrayLengthSlot = keccak256(abi.encode(taskId, taskBidsSlot));
        vm.store(address(market), arrayLengthSlot, bytes32(limit));
        vm.expectRevert(ITMPCore.BidLimitReached.selector);
        _submitBid(taskId, worker1, REWARD / 2);
    }

    // -------------------------------------------------------------------------
    // RegistryFacet view coverage: taskMode, totalFeesCollected, getTaskMetadata
    // -------------------------------------------------------------------------

    function test_TaskMode_ReturnsBountyMode() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        assertEq(market.taskMode(taskId), market.BOUNTY());
    }

    function test_TaskMode_ReturnsClaimMode() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        assertEq(market.taskMode(taskId), market.CLAIM());
    }

    function test_TotalFeesCollected_ZeroInitially() public view {
        assertEq(market.totalFeesCollected(), 0);
    }

    function test_TotalFeesCollected_IncreasesAfterAccept() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        uint256 before = market.totalFeesCollected();
        _acceptSubmission(taskId, requester, worker1);
        assertGt(market.totalFeesCollected(), before);
    }

    function test_GetTaskMetadata_CreatedAt() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        ITMPCore.TaskMetadata memory meta = market.getTaskMetadata(taskId);
        assertEq(meta.createdAt, block.timestamp);
    }

    function test_GetTaskMetadata_ContentHashAndURI() public {
        bytes32 contentHash = keccak256("some-content");
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.BOUNTY(),
                        0,
                        0,
                        bytes4(0),
                        ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: contentHash, contentURI: "ipfs://xyz", tags: emptyTags })
                    )
                )
            ),
            (bytes32)
        );
        ITMPCore.TaskMetadata memory meta = market.getTaskMetadata(taskId);
        assertEq(meta.contentHash, contentHash);
        assertEq(meta.contentURI, "ipfs://xyz");
    }

    // -------------------------------------------------------------------------
    // RatingFacet coverage: _modeName branches via reputationRegistry
    // -------------------------------------------------------------------------

    function test_RateTask_WithRegistry_BountyModeName() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, worker1, 80, 1, 0, "", bytes32(0));
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.bounty");
    }

    function test_RateTask_WithRegistry_ClaimModeName() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _claimTask(taskId, worker1, 0);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, worker1, 80, 1, 0, "", bytes32(0));
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.claim");
    }

    function test_RateTask_WithRegistry_PitchModeName() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        _selectWorker(taskId, requester, worker1);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, worker1, 70, 1, 0, "", bytes32(0));
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.pitch");
    }

    function test_RateTask_WithRegistry_BenchmarkModeName() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, worker1, 90, 1, 0, "", bytes32(0));
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.benchmark");
    }

    function test_RateTask_WithRegistry_AuctionModeName() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        _acceptAuction(taskId, worker1, REWARD / 2);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, worker1, 85, 1, 0, "", bytes32(0));
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.auction");
    }

    function test_RateTask_NoRegistry_SkipsExternalCall() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        _rateTask(taskId, requester, worker1, 80, 1, 0, "", bytes32(0));
        assertEq(market.getWorkerStats(worker1).ratedTasks, 1);
    }

    // -------------------------------------------------------------------------
    // AcceptanceFacet: validate-branch reverts and hook paths
    // -------------------------------------------------------------------------

    function test_AcceptSubmission_Claim_NotClaimed_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        vm.expectRevert(ITMPCore.TaskNotClaimed.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, bytes32(0), 0))
        );
    }

    function test_AcceptSubmission_Pitch_WorkerNotSelected_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.expectRevert(ITMPCore.WorkerNotSelected.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, bytes32(0), 0))
        );
    }

    function test_AcceptSubmission_Auction_WinnerNotSelected_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());
        vm.expectRevert(ITMPCore.WinnerNotSelected.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, bytes32(0), 0))
        );
    }

    function test_AcceptSubmission_Bounty_AlreadyAccepted_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker2, keccak256("work2"), 0))
        );
    }

    function test_AcceptSubmissions_AlreadyAccepted_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;
        bytes32[] memory deliverables = new bytes32[](1);
        deliverables[0] = keccak256("A");
        _acceptSubmissions(taskId, requester, workers, shares, deliverables);

        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmission_Hook_CheckComplete_Rejected_Reverts() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
        _submitWork(taskId, worker1, keccak256("work"));
        hook.setRejectOnCheckComplete(true);
        vm.expectRevert(ITMPCore.HookCheckCompleteRejected.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker1, keccak256("work"), 0))
        );
    }

    // -------------------------------------------------------------------------
    // CoreFacet: hook-reject paths and submitWork status guards
    // -------------------------------------------------------------------------

    function test_HookCheckSelectWorker_RejectFalse_BlocksSelectWorker() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.PITCH(), address(hook));
        hook.setRejectOnCheckSelectWorker(true);
        vm.expectRevert(ITMPCore.HookCheckSelectWorkerRejected.selector);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
    }

    function test_HookCheckSubmit_RejectFalse_BlocksSubmit() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
        hook.setRejectOnCheckSubmit(true);
        vm.expectRevert(ITMPCore.HookCheckSubmitRejected.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function test_SubmitWork_Bounty_WhenAccepted_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _acceptSubmission(taskId, requester, worker1);
        vm.expectRevert(ITMPCore.TaskNotOpen.selector);
        forwarder.relay(address(market), worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    function test_SubmitWork_Pitch_WhenOpen_WorkerNotSelected_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), 2 days, 0);
        vm.expectRevert(ITMPCore.WorkerNotSelected.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
    }

    // -------------------------------------------------------------------------
    // EvaluatorFacet: evaluatorTimeout with stake forfeit, hook reject paths
    // -------------------------------------------------------------------------

    function test_EvaluatorTimeout_WithStake_ForfeitsStake() public {
        uint256 stakeAmount = 50 * 10 ** 6;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        uint32 evalWindow = uint32(2 days);

        usdc.mint(requester, stakeAmount);
        vm.prank(requester);
        usdc.approve(address(market), stakeAmount);

        _relay(
            requester,
            0,
            abi.encodeCall(
                market.assignEvaluator, (taskId, evaluator, stakeAmount, 0, evalWindow, uint32(1 days), address(0))
            )
        );

        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        vm.warp(block.timestamp + evalWindow + 1 seconds);

        uint256 feeBefore = market.totalFeesCollected();
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        _relay(requester, 0, abi.encodeCall(market.evaluatorTimeout, (taskId)));
        assertGt(market.totalFeesCollected(), feeBefore);
        assertGt(usdc.balanceOf(feeRecipient), feeRecipientBefore);
    }

    function test_HookCheckEvaluate_RejectFalse_BlocksEvaluate() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.CLAIM(), address(hook));
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        hook.setRejectOnCheckEvaluate(true);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        vm.expectRevert(ITMPCore.HookCheckEvaluateRejected.selector);
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);
    }

    // -------------------------------------------------------------------------
    // EvaluatorFacet: hook reject path in _payAwards (finalizeVerdict)
    // -------------------------------------------------------------------------

    function test_FinalizeVerdict_Hook_CheckComplete_RejectFalse_Reverts() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.CLAIM(), address(hook));
        _assignEvaluator(taskId, requester, evaluator, 0, uint32(2 days), uint32(1 days));
        _claimTask(taskId, worker1, 0);
        _submitWork(taskId, worker1, keccak256("work"));

        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker1, amount: REWARD, rank: 1 });
        _evaluate(taskId, evaluator, ITMPCore.VerdictType.APPROVE, 1000, awards);

        vm.warp(block.timestamp + 2 days + 1 seconds);

        hook.setRejectOnCheckComplete(true);
        vm.expectRevert(ITMPCore.HookCheckCompleteRejected.selector);
        market.finalizeVerdict(taskId);
    }

    // -------------------------------------------------------------------------
    // AuctionFacet: hook reject path for acceptAuction
    // -------------------------------------------------------------------------

    function test_AcceptAuction_Hook_CheckSelectWorker_RejectFalse_Reverts() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32[] memory emptyTags = new bytes32[](0);
        bytes32 taskId = abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        REWARD,
                        DURATION,
                        market.AUCTION(),
                        0,
                        1 days,
                        market.AUCTION_DUTCH(),
                        ITMPCore.HookConfig({ contracts: _hookArr(address(hook)), data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) })
                    )
                )
            ),
            (bytes32)
        );
        hook.setRejectOnCheckSelectWorker(true);
        vm.expectRevert(ITMPCore.HookCheckSelectWorkerRejected.selector);
        _acceptAuction(taskId, worker1, REWARD / 2);
    }

    // -------------------------------------------------------------------------
    // MockTaskHook setter coverage: setRejectOnCheckClaim, setRevertOnCheckComplete,
    // supportsInterface
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // MockERC20 and MockPGTRForwarder helper method coverage
    // -------------------------------------------------------------------------

    function test_MockERC20_Decimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_MockUSDC_Decimals() public {
        MockUSDC mockUsdc = new MockUSDC();
        assertEq(mockUsdc.decimals(), 6);
    }

    function test_MockPGTRForwarder_IsPGTRForwarder() public view {
        assertTrue(forwarder.isPGTRForwarder());
    }

    function test_MockPGTRForwarder_IsTrustedForwarder_Self() public view {
        assertTrue(forwarder.isTrustedForwarder(address(forwarder)));
    }

    function test_MockPGTRForwarder_IsTrustedForwarder_Other_False() public view {
        assertFalse(forwarder.isTrustedForwarder(address(0x1234)));
    }

    function test_MockPGTRForwarder_SupportsInterface_IPGTRForwarder() public view {
        assertTrue(forwarder.supportsInterface(type(IPGTRForwarder).interfaceId));
    }

    function test_MockPGTRForwarder_SupportsInterface_IERC165() public view {
        assertTrue(forwarder.supportsInterface(type(IERC165).interfaceId));
    }

    function test_MockPGTRForwarder_SupportsInterface_Unknown_False() public view {
        assertFalse(forwarder.supportsInterface(bytes4(0xdeadbeef)));
    }

    function test_MockHook_SetRejectOnCheckClaim_BlocksClaim() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.CLAIM(), address(hook));
        hook.setRejectOnCheckClaim(true);
        vm.expectRevert(ITMPCore.HookCheckClaimRejected.selector);
        forwarder.relay(address(market), worker1, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
    }

    function test_MockHook_SetRevertOnCheckComplete_BlocksAccept() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
        hook.setRevertOnCheckComplete(true);
        vm.expectRevert();
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker1, keccak256("work"), 0))
        );
    }

    function test_MockHook_SupportsInterface() public {
        MockTaskHook hook = new MockTaskHook();
        assertTrue(hook.supportsInterface(type(ITMPHook).interfaceId));
        assertFalse(hook.supportsInterface(bytes4(0xdeadbeef)));
    }

    // -----------------------------------------------------------------------
    // Submission integrity — TDD tests (written before implementation)
    // -----------------------------------------------------------------------

    // --- SubmissionNotFound / hash verification ---

    function test_AcceptSubmission_Bounty_WithoutSubmit_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.expectRevert(ITMPCore.SubmissionNotFound.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker1, keccak256("work"), 0))
        );
    }

    function test_AcceptSubmission_Benchmark_WithoutSubmit_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        vm.expectRevert(ITMPCore.SubmissionNotFound.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmission, (taskId, worker1, keccak256("proof"), 0))
        );
    }

    function test_AcceptSubmission_Bounty_WrongDeliverable_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hashA = keccak256("hashA");
        bytes32 hashB = keccak256("hashB");
        _submitWork(taskId, worker1, hashA);
        vm.expectRevert(ITMPCore.SubmissionNotFound.selector);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hashB, 0))
        );
    }

    function test_AcceptSubmission_Bounty_CorrectDeliverable_Succeeds() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hash = keccak256("myWork");
        _submitWork(taskId, worker1, hash);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hash, 0))
        );
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_AcceptSubmission_Bounty_OlderVersionStillAcceptable() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hashV1 = keccak256("v1");
        bytes32 hashV2 = keccak256("v2");
        _submitWork(taskId, worker1, hashV1);
        _submitWork(taskId, worker1, hashV2);
        // accept the older v1, not the latest v2
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hashV1, 0))
        );
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
        assertEq(market.getTask(taskId).deliverable, hashV1);
    }

    function test_AcceptSubmissions_MultiWinner_NoSubmit_Reverts() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        // worker1 submitted but worker2 did not
        _submitWork(taskId, worker1, keccak256("w1work"));
        vm.expectRevert(ITMPCore.SubmissionNotFound.selector);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    function test_AcceptSubmissions_MultiWinner_AllCorrect_Succeeds() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("w1work"));
        _submitWork(taskId, worker2, keccak256("w2work"));
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    // --- SelfAward event ---

    function test_SelfAward_EmitsWhenWorkerIsRequester() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hash = keccak256("selfWork");
        _submitWork(taskId, requester, hash);
        vm.expectEmit(true, true, true, false);
        emit ITMPCore.SelfAward(taskId, requester, requester);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, requester, hash, 0))
        );
    }

    function test_SelfAward_NotEmittedWhenWorkerDiffers() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hash = keccak256("w1work");
        _submitWork(taskId, worker1, hash);
        vm.recordLogs();
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hash, 0))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 selfAwardTopic = keccak256("SelfAward(bytes32,address,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], selfAwardTopic, "SelfAward should not be emitted");
        }
    }

    function test_SelfAward_MultiWinner_EmitsPerSelfAwardWinner() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, requester, keccak256("selfWork"));
        _submitWork(taskId, worker1, keccak256("w1work"));
        address[] memory workers = new address[](2);
        workers[0] = requester;
        workers[1] = worker1;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 5000;
        shares[1] = 5000;
        vm.expectEmit(true, true, true, false);
        emit ITMPCore.SelfAward(taskId, requester, requester);
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
    }

    // --- RequesterReputation event ---

    function test_RequesterReputation_OnComplete_Emitted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hash = keccak256("work");
        _submitWork(taskId, worker1, hash);
        vm.expectEmit(true, true, false, false);
        emit ITMPCore.RequesterReputation(taskId, requester, keccak256("completed"), REWARD, 1, false);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hash, 0))
        );
    }

    function test_RequesterReputation_OnComplete_SelfAwardFlag() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hash = keccak256("selfWork");
        _submitWork(taskId, requester, hash);
        vm.expectEmit(true, true, false, false);
        emit ITMPCore.RequesterReputation(taskId, requester, keccak256("completed"), REWARD, 1, true);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, requester, hash, 0))
        );
    }

    function test_RequesterReputation_CancelAfterRejections_Emitted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        _rejectSubmission(taskId, requester, worker1);
        vm.expectEmit(true, true, false, false);
        emit ITMPCore.RequesterReputation(taskId, requester, keccak256("cancelled_after_submissions"), REWARD, 0, false);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
    }

    function test_RequesterReputation_CleanCancel_NotEmitted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.recordLogs();
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 repTopic = keccak256("RequesterReputation(bytes32,address,bytes32,uint256,uint32,bool)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], repTopic, "RequesterReputation should not be emitted on clean cancel");
        }
    }

    function test_RequesterReputation_ExpiredNoAction_Emitted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);
        vm.expectEmit(true, true, false, false);
        emit ITMPCore.RequesterReputation(taskId, requester, keccak256("expired_no_action"), REWARD, 0, false);
        market.refundExpired(taskId, 0);
    }

    function test_RequesterReputation_ExpiredAfterRejections_Emitted() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        _rejectSubmission(taskId, requester, worker1);
        vm.warp(block.timestamp + DURATION + 1);
        vm.expectEmit(true, true, false, false);
        emit ITMPCore.RequesterReputation(taskId, requester, keccak256("expired_after_rejections"), REWARD, 0, false);
        market.refundExpired(taskId, 0);
    }

    // --- requesterAgentId passthrough ---

    function test_AcceptSubmission_ZeroAgentId_NoRegistryCall() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hash = keccak256("work");
        _submitWork(taskId, worker1, hash);
        // requesterAgentId = 0 — no registry call, must not revert
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hash, 0))
        );
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_CancelTask_WithAgentId_NoRevert() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        // requesterAgentId = 42, no registry configured — must not revert
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 42)));
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Cancelled));
    }

    // --- AcceptanceFacet: requesterAgentId registry path and _modeName branches ---

    function test_AcceptSubmission_WithRegistry_BountyMode() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 hash = keccak256("work");
        _submitWork(taskId, worker1, hash);
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hash, 42))
        );
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.bounty");
    }

    function test_AcceptSubmission_WithRegistry_BenchmarkMode() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        bytes32 hash = keccak256("work");
        _submitWork(taskId, worker1, hash);
        // _modeName(BENCHMARK): traverses BOUNTY=false, CLAIM=false, PITCH=false, BENCHMARK=true
        forwarder.relay(
            address(market), requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, hash, 42))
        );
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.benchmark");
    }

    function test_AcceptSubmissions_WithRegistry() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("w1"));
        _submitWork(taskId, worker2, keccak256("w2"));
        address[] memory workers = new address[](2);
        workers[0] = worker1;
        workers[1] = worker2;
        uint16[] memory shares = new uint16[](2);
        shares[0] = 6000;
        shares[1] = 4000;
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 42))
        );
        assertEq(reg.calls(), 1);
    }

    function test_AcceptSubmissions_WithHook_CheckComplete() public {
        MockTaskHook hook = new MockTaskHook();
        bytes32 taskId = _createTaskWithHook(requester, REWARD, DURATION, market.BOUNTY(), address(hook));
        _submitWork(taskId, worker1, keccak256("work"));
        address[] memory workers = new address[](1);
        workers[0] = worker1;
        uint16[] memory shares = new uint16[](1);
        shares[0] = 10000;
        forwarder.relay(
            address(market),
            requester,
            0,
            abi.encodeCall(market.acceptSubmissions, (taskId, workers, shares, new bytes32[](0), 0))
        );
        assertGt(hook.checkCompleteCalls(), 0);
        assertGt(hook.onCompleteCalls(), 0);
    }

    // --- CoreFacet: cancelTask with registry after rejections (_modeName branches) ---

    function test_CancelTask_WithRegistry_Bounty_AfterRejections() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        _rejectSubmission(taskId, requester, worker1);
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 42)));
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.bounty");
    }

    function test_CancelTask_WithRegistry_Benchmark_AfterRejections() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);
        _submitWork(taskId, worker1, keccak256("work"));
        _rejectSubmission(taskId, requester, worker1);
        // _modeName(BENCHMARK) in CoreFacet: BOUNTY=false, CLAIM=false, PITCH=false, BENCHMARK=true
        forwarder.relay(address(market), requester, 0, abi.encodeCall(market.cancelTask, (taskId, 42)));
        assertEq(reg.calls(), 1);
        assertEq(reg.lastTag2(), "tmp.mode.benchmark");
    }

    // --- CoreFacet: refundExpired with registry ---

    function test_RefundExpired_WithRegistry_Bounty() public {
        MockReputationRegistry reg = new MockReputationRegistry();
        vm.prank(owner);
        market.setReputationRegistry(address(reg));

        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);
        market.refundExpired(taskId, 42);
        assertEq(reg.calls(), 1);
    }
}
