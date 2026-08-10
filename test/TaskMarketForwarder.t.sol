// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../src/TaskMarketForwarder.sol";
import "../src/interfaces/IPGTRForwarder.sol";
import "../src/interfaces/ITMPCore.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import "./helpers/DiamondTestHelper.sol";
import "../src/interfaces/ITMPDiamond.sol";
import { noEvaluatorConfig } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

contract TaskMarketForwarderTest is DiamondTestHelper {
    ITMPDiamond public market;
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

        market = deployDiamond(owner, address(usdc), owner, 500);

        // Deploy TaskMarketForwarder and register it
        forwarder = new TaskMarketForwarder(address(usdc), address(market), server);
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
    function _relay(address pgtrSenderAddr, uint256 paymentAmount, bytes memory data, bytes32 nonce) internal {
        vm.prank(server);
        forwarder.relay(pgtrSenderAddr, paymentAmount, _validBefore, nonce, data);
    }

    function _createTask() internal returns (bytes32 taskId) {
        // Pre-compute taskId using the requester nonce
        uint256 nonce = market.requesterNonce(requester);
        taskId = keccak256(abi.encode(block.chainid, address(market), requester, nonce));

        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
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
        vm.expectRevert(TaskMarketForwarder.NoActiveForwardedCall.selector);
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
            (
                taskConfig(REWARD, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
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
            (
                taskConfig(REWARD, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
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
            (
                taskConfig(REWARD, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
        );
        bytes32 nonce = _nonce(100);
        bytes4 selector = market.createTask.selector;
        bytes32 receiptHash =
            keccak256(abi.encode(block.chainid, requester, REWARD, nonce, _validBefore, address(market), selector));

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
            (
                taskConfig(REWARD, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
        );
        uint256 expiredBefore = block.timestamp - 1;

        vm.prank(server);
        vm.expectRevert(TaskMarketForwarder.ReceiptExpired.selector);
        forwarder.relay(requester, REWARD, expiredBefore, _nonce(200), data);
    }

    function test_Relay_ExactlyAtDeadline_Succeeds() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
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
        vm.expectRevert(TaskMarketForwarder.NoActiveForwardedCall.selector);
        forwarder.pgtrSender();
    }

    // -----------------------------------------------------------------------
    // Destination revert propagation
    // -----------------------------------------------------------------------

    function test_Relay_PropagatesRevert() public {
        // createTask with reward=0 must revert with the TaskMarket error
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(0, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
        );
        vm.prank(server);
        vm.expectRevert(ITMPCore.RewardMustBeGreaterThanZero.selector);
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
            (
                taskConfig(REWARD, DURATION, market.CLAIM(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
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
    // Authorized relayer restriction
    // -----------------------------------------------------------------------

    function test_Relay_UnauthorizedCaller_Reverts() public {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, market.BOUNTY(), 0, 0, bytes4(0)),
                ITMPCore.StakeConfig({ required: false, bps: 0 }),
                ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                noEvaluatorConfig()
            )
        );
        vm.prank(attacker);
        vm.expectRevert(TaskMarketForwarder.UnauthorizedRelayer.selector);
        forwarder.relay(requester, REWARD, _validBefore, _nonce(400), data);
    }

    // -----------------------------------------------------------------------
    // Immutable addresses
    // -----------------------------------------------------------------------

    function test_ImmutableAddresses() public view {
        assertEq(address(forwarder.usdc()), address(usdc));
        assertEq(forwarder.taskMarket(), address(market));
        assertEq(forwarder.authorizedRelayer(), server);
    }

    /// @notice Freezes the receipt-key derivation against a fixed vector.
    /// @dev `consumedReceipts` is keyed by this hash, and an off-chain caller reconstructs the
    ///      same key to ask whether a relay it never got a hash back for actually landed. That
    ///      reconstruction lives in another language, in another package, and cannot see this
    ///      file -- so a change to the expression below silently invalidates it, and the failure
    ///      is not a wrong answer but a `false` for a call that succeeded.
    ///
    ///      The point of the test is therefore to fail here, on the side that changed. Editing
    ///      the field order, a type, or the set of inputs breaks this assertion; the fix is to
    ///      update the off-chain derivation to match, not to re-freeze the constant. The mapping
    ///      itself is unaffected either way, since entries keep the key they were written under.
    function test_ReceiptHash_DerivationIsFrozen() public pure {
        bytes32 receiptHash = keccak256(
            abi.encode(
                uint256(8453),
                address(0x1111111111111111111111111111111111111111),
                uint256(1_000_000),
                bytes32(0x2222222222222222222222222222222222222222222222222222222222222222),
                uint256(1_786_029_192),
                address(0x3333333333333333333333333333333333333333),
                bytes4(0xdeadbeef)
            )
        );
        assertEq(receiptHash, 0x99ba1fdf70fbfe86a31d2b8e6461b405640c9d5e677c31a0cd24c980cb1782d1);
    }
}
