// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPHook } from "../src/interfaces/ITMPHook.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { LibGuards } from "../src/libraries/LibGuards.sol";
import { TaskMarketForwarderV2 } from "../src/TaskMarketForwarderV2.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";

/// @dev Payment token that, once armed, makes one arbitrary call from inside the transfer the
///      diamond sends to `trigger`, and records how that call ended. The outer transfer itself
///      always completes, so the outer operation's own outcome is unaffected by the attempt.
contract ReentrantToken is ERC20 {
    address public trigger;
    address public reentryTarget;
    bytes public reentryData;
    bool public attempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    constructor() ERC20("Reentrant USDC", "rUSDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address _trigger, address _target, bytes calldata _data) external {
        trigger = _trigger;
        reentryTarget = _target;
        reentryData = _data;
    }

    /// @dev Lets the token act as a relayer in its own right, so a re-entry into a forwarder
    ///      comes from the authorized relayer and only the reentrancy guard can stop it.
    function approveSelf(address spender) external {
        _approve(address(this), spender, type(uint256).max);
    }

    function relayVia(
        TaskMarketForwarderV2 fwd,
        address sender,
        uint256 amount,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata data
    ) external {
        fwd.relay(sender, amount, validBefore, nonce, data);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (trigger != address(0) && to == trigger && !attempted) {
            attempted = true;
            (bool ok, bytes memory ret) = reentryTarget.call(reentryData);
            reentrySucceeded = ok;
            reentryRevertData = ret;
        }
    }
}

/// @dev Hook that approves every check and, from each settlement callback, tries to re-enter the
///      diamond with preset calldata, recording how that call ended.
contract ReentrantHook is ITMPHook {
    address public reentryTarget;
    bytes public reentryData;
    uint256 public attempts;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    function arm(address _target, bytes calldata _data) external {
        reentryTarget = _target;
        reentryData = _data;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(ITMPHook).interfaceId;
    }

    function checkFund(bytes32, ITMPCore.TaskContext calldata, bytes calldata) external pure returns (bool) {
        return true;
    }

    function checkClaim(bytes32, ITMPCore.TaskContext calldata, address) external pure returns (bool) {
        return true;
    }

    function checkSelectWorker(bytes32, ITMPCore.TaskContext calldata, address) external pure returns (bool) {
        return true;
    }

    function checkSubmit(bytes32, ITMPCore.TaskContext calldata, address, bytes32) external pure returns (bool) {
        return true;
    }

    function checkEvaluate(bytes32, ITMPCore.TaskContext calldata, address) external pure returns (bool) {
        return true;
    }

    function checkComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function onComplete(bytes32, ITMPCore.TaskContext calldata, ITMPCore.Verdict calldata) external {
        _reenter();
    }

    function onForfeit(bytes32, ITMPCore.TaskContext calldata, address) external {
        _reenter();
    }

    function onCancel(bytes32, ITMPCore.TaskContext calldata) external {
        _reenter();
    }

    function onExpire(bytes32, ITMPCore.TaskContext calldata) external {
        _reenter();
    }

    function _reenter() private {
        if (reentryTarget == address(0)) return;
        attempts++;
        (bool ok, bytes memory ret) = reentryTarget.call(reentryData);
        reentrySucceeded = ok;
        reentryRevertData = ret;
    }
}

/// @notice Every diamond entry point that moves escrow out runs under the AppStorage reentrancy
///         lock. These tests drive a malicious token and a malicious hook into re-entering the
///         payout paths mid-transfer and assert the re-entry is refused with
///         ReentrancyGuardReentrantCall while the outer call settles exactly once.
contract DiamondReentrancyTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ReentrantToken internal token;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(1);
    address internal feeRecipient = address(2);
    address internal requester = address(3);
    address internal worker1 = address(4);
    address internal worker2 = address(5);

    uint16 internal constant FEE_BPS = 500;
    uint256 internal constant REWARD = 100 * 10 ** 6;
    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        token = new ReentrantToken();
        vm.startPrank(owner);
        market = deployDiamond(owner, address(token), feeRecipient, FEE_BPS);
        forwarder = new MockPGTRForwarder(address(token));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        token.mint(address(forwarder), 10_000 * 10 ** 6);
    }

    function _relay(address sender, uint256 amount, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, amount, data);
    }

    function _viaForwarder(address sender, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeCall(MockPGTRForwarder.relay, (address(market), sender, 0, inner));
    }

    function _createBounty(address[] memory hooks) internal returns (bytes32) {
        return abi.decode(
            _relay(
                requester,
                REWARD,
                abi.encodeCall(
                    market.createTask,
                    (
                        taskConfig(REWARD, DURATION, market.BOUNTY()),
                        ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                        ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                        noEvaluatorConfig(),
                        stakeTerms(false, 0)
                    )
                )
            ),
            (bytes32)
        );
    }

    function _createBounty() internal returns (bytes32) {
        return _createBounty(new address[](0));
    }

    function _submitWork(bytes32 taskId, address worker, bytes32 deliverable) internal {
        _relay(worker, 0, abi.encodeCall(market.submitWork, (taskId, deliverable)));
    }

    function _assertGuardRejected(bytes memory revertData) internal pure {
        assertEq(revertData.length, 4, "re-entry reverted with a bare custom error");
        assertEq(bytes4(revertData), LibGuards.ReentrancyGuardReentrantCall.selector, "reentrancy guard");
    }

    function _assertTokenReentryRejected() internal view {
        assertTrue(token.attempted(), "re-entry attempted");
        assertFalse(token.reentrySucceeded(), "re-entry must fail");
        _assertGuardRejected(token.reentryRevertData());
    }

    /// @dev The lock is released after the outer call: an unrelated guarded call still works.
    function _assertLockReleased() internal {
        bytes32 next = _createBounty();
        assertEq(uint256(market.getTask(next).status), uint256(ITMPCore.TaskStatus.Open));
    }

    function _workers2() internal view returns (address[] memory w, uint16[] memory sh) {
        w = new address[](2);
        w[0] = worker1;
        w[1] = worker2;
        sh = new uint16[](2);
        sh[0] = 6000;
        sh[1] = 4000;
    }

    // -------------------------------------------------------------------------
    // Malicious token
    // -------------------------------------------------------------------------

    function test_Token_AcceptSubmission_ReentryIntoAcceptRejected() public {
        bytes32 taskId = _createBounty();
        bytes32 d = keccak256("work");
        _submitWork(taskId, worker1, d);

        token.arm(
            worker1,
            address(forwarder),
            _viaForwarder(requester, abi.encodeCall(market.acceptSubmission, (taskId, worker1, d, 0)))
        );
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, d, 0)));

        _assertTokenReentryRejected();
        uint256 fee = (REWARD * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(worker1), REWARD - fee, "worker paid once");
        assertEq(token.balanceOf(feeRecipient), fee, "fee paid once");
        assertEq(token.balanceOf(address(market)), 0, "escrow fully released");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
        _assertLockReleased();
    }

    function test_Token_AcceptSubmission_ReentryIntoCancelRejected() public {
        bytes32 taskId = _createBounty();
        bytes32 other = _createBounty();
        bytes32 d = keccak256("work");
        _submitWork(taskId, worker1, d);

        token.arm(worker1, address(forwarder), _viaForwarder(requester, abi.encodeCall(market.cancelTask, (other, 0))));
        _relay(requester, 0, abi.encodeCall(market.acceptSubmission, (taskId, worker1, d, 0)));

        _assertTokenReentryRejected();
        assertEq(uint256(market.getTask(other).status), uint256(ITMPCore.TaskStatus.Open), "other task untouched");
        assertEq(token.balanceOf(requester), 0, "no refund leaked");
    }

    function test_Token_AcceptSubmissions_ReentryRejected() public {
        bytes32 taskId = _createBounty();
        (address[] memory w, uint16[] memory sh) = _workers2();
        _submitWork(taskId, worker1, keccak256("A"));
        _submitWork(taskId, worker2, keccak256("B"));
        bytes memory call_ = abi.encodeCall(market.acceptSubmissions, (taskId, w, sh, new bytes32[](0), 0));

        token.arm(worker1, address(forwarder), _viaForwarder(requester, call_));
        _relay(requester, 0, call_);

        _assertTokenReentryRejected();
        uint256 paid = token.balanceOf(worker1) + token.balanceOf(worker2);
        assertEq(paid + token.balanceOf(feeRecipient), REWARD, "escrow conserved");
        assertEq(token.balanceOf(address(market)), 0, "escrow fully released");
        assertLt(paid, REWARD, "fee withheld once, nothing double paid");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
        _assertLockReleased();
    }

    function test_Token_CancelTask_ReentryRejected() public {
        bytes32 taskId = _createBounty();
        bytes memory call_ = abi.encodeCall(market.cancelTask, (taskId, 0));

        token.arm(requester, address(forwarder), _viaForwarder(requester, call_));
        _relay(requester, 0, call_);

        _assertTokenReentryRejected();
        assertEq(token.balanceOf(requester), REWARD, "refunded once");
        assertEq(token.balanceOf(address(market)), 0);
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Cancelled));
        _assertLockReleased();
    }

    function test_Token_RefundExpired_ReentryRejected() public {
        bytes32 taskId = _createBounty();
        bytes32 other = _createBounty();
        vm.warp(block.timestamp + DURATION + 1);

        // refundExpired is permissionless, so the token re-enters it directly without a forwarder,
        // targeting a second expired task whose escrow would otherwise be released.
        token.arm(requester, address(market), abi.encodeCall(market.refundExpired, (other, 0)));
        market.refundExpired(taskId, 0);

        _assertTokenReentryRejected();
        assertEq(token.balanceOf(requester), REWARD, "only the outer task refunded");
        assertEq(token.balanceOf(address(market)), REWARD, "other task still escrowed");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Expired));
        assertEq(uint256(market.getTask(other).status), uint256(ITMPCore.TaskStatus.Open));

        market.refundExpired(other, 0);
        assertEq(token.balanceOf(requester), 2 * REWARD);
    }

    // -------------------------------------------------------------------------
    // Malicious hook (settlement callbacks are swallowed, stipend-bounded calls)
    // -------------------------------------------------------------------------

    function _hooked() internal returns (ReentrantHook hook, bytes32 taskId) {
        hook = new ReentrantHook();
        address[] memory hooks = new address[](1);
        hooks[0] = address(hook);
        taskId = _createBounty(hooks);
    }

    function _assertHookReentryRejected(ReentrantHook hook) internal view {
        assertEq(hook.attempts(), 1, "hook re-entered once");
        assertFalse(hook.reentrySucceeded(), "re-entry must fail");
        _assertGuardRejected(hook.reentryRevertData());
    }

    function test_Hook_OnComplete_ReentryIntoAcceptRejected() public {
        (ReentrantHook hook, bytes32 taskId) = _hooked();
        bytes32 d = keccak256("work");
        _submitWork(taskId, worker1, d);
        bytes memory call_ = abi.encodeCall(market.acceptSubmission, (taskId, worker1, d, 0));

        hook.arm(address(forwarder), _viaForwarder(requester, call_));
        _relay(requester, 0, call_);

        _assertHookReentryRejected(hook);
        uint256 fee = (REWARD * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(worker1), REWARD - fee, "worker paid once");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
        _assertLockReleased();
    }

    function test_Hook_OnComplete_MultiWinner_ReentryRejected() public {
        (ReentrantHook hook, bytes32 taskId) = _hooked();
        (address[] memory w, uint16[] memory sh) = _workers2();
        _submitWork(taskId, worker1, keccak256("A"));
        _submitWork(taskId, worker2, keccak256("B"));
        bytes memory call_ = abi.encodeCall(market.acceptSubmissions, (taskId, w, sh, new bytes32[](0), 0));

        hook.arm(address(forwarder), _viaForwarder(requester, call_));
        _relay(requester, 0, call_);

        _assertHookReentryRejected(hook);
        uint256 paid = token.balanceOf(worker1) + token.balanceOf(worker2);
        assertEq(paid + token.balanceOf(feeRecipient), REWARD, "escrow conserved");
        assertEq(token.balanceOf(address(market)), 0, "escrow fully released");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Accepted));
    }

    function test_Hook_OnCancel_ReentryRejected() public {
        (ReentrantHook hook, bytes32 taskId) = _hooked();
        bytes32 other = _createBounty();
        hook.arm(address(forwarder), _viaForwarder(requester, abi.encodeCall(market.cancelTask, (other, 0))));
        _relay(requester, 0, abi.encodeCall(market.cancelTask, (taskId, 0)));

        _assertHookReentryRejected(hook);
        assertEq(token.balanceOf(requester), REWARD, "refunded once");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Cancelled));
        assertEq(uint256(market.getTask(other).status), uint256(ITMPCore.TaskStatus.Open));
        _assertLockReleased();
    }

    function test_Hook_OnExpire_ReentryRejected() public {
        (ReentrantHook hook, bytes32 taskId) = _hooked();
        bytes32 other = _createBounty();
        vm.warp(block.timestamp + DURATION + 1);

        hook.arm(address(market), abi.encodeCall(market.refundExpired, (other, 0)));
        market.refundExpired(taskId, 0);

        _assertHookReentryRejected(hook);
        assertEq(token.balanceOf(requester), REWARD, "only the outer task refunded");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Expired));
        assertEq(uint256(market.getTask(other).status), uint256(ITMPCore.TaskStatus.Open));
    }
}

/// @notice TaskMarketForwarderV2.relay is nonReentrant. The malicious token is itself the
///         authorized relayer, so a re-entry from inside a payout passes every relay check
///         except the guard.
contract ForwarderReentrancyTest is DiamondTestHelper {
    ITMPDiamond internal market;
    ReentrantToken internal token;
    TaskMarketForwarderV2 internal forwarder;

    address internal owner = address(1);
    address internal requester = address(3);

    uint256 internal constant REWARD = 100 * 10 ** 6;
    uint256 internal constant DURATION = 7 days;

    function setUp() public {
        token = new ReentrantToken();
        vm.startPrank(owner);
        market = deployDiamond(owner, address(token), owner, 500);
        forwarder = new TaskMarketForwarderV2(address(token), address(market), address(token));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        token.mint(address(token), 10_000 * 10 ** 6);
        token.approveSelf(address(forwarder));
    }

    function _create(bytes32 nonce) internal returns (bytes32 taskId) {
        taskId = keccak256(abi.encode(block.chainid, address(market), requester, market.requesterNonce(requester)));
        token.relayVia(
            forwarder,
            requester,
            REWARD,
            block.timestamp + 5 minutes,
            nonce,
            abi.encodeCall(
                market.createTask,
                (
                    taskConfig(REWARD, DURATION, market.BOUNTY()),
                    ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    noEvaluatorConfig(),
                    stakeTerms(false, 0)
                )
            )
        );
    }

    function test_Relay_ReentryFromPayoutRejected() public {
        bytes32 taskId = _create(keccak256("n0"));
        bytes32 other = _create(keccak256("n1"));
        uint256 vb = block.timestamp + 5 minutes;

        token.arm(
            requester,
            address(token),
            abi.encodeCall(
                ReentrantToken.relayVia,
                (forwarder, requester, 0, vb, keccak256("n3"), abi.encodeCall(market.cancelTask, (other, 0)))
            )
        );
        token.relayVia(forwarder, requester, 0, vb, keccak256("n2"), abi.encodeCall(market.cancelTask, (taskId, 0)));

        assertTrue(token.attempted(), "re-entry attempted");
        assertFalse(token.reentrySucceeded(), "re-entry must fail");
        bytes memory ret = token.reentryRevertData();
        assertEq(bytes4(ret), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "forwarder guard");

        assertEq(token.balanceOf(requester), REWARD, "refunded once");
        assertEq(uint256(market.getTask(taskId).status), uint256(ITMPCore.TaskStatus.Cancelled));
        assertEq(uint256(market.getTask(other).status), uint256(ITMPCore.TaskStatus.Open));

        // The guard was released and the inner receipt was never consumed: the same relay now succeeds.
        token.relayVia(forwarder, requester, 0, vb, keccak256("n3"), abi.encodeCall(market.cancelTask, (other, 0)));
        assertEq(uint256(market.getTask(other).status), uint256(ITMPCore.TaskStatus.Cancelled));
    }
}
