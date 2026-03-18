// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../src/TaskMarket.sol";
import "../src/interfaces/ITMP.sol";
import "../src/interfaces/IPGTRForwarder.sol";
import "../src/interfaces/ITMPMode.sol";
import "./mocks/MockUSDC.sol";

/// @dev Minimal PGTR forwarder for compliance tests.
contract ComplianceMockForwarder is IPGTRForwarder {
    IERC20 public usdc;
    address private _pgtrSenderValue;

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    function isPGTRForwarder() external pure override returns (bool) { return true; }

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

/**
 * @title ITMPCompliance
 * @notice Compliance test suite for the Task Market Protocol (ERC-8195).
 *         Any contract claiming ITMP compliance can be pointed at these tests.
 *
 *         Verifies:
 *         1. ERC-165: supportsInterface returns correct values
 *         2. Mode constants are canonical bytes4 values
 *         3. Bounty mode state machine
 *         4. Claim mode state machine (stake + forfeit + refund)
 *         5. Pitch mode state machine
 *         6. Benchmark mode state machine
 *         7. Auction mode state machine (selectLowestBidder + acceptAuction)
 *         8. submitWork across all modes
 *         9. rateTask with correct ERC-8004 tags
 *        10. refundExpired bypasses all state (fund safety)
 *        11. requesterNonce increments and produces unique IDs
 *        12. Multi-forwarder: add and remove forwarders
 */
contract ITMPCompliance is Test {
    TaskMarket public market;
    MockUSDC public usdc;
    ComplianceMockForwarder public fwd;

    address public owner    = address(0x0001);
    address public treasury = address(0x0002);
    address public requester = address(0x0003);
    address public worker1   = address(0x0004);
    address public worker2   = address(0x0005);

    uint256 constant REWARD   = 100e6;  // 100 USDC
    uint256 constant DURATION = 7 days;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();

        TaskMarket impl = new TaskMarket();
        bytes memory initData = abi.encodeCall(TaskMarket.initialize, (address(usdc), treasury, 500));
        market = TaskMarket(address(new ERC1967Proxy(address(impl), initData)));

        fwd = new ComplianceMockForwarder(address(usdc));
        market.addForwarder(address(fwd));
        vm.stopPrank();

        usdc.mint(address(fwd), 1_000_000e6);
    }

    // -------------------------------------------------------------------------
    // Relay helpers
    // -------------------------------------------------------------------------

    function _relay(address pgtrSenderAddr, uint256 paymentAmount, bytes memory data) internal returns (bytes memory) {
        return fwd.relay(address(market), pgtrSenderAddr, paymentAmount, data);
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

    // -------------------------------------------------------------------------
    // 1. ERC-165 compliance
    // -------------------------------------------------------------------------

    function test_Compliance_ERC165_ITMP() public view {
        assertTrue(
            market.supportsInterface(type(ITMP).interfaceId),
            "Must support ITMP interface"
        );
    }

    function test_Compliance_ERC165_Self() public view {
        assertTrue(
            market.supportsInterface(type(IERC165).interfaceId),
            "Must support IERC165"
        );
    }

    function test_Compliance_ERC165_RandomBytes_False() public view {
        assertFalse(
            market.supportsInterface(bytes4(0xdeadbeef)),
            "Must return false for unknown interface"
        );
    }

    function test_Compliance_ERC165_AllFFs_False() public view {
        assertFalse(
            market.supportsInterface(0xffffffff),
            "Must return false for 0xffffffff"
        );
    }

    // -------------------------------------------------------------------------
    // 2. Mode constants — canonical bytes4 values
    // -------------------------------------------------------------------------

    function test_Compliance_ModeConstants_Canonical() public view {
        assertEq(market.BOUNTY(),    bytes4(keccak256("TMP.mode.bounty")),    "BOUNTY mismatch");
        assertEq(market.CLAIM(),     bytes4(keccak256("TMP.mode.claim")),     "CLAIM mismatch");
        assertEq(market.PITCH(),     bytes4(keccak256("TMP.mode.pitch")),     "PITCH mismatch");
        assertEq(market.BENCHMARK(), bytes4(keccak256("TMP.mode.benchmark")), "BENCHMARK mismatch");
        assertEq(market.AUCTION(),   bytes4(keccak256("TMP.mode.auction")),   "AUCTION mismatch");
    }

    function test_Compliance_ModeConstants_FileLevel() public pure {
        assertEq(TMP_BOUNTY,    bytes4(keccak256("TMP.mode.bounty")));
        assertEq(TMP_CLAIM,     bytes4(keccak256("TMP.mode.claim")));
        assertEq(TMP_PITCH,     bytes4(keccak256("TMP.mode.pitch")));
        assertEq(TMP_BENCHMARK, bytes4(keccak256("TMP.mode.benchmark")));
        assertEq(TMP_AUCTION,   bytes4(keccak256("TMP.mode.auction")));
    }

    function test_Compliance_ModeConstants_AllDistinct() public view {
        bytes4[5] memory modes = [
            market.BOUNTY(), market.CLAIM(), market.PITCH(), market.BENCHMARK(), market.AUCTION()
        ];
        for (uint i = 0; i < 5; i++) {
            for (uint j = i + 1; j < 5; j++) {
                assertTrue(modes[i] != modes[j], "Mode selectors must be distinct");
            }
        }
    }

    // -------------------------------------------------------------------------
    // 3. Bounty mode state machine
    // -------------------------------------------------------------------------

    function test_Compliance_Bounty_FullCycle() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Open), "Bounty: must start Open");
        assertEq(task.mode, market.BOUNTY());

        // submitWork -> PendingApproval
        _relay(worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("deliverable"))));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.PendingApproval), "Bounty: submitWork must set PendingApproval");

        // acceptSubmission -> Accepted
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted), "Bounty: acceptSubmission must set Accepted");
        assertEq(task.worker, worker1);
    }

    function test_Compliance_Bounty_Expire() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);
        market.refundExpired(taskId);

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Expired), "Must be Expired after refundExpired");
    }

    // -------------------------------------------------------------------------
    // 4. Claim mode state machine
    // -------------------------------------------------------------------------

    function test_Compliance_Claim_FullCycle() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);

        // claim -> Claimed
        _relay(worker1, 0, abi.encodeCall(market.claimTask, (taskId, 0)));
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));
        assertEq(task.claimer, worker1);

        // submitWork -> Claimed (no state change)
        _relay(worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("work"))));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed), "Claim: submitWork must not change state");

        // acceptSubmission -> Accepted
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    function test_Compliance_Claim_Forfeit_Reopen() public {
        uint256 stake = REWARD / 10;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(worker1, stake, abi.encodeCall(market.claimTask, (taskId, stake)));

        vm.warp(block.timestamp + DURATION + 1);

        _relay(requester, 0, abi.encodeCall(market.forfeitAndReopen, (taskId)));

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Open), "Must reopen to Open after forfeit");
        assertEq(task.claimer, address(0));
        assertEq(task.stakeAmount, 0);
    }

    // -------------------------------------------------------------------------
    // 5. Pitch mode state machine
    // -------------------------------------------------------------------------

    function test_Compliance_Pitch_FullCycle() public {
        uint256 pitchWindow = 2 days;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.PITCH(), pitchWindow, 0);

        // selectWorker -> WorkerSelected
        _relay(requester, 0, abi.encodeCall(market.selectWorker, (taskId, worker1)));
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.WorkerSelected));
        assertEq(task.worker, worker1);

        // submitWork -> WorkerSelected (no state change)
        _relay(worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("pitch work"))));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.WorkerSelected), "Pitch: submitWork must not change state");

        // acceptSubmission -> Accepted
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    // -------------------------------------------------------------------------
    // 6. Benchmark mode state machine
    // -------------------------------------------------------------------------

    function test_Compliance_Benchmark_FullCycle() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BENCHMARK(), 0, 0);

        // submitWork -> PendingApproval (same as Bounty)
        _relay(worker1, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("benchmark result"))));
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.PendingApproval));

        // acceptSubmission -> Accepted
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    // -------------------------------------------------------------------------
    // 7. Auction mode state machine
    // -------------------------------------------------------------------------

    function test_Compliance_Auction_SelectLowestBidder() public {
        uint256 bidWindow = 1 days;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, bidWindow, market.AUCTION_ENGLISH());

        // Submit bids
        _relay(worker1, 0, abi.encodeCall(market.submitBid, (taskId, 80e6)));
        _relay(worker2, 0, abi.encodeCall(market.submitBid, (taskId, 60e6)));

        // Advance past bid deadline
        vm.warp(block.timestamp + bidWindow + 1);

        // selectLowestBidder -> Claimed
        _relay(address(0), 0, abi.encodeCall(market.selectLowestBidder, (taskId)));
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));
        assertEq(task.worker, worker2, "Lower bidder must win");
        assertEq(task.stakeAmount, 60e6, "Stake must equal winning bid");

        // submitWork -> Claimed (no state change)
        _relay(worker2, 0, abi.encodeCall(market.submitWork, (taskId, keccak256("auction work"))));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));

        // acceptSubmission -> Accepted
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker2)));
        task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Accepted));
    }

    function test_Compliance_Auction_AcceptAuction_ShortCircuit() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.AUCTION(), 0, 1 days, market.AUCTION_DUTCH());

        // acceptAuction directly selects winner
        _relay(worker1, 0, abi.encodeCall(market.acceptAuction, (taskId, 50e6)));
        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Claimed));
        assertEq(task.worker, worker1);
        assertEq(task.stakeAmount, 50e6);
    }

    // -------------------------------------------------------------------------
    // 8. submitWork — deliverable hash stored correctly
    // -------------------------------------------------------------------------

    function test_Compliance_SubmitWork_DeliverableStored() public {
        bytes32 deliverable = keccak256("ipfs://QmDeliverable");
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        vm.expectEmit(true, true, false, true);
        emit ITMP.TaskSubmitted(taskId, worker1, deliverable);

        _relay(worker1, 0, abi.encodeCall(market.submitWork, (taskId, deliverable)));

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(task.deliverable, deliverable, "Deliverable hash must be stored on-chain");
    }

    // -------------------------------------------------------------------------
    // 9. rateTask — ERC-8004 tag standardization
    // -------------------------------------------------------------------------

    function test_Compliance_RateTask_Range() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));

        ITMP.WorkerStats memory before = market.getWorkerStats(worker1);

        // rating=0 is the sentinel value for "unrated" but is still a valid call;
        // ratedTasks increments and totalStars increases by 0.
        _relay(requester, 0, abi.encodeCall(market.rateTask, (taskId, 0, 0, 0, "", bytes32(0))));

        ITMP.WorkerStats memory after_ = market.getWorkerStats(worker1);
        assertEq(after_.ratedTasks,  before.ratedTasks + 1, "ratedTasks must increment");
        assertEq(after_.totalStars,  before.totalStars,     "totalStars must not change for rating=0");
    }

    function test_Compliance_RateTask_WorkerStatsUpdated() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1)));
        _relay(requester, 0, abi.encodeCall(market.rateTask, (taskId, 80, 0, 0, "", bytes32(0))));

        ITMP.WorkerStats memory ws = market.getWorkerStats(worker1);
        assertEq(ws.ratedTasks, 1);
        assertEq(ws.totalStars, 80);
    }

    // -------------------------------------------------------------------------
    // 10. Fund safety — refundExpired always works
    // -------------------------------------------------------------------------

    function test_Compliance_FundSafety_RefundAlwaysWorks_Bounty() public {
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        vm.warp(block.timestamp + DURATION + 1);

        uint256 before = usdc.balanceOf(requester);
        market.refundExpired(taskId);
        assertEq(usdc.balanceOf(requester), before + REWARD, "Requester must recover funds after expiry");
    }

    function test_Compliance_FundSafety_RefundAlwaysWorks_Claim_WithStake() public {
        uint256 stake = REWARD / 5;
        bytes32 taskId = _createTask(requester, REWARD, DURATION, market.CLAIM(), 0, 0);
        _relay(worker1, stake, abi.encodeCall(market.claimTask, (taskId, stake)));

        vm.warp(block.timestamp + DURATION + 1);

        uint256 requesterBefore = usdc.balanceOf(requester);
        uint256 worker1Before   = usdc.balanceOf(worker1);

        market.refundExpired(taskId);

        assertEq(usdc.balanceOf(requester), requesterBefore + REWARD, "Requester recovers reward");
        assertEq(usdc.balanceOf(worker1),   worker1Before + stake,    "Claimer recovers stake");
    }

    // -------------------------------------------------------------------------
    // 11. requesterNonce — unique IDs, monotonic nonce
    // -------------------------------------------------------------------------

    function test_Compliance_RequesterNonce_UniqueIds() public {
        bytes32 id1 = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 id2 = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);
        bytes32 id3 = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        assertTrue(id1 != id2, "IDs must be unique");
        assertTrue(id2 != id3, "IDs must be unique");
        assertTrue(id1 != id3, "IDs must be unique");
        assertEq(market.requesterNonce(requester), 3, "Nonce must increment");
    }

    function test_Compliance_RequesterNonce_PrecomputableId() public {
        uint256 nonceBefore = market.requesterNonce(requester);
        bytes32 expected = keccak256(abi.encode(block.chainid, address(market), requester, nonceBefore));

        bytes32 actual = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        assertEq(actual, expected, "Pre-computed ID must match contract-generated ID");
    }

    // -------------------------------------------------------------------------
    // 12. Multi-forwarder
    // -------------------------------------------------------------------------

    function test_Compliance_MultiForwarder_BothCanCall() public {
        ComplianceMockForwarder fwd2 = new ComplianceMockForwarder(address(usdc));
        usdc.mint(address(fwd2), REWARD);
        vm.prank(owner);
        market.addForwarder(address(fwd2));

        bytes32 taskId1 = _createTask(requester, REWARD, DURATION, market.BOUNTY(), 0, 0);

        bytes32 taskId2 = abi.decode(
            fwd2.relay(address(market), requester, REWARD, abi.encodeCall(market.createTask, (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0)))),
            (bytes32)
        );

        assertTrue(taskId1 != taskId2, "Different forwarders produce distinct task IDs");
    }

    function test_Compliance_MultiForwarder_RemoveRevokes() public {
        vm.prank(owner);
        market.removeForwarder(address(fwd));

        assertFalse(market.trustedForwarders(address(fwd)));

        bytes memory data = abi.encodeCall(market.createTask, (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0)));
        vm.expectRevert("Not trusted forwarder");
        fwd.relay(address(market), requester, REWARD, data);
    }

    // -------------------------------------------------------------------------
    // Fuzz: createTask with all valid modes produces Open tasks
    // -------------------------------------------------------------------------

    function testFuzz_CreateTask_AllModes(uint8 modeIdx) public {
        vm.assume(modeIdx < 5);
        bytes4[5] memory modes = [
            market.BOUNTY(), market.CLAIM(), market.PITCH(), market.BENCHMARK(), market.AUCTION()
        ];
        bytes4 mode = modes[modeIdx];

        bytes32 taskId = _createTask(
            requester,
            REWARD,
            DURATION,
            mode,
            mode == market.PITCH() ? 1 days : 0,
            mode == market.AUCTION() ? 1 days : 0,
            mode == market.AUCTION() ? market.AUCTION_DUTCH() : bytes4(0)
        );

        TaskMarket.Task memory task = market.getTask(taskId);
        assertEq(uint256(task.status), uint256(ITMP.TaskStatus.Open));
        assertEq(task.mode, mode);
        assertEq(task.reward, REWARD);
    }
}
