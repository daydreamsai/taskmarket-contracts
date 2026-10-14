// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../../src/interfaces/ITMPDiamond.sol";
import { TMP_CLAIM, TMP_AUCTION, TMP_AUCTION_DUTCH, TMP_BOUNTY } from "../../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "../mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "../helpers/DiamondTestHelper.sol";
import { taskConfig } from "../helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig } from "../helpers/EvaluatorConfigHelper.sol";

/// @dev Drives random task lifecycles across Claim, Bounty and Dutch-auction tasks, with and without
///      an evaluator, evaluator stake, claim stake and dispute resolver. Every action is attempted
///      and allowed to revert; the invariant only cares about the balance the diamond is left with.
contract EscrowHandler is Test {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal constant REQUESTER = address(0xB0);
    address internal constant EVALUATOR = address(0xD0);
    address internal constant RESOLVER = address(0xE0);
    address[3] internal workers = [address(0xC1), address(0xC2), address(0xC3)];

    uint256 internal constant MAX_TASKS = 12;
    bytes32[] public taskIds;

    constructor(ITMPDiamond _market, MockUSDC _usdc, MockPGTRForwarder _forwarder) {
        market = _market;
        usdc = _usdc;
        forwarder = _forwarder;
        usdc.mint(REQUESTER, 1_000_000e6);
        vm.prank(REQUESTER);
        usdc.approve(address(market), type(uint256).max);
    }

    function taskCount() external view returns (uint256) {
        return taskIds.length;
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bool ok) {
        try forwarder.relay(address(market), sender, payment, data) {
            ok = true;
        } catch { }
    }

    function _task(uint256 seed) internal view returns (bytes32) {
        return taskIds[seed % taskIds.length];
    }

    function _evalConfig(bool hasEvaluator, uint256 stakeSeed, bool hasResolver, uint16 feeBps)
        internal
        pure
        returns (ITMPCore.TaskEvaluatorConfig memory)
    {
        if (!hasEvaluator) return noEvaluatorConfig();
        return ITMPCore.TaskEvaluatorConfig({
            evaluator: EVALUATOR,
            evaluatorStake: bound(stakeSeed, 0, 20e6),
            evaluatorFeeBps: uint16(bound(feeBps, 0, 3000)),
            evaluationWindow: 2 days,
            appealWindow: 1 days,
            disputeResolver: hasResolver ? RESOLVER : address(0)
        });
    }

    function _create(ITMPCore.TaskConfig memory config, ITMPCore.TaskEvaluatorConfig memory evalCfg) internal {
        if (taskIds.length >= MAX_TASKS) return;
        try forwarder.relay(
            address(market),
            REQUESTER,
            config.reward,
            abi.encodeCall(
                market.createTask,
                (
                    config,
                    ITMPCore.StakeConfig({ required: false, bps: 0 }),
                    ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    evalCfg
                )
            )
        ) returns (
            bytes memory ret
        ) {
            taskIds.push(abi.decode(ret, (bytes32)));
        } catch { }
    }

    // -------------------------------------------------------------------------
    // Creation
    // -------------------------------------------------------------------------

    function createClaim(uint256 reward, bool hasEvaluator, uint256 stake, bool hasResolver, uint16 feeBps) external {
        _create(
            taskConfig(bound(reward, 1e6, 500e6), 7 days, TMP_CLAIM),
            _evalConfig(hasEvaluator, stake, hasResolver, feeBps)
        );
    }

    function createBounty(uint256 reward, bool hasEvaluator, uint256 stake, bool hasResolver, uint16 feeBps) external {
        _create(
            taskConfig(bound(reward, 1e6, 500e6) + (reward % 7), 7 days, TMP_BOUNTY),
            _evalConfig(hasEvaluator, stake, hasResolver, feeBps)
        );
    }

    function createAuction(uint256 reward, bool hasEvaluator, uint256 stake, bool hasResolver, uint16 feeBps) external {
        _create(
            taskConfig(bound(reward, 1e6, 500e6), 7 days, TMP_AUCTION, 0, 1 days, TMP_AUCTION_DUTCH),
            _evalConfig(hasEvaluator, stake, hasResolver, feeBps)
        );
    }

    // -------------------------------------------------------------------------
    // Worker actions
    // -------------------------------------------------------------------------

    function claim(uint256 seed, uint256 workerSeed, uint256 stake) external {
        if (taskIds.length == 0) return;
        stake = bound(stake, 0, 50e6);
        _relay(workers[workerSeed % 3], stake, abi.encodeCall(market.claimTask, (_task(seed), stake)));
    }

    function acceptAuction(uint256 seed, uint256 workerSeed, uint256 price) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        price = bound(price, 0, market.getTask(id).reward);
        _relay(workers[workerSeed % 3], 0, abi.encodeCall(market.acceptAuction, (id, price)));
    }

    /// @dev Each worker always submits keccak256(worker), so accept can name a committed hash
    ///      without a submission getter.
    function submit(uint256 seed, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address w = market.getTask(id).worker;
        if (w == address(0)) w = workers[workerSeed % 3];
        _relay(w, 0, abi.encodeCall(market.submitWork, (id, keccak256(abi.encode(w)))));
    }

    function appeal(uint256 seed, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address w = market.getTask(id).worker;
        if (w == address(0)) w = workers[workerSeed % 3];
        _relay(w, 0, abi.encodeCall(market.appeal, (id)));
    }

    // -------------------------------------------------------------------------
    // Requester actions
    // -------------------------------------------------------------------------

    function accept(uint256 seed, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        ITMPCore.Task memory t = market.getTask(id);
        address w = t.worker;
        bytes32 deliverable = t.deliverable;
        if (t.mode == TMP_BOUNTY) {
            w = workers[workerSeed % 3];
            deliverable = keccak256(abi.encode(w));
        }
        _relay(REQUESTER, 0, abi.encodeCall(market.acceptSubmission, (id, w, deliverable, 0)));
    }

    function acceptMulti(uint256 seed, uint16 firstShare) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address[] memory winners = new address[](2);
        winners[0] = workers[0];
        winners[1] = workers[1];
        uint16[] memory shares = new uint16[](2);
        shares[0] = uint16(bound(firstShare, 1, 9999));
        shares[1] = 10000 - shares[0];
        _relay(REQUESTER, 0, abi.encodeCall(market.acceptSubmissions, (id, winners, shares, new bytes32[](0), 0)));
    }

    function cancel(uint256 seed) external {
        if (taskIds.length == 0) return;
        _relay(REQUESTER, 0, abi.encodeCall(market.cancelTask, (_task(seed), 0)));
    }

    function forfeit(uint256 seed) external {
        if (taskIds.length == 0) return;
        _relay(REQUESTER, 0, abi.encodeCall(market.forfeitAndReopen, (_task(seed))));
    }

    function evaluatorTimeout(uint256 seed) external {
        if (taskIds.length == 0) return;
        _relay(REQUESTER, 0, abi.encodeCall(market.evaluatorTimeout, (_task(seed))));
    }

    // -------------------------------------------------------------------------
    // Evaluator, resolver and anyone
    // -------------------------------------------------------------------------

    function evaluate(uint256 seed, uint8 verdictSeed, uint256 amount, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        ITMPCore.Task memory t = market.getTask(id);
        ITMPCore.VerdictType verdict = ITMPCore.VerdictType(verdictSeed % 3);
        ITMPCore.Award[] memory awards;
        if (verdict != ITMPCore.VerdictType.REJECT) {
            awards = new ITMPCore.Award[](1);
            address w = t.mode == TMP_BOUNTY ? workers[workerSeed % 3] : t.worker;
            awards[0] = ITMPCore.Award({ worker: w, amount: bound(amount, 0, t.reward), rank: 1 });
        }
        _relay(EVALUATOR, 0, abi.encodeCall(market.evaluate, (id, verdict, 500, 500, bytes32(0), awards)));
    }

    function resolve(uint256 seed, uint256 amount) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        ITMPCore.Task memory t = market.getTask(id);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: t.worker, amount: bound(amount, 1, t.reward), rank: 1 });
        vm.prank(RESOLVER);
        try market.resolveDispute(id, ITMPCore.VerdictType.PARTIAL, awards) { } catch { }
    }

    function finalize(uint256 seed) external {
        if (taskIds.length == 0) return;
        try market.finalizeVerdict(_task(seed)) { } catch { }
    }

    function refundExpired(uint256 seed) external {
        if (taskIds.length == 0) return;
        try market.refundExpired(_task(seed), 0) { } catch { }
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 4 days));
    }
}

/// @title EscrowConservationInvariantTest
/// @dev The diamond pools every task's escrow in one USDC balance, so a payout path that forgets an
///      amount strands it there, owed to no task, with nothing able to recover it short of an
///      upgrade. The invariant: the balance equals exactly what the non-terminal tasks still owe --
///      their remaining reward, a Claim worker's stake and any evaluator stake -- and a terminal
///      task owes nothing.
contract EscrowConservationInvariantTest is DiamondTestHelper {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    EscrowHandler internal handler;

    function setUp() public {
        address owner = address(0xA0);
        vm.startPrank(owner);
        usdc = new MockUSDC();
        market = deployDiamond(owner, address(usdc), address(0xFEE), 500);
        MockPGTRForwarder forwarder = new MockPGTRForwarder(address(usdc));
        market.addForwarder(address(forwarder));
        vm.stopPrank();
        usdc.mint(address(forwarder), 100_000_000e6);

        handler = new EscrowHandler(market, usdc, forwarder);
        targetContract(address(handler));
    }

    function _owed(bytes32 id) internal view returns (uint256 owed) {
        ITMPCore.Task memory t = market.getTask(id);
        if (
            t.status == ITMPCore.TaskStatus.Accepted || t.status == ITMPCore.TaskStatus.Expired
                || t.status == ITMPCore.TaskStatus.Cancelled
        ) return 0;
        ITMPCore.TaskEvaluatorConfig memory ev = market.getTaskEvaluatorConfig(id);
        owed = t.reward;
        // evaluate() pays its fee out of the reward as soon as the verdict is in.
        if (t.status == ITMPCore.TaskStatus.Appealing || t.status == ITMPCore.TaskStatus.Disputed) {
            uint256 base = t.mode == TMP_AUCTION ? t.stakeAmount : t.reward;
            owed -= (base * ev.evaluatorFeeBps) / 10000;
        }
        // An auction records its accepted price in stakeAmount; it is part of the reward, not a stake.
        if (t.mode == TMP_CLAIM) owed += t.stakeAmount;
        owed += ev.evaluatorStake;
    }

    function invariant_BalanceEqualsWhatLiveTasksOwe() public view {
        uint256 n = handler.taskCount();
        uint256 owed;
        for (uint256 i; i < n; i++) {
            owed += _owed(handler.taskIds(i));
        }
        assertEq(usdc.balanceOf(address(market)), owed, "diamond balance must equal live obligations");
    }
}
