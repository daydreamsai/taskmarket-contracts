// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../src/TaskMarket.sol";
import "../src/TaskMarketForwarder.sol";
import "../src/interfaces/IPGTRForwarder.sol";
import "../src/interfaces/ITMP.sol";
import "./mocks/MockUSDC.sol";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

contract TaskMarketForwarderTest is Test {
    TaskMarket public market;
    TaskMarketForwarder public forwarder;
    MockUSDC public usdc;

    address public owner = address(1);
    address public server = address(2);
    address public requester = address(3);
    address public worker = address(4);
    address public attacker = address(5);

    uint256 constant REWARD = 100 * 10 ** 6; // 100 USDC
    uint256 constant DURATION = 7 days;

    // Default relay params — override per-test as needed
    uint256 internal _validBefore;
    bytes32 internal _receiptNonce;

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockUSDC();

        // Deploy TaskMarket via UUPS proxy (msg.sender == owner -> sets ownable)
        address impl = address(new TaskMarket());
        bytes memory init = abi.encodeCall(TaskMarket.initialize, (address(usdc), owner, 500));
        market = TaskMarket(address(new ERC1967Proxy(impl, init)));

        // Deploy TaskMarketForwarder and register it
        forwarder = new TaskMarketForwarder(address(usdc), address(market));
        market.addForwarder(address(forwarder));

        vm.stopPrank();

        // Fund server with USDC and approve forwarder
        usdc.mint(server, 10_000 * 10 ** 6);
        vm.prank(server);
        usdc.approve(address(forwarder), type(uint256).max);

        // Fund requester (for direct checks)
        usdc.mint(requester, 10_000 * 10 ** 6);

        _validBefore = block.timestamp + 5 minutes;
        _receiptNonce = keccak256("nonce-0");
    }

    // Encode a relay receipt nonce that is unique per call index
    function _nonce(uint256 idx) internal pure returns (bytes32) {
        return keccak256(abi.encode("nonce", idx));
    }

    // Relay helper: server relays a call on behalf of pgtrSender
    function _relay(
        address pgtrSenderAddr,
        uint256 paymentAmount,
        bytes memory data,
        bytes32 nonce
    ) internal {
        vm.prank(server);
        forwarder.relay(pgtrSenderAddr, paymentAmount, _validBefore, nonce, data);
    }

    function _createTask() internal returns (bytes32 taskId) {
        // Pre-compute taskId using the requester nonce
        uint256 nonce = market.requesterNonce(requester);
        taskId = keccak256(abi.encode(block.chainid, address(market), requester, nonce));

        bytes memory data = abi.encodeCall(
            market.createTask,
            (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0))
        );
        _relay(requester, REWARD, data, _nonce(0));
    }

    // -----------------------------------------------------------------------
    // ERC-165
    // -----------------------------------------------------------------------

    function test_ERC165_IPGTRForwarder() public view {
        assertTrue(forwarder.supportsInterface(type(IPGTRForwarder).interfaceId));
    }

    function test_ERC165_IERC165() public view {
        assertTrue(forwarder.supportsInterface(type(IERC165).interfaceId));
    }

    function test_ERC165_RandomBytes_False() public view {
        assertFalse(forwarder.supportsInterface(0xdeadbeef));
    }

    // -----------------------------------------------------------------------
    // isPGTRForwarder / isTrustedForwarder
    // -----------------------------------------------------------------------

    function test_IsPGTRForwarder() public view {
        assertTrue(forwarder.isPGTRForwarder());
    }

    function test_IsTrustedForwarder_Self() public view {
        assertTrue(forwarder.isTrustedForwarder(address(forwarder)));
    }

    function test_IsTrustedForwarder_Other_False() public view {
        assertFalse(forwarder.isTrustedForwarder(attacker));
    }

    // -----------------------------------------------------------------------
    // pgtrSender — only valid during an active relay
    // -----------------------------------------------------------------------

    function test_PgtrSender_Reverts_OutsideRelay() public {
        vm.expectRevert("No active forwarded call");
        forwarder.pgtrSender();
    }

    // -----------------------------------------------------------------------
    // Happy path: relay a createTask
    // -----------------------------------------------------------------------

    function test_Relay_CreateTask_Success() public {
        bytes32 taskId = _createTask();
        // taskId is pre-computed from nonce — must not be zero
        assertTrue(taskId != bytes32(0));
        // Verify funds reached the market
        assertEq(usdc.balanceOf(address(market)), REWARD);
    }

    // -----------------------------------------------------------------------
    // Payment flow: forwarder pulls USDC from server
    // -----------------------------------------------------------------------

    function test_Relay_PullsUSDC_FromServer() public {
        uint256 serverBefore = usdc.balanceOf(server);
        uint256 marketBefore = usdc.balanceOf(address(market));

        _createTask();

        assertEq(usdc.balanceOf(server), serverBefore - REWARD);
        assertEq(usdc.balanceOf(address(market)), marketBefore + REWARD);
    }

    // -----------------------------------------------------------------------
    // PaymentGatedCall event
    // -----------------------------------------------------------------------

    function test_Relay_EmitsPaymentGatedCall() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0))
        );
        bytes4 expectedSelector = market.createTask.selector;

        vm.prank(server);
        vm.expectEmit(true, true, true, true);
        emit IPGTRForwarder.PaymentGatedCall(requester, address(market), expectedSelector, REWARD);
        forwarder.relay(requester, REWARD, _validBefore, _nonce(1), data);
    }

    // -----------------------------------------------------------------------
    // Receipt replay protection
    // -----------------------------------------------------------------------

    function test_Relay_Replay_Reverts() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0))
        );
        bytes32 nonce = _nonce(99);

        vm.prank(server);
        forwarder.relay(requester, REWARD, _validBefore, nonce, data);

        // Second relay with the same nonce must fail
        usdc.mint(server, REWARD); // re-fund so USDC is not the bottleneck
        vm.prank(server);
        vm.expectRevert(TaskMarketForwarder.ReceiptAlreadyConsumed.selector);
        forwarder.relay(requester, REWARD, _validBefore, nonce, data);
    }

    function test_ConsumedReceipts_Stored() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0))
        );
        bytes32 nonce = _nonce(100);
        bytes4 selector = market.createTask.selector;
        bytes32 receiptHash = keccak256(
            abi.encode(block.chainid, requester, REWARD, nonce, _validBefore, address(market), selector)
        );

        assertFalse(forwarder.consumedReceipts(receiptHash));

        vm.prank(server);
        forwarder.relay(requester, REWARD, _validBefore, nonce, data);

        assertTrue(forwarder.consumedReceipts(receiptHash));
    }

    // -----------------------------------------------------------------------
    // Expiry
    // -----------------------------------------------------------------------

    function test_Relay_Expired_Reverts() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0))
        );
        uint256 expiredBefore = block.timestamp - 1;

        vm.prank(server);
        vm.expectRevert(TaskMarketForwarder.ReceiptExpired.selector);
        forwarder.relay(requester, REWARD, expiredBefore, _nonce(200), data);
    }

    function test_Relay_ExactlyAtDeadline_Succeeds() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (REWARD, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0))
        );
        // validBefore == block.timestamp (inclusive, <= check)
        vm.prank(server);
        forwarder.relay(requester, REWARD, block.timestamp, _nonce(201), data);
    }

    // -----------------------------------------------------------------------
    // pgtrSender atomicity — reset after call
    // -----------------------------------------------------------------------

    function test_PgtrSender_ResetAfterRelay() public {
        _createTask();
        // pgtrSender must revert outside of an active relay
        vm.expectRevert("No active forwarded call");
        forwarder.pgtrSender();
    }

    // -----------------------------------------------------------------------
    // Destination revert propagation
    // -----------------------------------------------------------------------

    function test_Relay_PropagatesRevert() public {
        // createTask with reward=0 must revert with the TaskMarket error
        bytes memory data = abi.encodeCall(
            market.createTask,
            (0, DURATION, market.BOUNTY(), 0, 0, bytes32(0), "", bytes4(0))
        );
        vm.prank(server);
        vm.expectRevert("Reward must be greater than 0");
        forwarder.relay(requester, 0, _validBefore, _nonce(300), data);
    }

    // -----------------------------------------------------------------------
    // Zero-payment relay (no USDC transfer)
    // -----------------------------------------------------------------------

    function test_Relay_ZeroPayment_NoTransfer() public {
        // Create a CLAIM mode task so a worker can claim with zero stake
        uint256 nonce = market.requesterNonce(requester);
        bytes32 taskId = keccak256(abi.encode(block.chainid, address(market), requester, nonce));

        bytes memory createData = abi.encodeCall(
            market.createTask,
            (REWARD, DURATION, market.CLAIM(), 0, 0, bytes32(0), "", bytes4(0))
        );
        _relay(requester, REWARD, createData, _nonce(0));

        // claimTask with zero stake requires no additional payment
        bytes memory claimData = abi.encodeCall(market.claimTask, (taskId, 0));

        uint256 marketBefore = usdc.balanceOf(address(market));
        _relay(worker, 0, claimData, _nonce(1));

        // No additional USDC moved
        assertEq(usdc.balanceOf(address(market)), marketBefore);
    }

    // -----------------------------------------------------------------------
    // Immutable addresses
    // -----------------------------------------------------------------------

    function test_ImmutableAddresses() public view {
        assertEq(address(forwarder.usdc()), address(usdc));
        assertEq(forwarder.taskMarket(), address(market));
    }
}
