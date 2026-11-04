// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITMPCore } from "../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../src/interfaces/ITMPDiamond.sol";
import { ITMPEvaluator } from "../src/interfaces/ITMPEvaluator.sol";
import { TMP_CLAIM, TMP_PITCH, TMP_AUCTION, TMP_BOUNTY, TMP_BENCHMARK } from "../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "./mocks/MockPGTRForwarder.sol";
import { MockTaskHookV2 } from "./mocks/MockTaskHookV2.sol";
import { BaseTMPHookV2 } from "../src/hooks/base/BaseTMPHookV2.sol";
import { ITMPHookV2 } from "../src/interfaces/ITMPHookV2.sol";
import { DiamondTestHelper } from "./helpers/DiamondTestHelper.sol";
import { taskConfig } from "./helpers/TaskConfigHelper.sol";
import { stakeTerms } from "./helpers/EvaluatorConfigHelper.sol";

/// @dev V2 hook that burns its whole afterExpire budget once armed, to model aggregate hook gas.
contract GasBurnerHookV2 is BaseTMPHookV2 {
    uint256 public sink;
    bool public armed;

    constructor(address diamond_) BaseTMPHookV2(diamond_) { }

    function arm() external {
        armed = true;
    }

    function hookCapabilities() external pure override returns (uint32) {
        return uint32(1) << 23;
    }

    function afterExpire(bytes32, TaskContextV2 calldata, SettlementAmounts calldata, uint64) external override {
        if (!armed) return;
        for (uint256 i; i < type(uint256).max; ++i) {
            sink = i;
        }
    }
}

/// @dev rev028: hooks cannot block a worker's release, dispute resolution or expiry refunds, and an
///      evaluator who never had a delivery gets its stake back at expiry.
contract Rev028HookSafetyTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal owner = address(0xA0);
    address internal feeRecipient = address(0xFEE);
    address internal requester = address(0xB0);
    address internal worker = address(0xC0);
    address internal evaluator = address(0xE0);
    address internal resolver = address(0xD0);

    uint256 internal constant REWARD = 100e6;
    uint256 internal constant ESTAKE = 10e6;
    uint256 internal constant DURATION = 7 days;
    bytes32 internal constant WORK = keccak256("work");

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), feeRecipient, 500);
        forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000e6);
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bytes memory) {
        return forwarder.relay(address(market), sender, payment, data);
    }

    function _evalCfg(uint256 stake, address disputeResolver)
        internal
        view
        returns (ITMPCore.TaskEvaluatorConfig memory)
    {
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: evaluator,
            evaluatorStake: stake,
            evaluatorFeeBps: 0,
            evaluationWindow: uint32(2 days),
            appealWindow: uint32(1 days),
            disputeResolver: disputeResolver
        });
    }

    function _evalCfgNone() internal pure returns (ITMPCore.TaskEvaluatorConfig memory c) {
        return c;
    }

    function _create(
        bytes4 mode,
        bytes4 subtype,
        address[] memory hooks,
        ITMPCore.TaskEvaluatorConfig memory cfg,
        ITMPCore.TaskTerms memory terms
    ) internal returns (bytes32) {
        bytes memory data = abi.encodeCall(
            market.createTask,
            (
                taskConfig(REWARD, DURATION, mode, DURATION, 1 days, subtype),
                ITMPCore.HookConfig({ contracts: hooks, data: hex"" }),
                ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                cfg,
                terms
            )
        );
        return abi.decode(_relay(requester, REWARD + cfg.evaluatorStake, data), (bytes32));
    }

    function _createPlain(bytes4 mode, bytes4 subtype) internal returns (bytes32) {
        return _create(mode, subtype, new address[](0), _evalCfg(ESTAKE, address(0)), stakeTerms(false, 0));
    }

    function _hooks(address h) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = h;
    }

    // -------------------------------------------------------------------------
    // Evaluator stake: returned to the requester when nothing was delivered
    // -------------------------------------------------------------------------

    function _expireAndCheckRefund(bytes32 taskId) internal {
        uint256 reqBefore = usdc.balanceOf(requester);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.warp(block.timestamp + DURATION + 1 days + 1);
        vm.expectEmit(true, true, false, true);
        emit ITMPEvaluator.EvaluatorStakeRefunded(taskId, requester, ESTAKE);
        market.refundExpired(taskId, 0);
        assertEq(usdc.balanceOf(requester) - reqBefore, REWARD + ESTAKE, "reward and evaluator stake refunded");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "nothing forfeited to the fee recipient");
        assertEq(market.getTaskEvaluatorConfig(taskId).evaluatorStake, 0, "stake zeroed");
    }

    function test_ExpiryRefundsEvaluatorStake_ClaimUnclaimed() public {
        _expireAndCheckRefund(_createPlain(TMP_CLAIM, bytes4(0)));
    }

    function test_ExpiryRefundsEvaluatorStake_ClaimClaimedUndelivered() public {
        bytes32 id = _createPlain(TMP_CLAIM, bytes4(0));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (id, 0)));
        _expireAndCheckRefund(id);
    }

    function test_ExpiryRefundsEvaluatorStake_Pitch() public {
        _expireAndCheckRefund(_createPlain(TMP_PITCH, bytes4(0)));
    }

    function test_ExpiryRefundsEvaluatorStake_AuctionOpen() public {
        _expireAndCheckRefund(_createPlain(TMP_AUCTION, market.AUCTION_DUTCH()));
    }

    function test_ExpiryRefundsEvaluatorStake_AuctionClaimedUndelivered() public {
        bytes32 id = _createPlain(TMP_AUCTION, market.AUCTION_DUTCH());
        _relay(worker, 0, abi.encodeCall(market.acceptAuction, (id, REWARD)));
        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Claimed));
        _expireAndCheckRefund(id);
    }

    function test_ExpiryRefundsEvaluatorStake_Bounty() public {
        _expireAndCheckRefund(_createPlain(TMP_BOUNTY, bytes4(0)));
    }

    function test_ExpiryRefundsEvaluatorStake_Benchmark() public {
        _expireAndCheckRefund(_createPlain(TMP_BENCHMARK, bytes4(0)));
    }

    /// @dev A delivered task whose evaluator never acts still forfeits through evaluatorTimeout.
    function test_DeliveredTaskEvaluatorStillForfeits() public {
        bytes32 id = _createPlain(TMP_CLAIM, bytes4(0));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (id, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));
        vm.warp(block.timestamp + 2 days + 1);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        market.evaluatorTimeout(id);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, ESTAKE, "stake forfeited for the delivered task");
    }

    // -------------------------------------------------------------------------
    // Dispute resolution cannot be vetoed by the requester's check hook
    // -------------------------------------------------------------------------

    function test_ResolveDispute_NotVetoedByCheckCompleteHook() public {
        MockTaskHookV2 hook = new MockTaskHookV2(address(market), (uint32(1) << 13) | (uint32(1) << 21));
        bytes32 id = _create(TMP_CLAIM, bytes4(0), _hooks(address(hook)), _evalCfg(0, resolver), stakeTerms(false, 0));
        _relay(worker, 0, abi.encodeCall(market.claimTask, (id, 0)));
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));

        ITMPCore.Award[] memory none = new ITMPCore.Award[](0);
        _relay(
            evaluator,
            0,
            abi.encodeCall(market.evaluate, (id, ITMPCore.VerdictType.REJECT, 100, 1000, bytes32(0), none))
        );
        _relay(worker, 0, abi.encodeCall(market.appeal, (id)));

        hook.setVeto(13, true);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: worker, amount: REWARD, rank: 1 });
        uint256 workerBefore = usdc.balanceOf(worker);
        vm.prank(resolver);
        market.resolveDispute(id, ITMPCore.VerdictType.APPROVE, awards);
        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Accepted));
        assertGt(usdc.balanceOf(worker), workerBefore, "worker paid despite the vetoing hook");
        assertEq(hook.afterCalls(), 1, "after-hook still runs");
    }

    // -------------------------------------------------------------------------
    // A task with hooks cannot trap its worker (no release)
    // -------------------------------------------------------------------------

    function test_ReleaseClaim_AllowedWhenHooksCanVetoDelivery() public {
        MockTaskHookV2 hook = new MockTaskHookV2(address(market), uint32(1) << 9);
        ITMPCore.TaskTerms memory t = stakeTerms(true, 1000);
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Disallowed;
        bytes32 id = _create(TMP_CLAIM, bytes4(0), _hooks(address(hook)), _evalCfgNone(), t);
        uint256 stake = REWARD / 10;
        _relay(worker, stake, abi.encodeCall(market.claimTask, (id, stake)));

        hook.setVeto(9, true);
        vm.expectRevert();
        _relay(worker, 0, abi.encodeCall(market.submitWork, (id, WORK)));

        // The hook vetoes delivery, so the worker must still be able to leave with the stake.
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (id)));
        assertEq(usdc.balanceOf(worker), stake, "stake returned in full inside the grace period");
    }

    function test_ReleaseClaim_DisallowedStillHonouredWithoutHooks() public {
        ITMPCore.TaskTerms memory t = stakeTerms(true, 1000);
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Disallowed;
        bytes32 id = _create(TMP_CLAIM, bytes4(0), new address[](0), _evalCfgNone(), t);
        uint256 stake = REWARD / 10;
        _relay(worker, stake, abi.encodeCall(market.claimTask, (id, stake)));
        vm.expectRevert(ITMPCore.ReleaseNotAllowed.selector);
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (id)));
    }

    function test_ReleaseClaim_DisallowedStillHonouredWhenNoHookCanVetoSubmit() public {
        // A V2 hook that declares only afterComplete (bit 21) cannot veto delivery, so it does not
        // lift Disallowed.
        MockTaskHookV2 hook = new MockTaskHookV2(address(market), uint32(1) << 21);
        ITMPCore.TaskTerms memory t = stakeTerms(true, 1000);
        t.releaseAllowed = ITMPCore.ReleaseAllowed.Disallowed;
        bytes32 id = _create(TMP_CLAIM, bytes4(0), _hooks(address(hook)), _evalCfgNone(), t);
        uint256 stake = REWARD / 10;
        _relay(worker, stake, abi.encodeCall(market.claimTask, (id, stake)));
        vm.expectRevert(ITMPCore.ReleaseNotAllowed.selector);
        _relay(worker, 0, abi.encodeCall(market.releaseClaim, (id)));
    }

    // -------------------------------------------------------------------------
    // Aggregate hook gas cannot block the expiry refund
    // -------------------------------------------------------------------------

    function test_ExpiryRefund_NotBlockedByAggregateHookGas() public {
        vm.prank(owner);
        market.setHookGasStipend(8_000_000);
        address[] memory hooks = new address[](4);
        for (uint256 i; i < 4; ++i) {
            hooks[i] = address(new GasBurnerHookV2(address(market)));
        }
        bytes32 id = _create(TMP_CLAIM, bytes4(0), hooks, _evalCfgNone(), stakeTerms(false, 0));
        for (uint256 i; i < 4; ++i) {
            GasBurnerHookV2(hooks[i]).arm();
        }
        vm.warp(block.timestamp + DURATION + 1);
        uint256 before = usdc.balanceOf(requester);
        // One full stipend plus settlement fits; four stipends do not.
        market.refundExpired{ gas: 12_000_000 }(id, 0);
        assertEq(usdc.balanceOf(requester) - before, REWARD, "refund paid");
        assertEq(uint8(market.getTaskState(id)), uint8(ITMPCore.TaskStatus.Expired));
    }
}
