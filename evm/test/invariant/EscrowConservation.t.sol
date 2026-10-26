// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { ITMPCore } from "../../src/interfaces/ITMPCore.sol";
import { ITMPDiamond } from "../../src/interfaces/ITMPDiamond.sol";
import { ITMPTerms } from "../../src/interfaces/ITMPTerms.sol";
import { TMP_CLAIM, TMP_AUCTION, TMP_AUCTION_DUTCH, TMP_BOUNTY } from "../../src/interfaces/ITMPModes.sol";
import { MockUSDC } from "../../src/mocks/MockUSDC.sol";
import { MockPGTRForwarder } from "../mocks/MockPGTRForwarder.sol";
import { DiamondTestHelper } from "../helpers/DiamondTestHelper.sol";
import { taskConfig } from "../helpers/TaskConfigHelper.sol";
import { noEvaluatorConfig, stakeTerms } from "../helpers/EvaluatorConfigHelper.sol";

/// @dev Drives random task lifecycles across Claim, Bounty and Dutch-auction tasks, with and without
///      an evaluator, evaluator stake, claim stake and dispute resolver, and under random rev025
///      terms: required stakes, penaltyTo, review window, reject outcome and fee, revisions,
///      reopen extension and release grace. Every action is attempted
///      and allowed to revert; the invariant only cares about the balance the diamond is left with.
contract EscrowHandler is Test {
    ITMPDiamond internal market;
    MockUSDC internal usdc;
    MockPGTRForwarder internal forwarder;

    address internal constant REQUESTER = address(0xB0);
    address internal constant EVALUATOR = address(0xD0);
    address internal constant RESOLVER = address(0xE0);
    // Five workers, since rejectDelivery and releaseClaim bar a worker from the task for good.
    uint256 internal constant WORKERS = 5;
    address[WORKERS] internal workers = [address(0xC1), address(0xC2), address(0xC3), address(0xC4), address(0xC5)];

    // Creation stops while MAX_LIVE tasks are unsettled, so settled ones make room for new ones
    // and long runs keep reaching settlement paths; MAX_TASKS bounds the invariant's loop.
    uint256 internal constant MAX_LIVE = 8;
    uint256 internal constant MAX_TASKS = 64;
    bytes32[] public taskIds;
    mapping(string => uint256) public calls;
    // A requester action that succeeded, or moved diamond funds, on a Bounty past its decision
    // deadline. The invariant requires zero.
    uint256 public lapsedViolations;
    // acceptSubmissions that settled above the winner cap, moved funds doing so, or failed at it.
    uint256 public capViolations;
    mapping(bytes32 => uint256) internal activeSubs;
    mapping(bytes32 => mapping(address => uint256)) internal subsBy;

    constructor(ITMPDiamond _market, MockUSDC _usdc, MockPGTRForwarder _forwarder) {
        market = _market;
        usdc = _usdc;
        forwarder = _forwarder;
        usdc.mint(REQUESTER, 1_000_000e6);
        vm.prank(REQUESTER);
        usdc.approve(address(market), type(uint256).max);
    }

    function _full() internal view returns (bool) {
        if (taskIds.length >= MAX_TASKS) return true;
        uint256 live;
        for (uint256 i; i < taskIds.length; i++) {
            ITMPCore.TaskStatus st = market.getTask(taskIds[i]).status;
            if (
                st != ITMPCore.TaskStatus.Accepted && st != ITMPCore.TaskStatus.Expired
                    && st != ITMPCore.TaskStatus.Cancelled
            ) ++live;
        }
        return live >= MAX_LIVE;
    }

    function _task(uint256 seed) internal view returns (bytes32) {
        // Prefer the most recent tasks, where the live ones are.
        uint256 n = taskIds.length;
        uint256 window = n < MAX_LIVE * 2 ? n : MAX_LIVE * 2;
        return taskIds[n - 1 - (seed % window)];
    }

    function taskCount() external view returns (uint256) {
        return taskIds.length;
    }

    function _relay(address sender, uint256 payment, bytes memory data) internal returns (bool ok) {
        try forwarder.relay(address(market), sender, payment, data) {
            ok = true;
        } catch { }
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
        if (_full()) return;
        try forwarder.relay(
            address(market),
            REQUESTER,
            config.reward,
            abi.encodeCall(
                market.createTask,
                (
                    config,
                    ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    evalCfg,
                    stakeTerms(false, 0)
                )
            )
        ) returns (
            bytes memory ret
        ) {
            taskIds.push(abi.decode(ret, (bytes32)));
        } catch { }
    }

    function _window(uint256 seed) internal pure returns (uint32) {
        return seed % 3 == 0 ? 0 : uint32(bound(seed, 1 days, 5 days));
    }

    function _terms(uint256 seed, bool auction) internal pure returns (ITMPCore.TaskTerms memory t) {
        t.version = 1;
        t.stakeRequired = seed % 2 == 0;
        t.stakeBps = uint16(bound(seed >> 8, 0, 5000));
        t.penaltyTo = ITMPCore.PenaltyTo((seed >> 24) % 2);
        t.reviewWindowSecs = _window(seed >> 32);
        t.reopenExtensionSecs = _window(seed >> 64);
        t.releaseAllowed = ITMPCore.ReleaseAllowed((seed >> 96) % 3);
        t.releaseGraceBps = uint16(bound(seed >> 104, 0, 10001));
        t.rejectOutcome = auction ? ITMPCore.RejectOutcome.Refund : ITMPCore.RejectOutcome((seed >> 120) % 3);
        // Stored as value + 1; zero means the default and 1 means no reject fee.
        t.rejectFeeBps = uint16(bound(seed >> 128, 0, 5001));
        t.maxRevisions = uint8(bound(seed >> 144, 0, 6));
    }

    function _createWithTerms(
        ITMPCore.TaskConfig memory config,
        ITMPCore.TaskEvaluatorConfig memory evalCfg,
        ITMPCore.TaskTerms memory terms
    ) internal {
        if (_full()) return;
        try forwarder.relay(
            address(market),
            REQUESTER,
            config.reward,
            abi.encodeCall(
                ITMPTerms.createTask,
                (
                    config,
                    ITMPCore.HookConfig({ contracts: new address[](0), data: hex"" }),
                    ITMPCore.TaskContent({ contentHash: bytes32(0), contentURI: "", tags: new bytes32[](0) }),
                    evalCfg,
                    terms
                )
            )
        ) returns (
            bytes memory ret
        ) {
            taskIds.push(abi.decode(ret, (bytes32)));
            ++calls["createWithTerms"];
        } catch { }
    }

    // -------------------------------------------------------------------------
    // Creation
    // -------------------------------------------------------------------------

    /// @dev Rev025 Claim task, usually without an evaluator so it settles through the review window.
    function createClaimTerms(uint256 reward, uint256 termsSeed, bool hasEvaluator, uint256 stake) external {
        _createWithTerms(
            taskConfig(bound(reward, 1e6, 500e6), 7 days, TMP_CLAIM),
            _evalConfig(hasEvaluator && termsSeed % 4 == 0, stake, true, uint16(stake)),
            _terms(termsSeed, false)
        );
    }

    /// @dev Rev025 Bounty without an evaluator, so its decision deadline applies.
    function createBountyTerms(uint256 reward, uint256 termsSeed) external {
        ITMPCore.TaskTerms memory t = _terms(termsSeed, false);
        t.decisionWindowSecs = _window(termsSeed >> 160);
        _createWithTerms(taskConfig(bound(reward, 1e6, 500e6), 7 days, TMP_BOUNTY), noEvaluatorConfig(), t);
    }

    function createAuctionTerms(uint256 reward, uint256 termsSeed) external {
        _createWithTerms(
            taskConfig(bound(reward, 1e6, 500e6), 7 days, TMP_AUCTION, 0, 1 days, TMP_AUCTION_DUTCH),
            noEvaluatorConfig(),
            _terms(termsSeed, true)
        );
    }

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
        bytes32 id = _task(seed);
        // Half the time stake exactly the required minimum, so enforced-stake tasks get claimed.
        if (stake % 2 == 0) stake = (market.getTask(id).reward * market.getTaskTerms(id).stakeBps + 9999) / 10000;
        else stake = bound(stake, 0, 50e6);
        if (_relay(workers[workerSeed % WORKERS], stake, abi.encodeCall(market.claimTask, (id, stake))) && stake > 0) {
            ++calls["claimStaked"];
        }
    }

    function acceptAuction(uint256 seed, uint256 workerSeed, uint256 price) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        price = bound(price, 0, market.getTask(id).reward);
        _relay(workers[workerSeed % WORKERS], 0, abi.encodeCall(market.acceptAuction, (id, price)));
    }

    /// @dev Each worker always submits keccak256(worker), so accept can name a committed hash
    ///      without a submission getter.
    function submit(uint256 seed, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address w = market.getTask(id).worker;
        if (w == address(0)) w = workers[workerSeed % WORKERS];
        if (
            _relay(w, 0, abi.encodeCall(market.submitWork, (id, keccak256(abi.encode(w)))))
                && market.getTask(id).mode == TMP_BOUNTY
        ) {
            ++activeSubs[id];
            ++subsBy[id][w];
        }
    }

    /// @dev Mirrors the contract's decision deadline for a Bounty without an evaluator, from the
    ///      handler's own submission tally, so a lapsed task is known before the call is made.
    function _decisionLapsed(bytes32 id) internal view returns (bool) {
        ITMPCore.Task memory t = market.getTask(id);
        if (t.mode != TMP_BOUNTY || activeSubs[id] == 0) return false;
        if (market.getTaskEvaluatorConfig(id).evaluator != address(0)) return false;
        uint32 w = market.getTaskTerms(id).decisionWindowSecs;
        return block.timestamp > t.expiryTime + (w == 0 ? 7 days : w);
    }

    /// @dev Runs a requester call that must fail without moving funds once the decision lapsed.
    function _lapseGuarded(bytes32 id, bytes memory data) internal returns (bool ok) {
        bool lapsed = _decisionLapsed(id);
        uint256 before = usdc.balanceOf(address(market));
        ok = _relay(REQUESTER, 0, data);
        if (lapsed) {
            ++calls["lapsedAttempt"];
            if (ok || usdc.balanceOf(address(market)) != before) ++lapsedViolations;
        }
    }

    function rejectSubmission(uint256 seed, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address w = workers[workerSeed % WORKERS];
        if (_lapseGuarded(id, abi.encodeCall(market.rejectSubmission, (id, w)))) {
            uint256 n = subsBy[id][w];
            activeSubs[id] = activeSubs[id] > n ? activeSubs[id] - n : 0;
            subsBy[id][w] = 0;
            ++calls["rejectSubmission"];
        }
    }

    /// @dev A Bounty with n distinct submitters, accepted with all n as winners: n <= 50 must
    ///      settle in full, 51 must revert with no funds moved.
    function acceptAtWinnerCap(uint256 nSeed, uint256 reward) external {
        if (_full()) return;
        uint256 n = bound(nSeed, 48, 51);
        uint256 before = taskIds.length;
        _createWithTerms(
            taskConfig(bound(reward, 1e6, 500e6), 7 days, TMP_BOUNTY), noEvaluatorConfig(), _terms(0, false)
        );
        if (taskIds.length == before) return;
        bytes32 id = taskIds[taskIds.length - 1];
        address[] memory winners = new address[](n);
        uint16[] memory shares = new uint16[](n);
        uint256 left = 10000;
        for (uint256 i; i < n; i++) {
            winners[i] = address(uint160(0x10000 + i));
            _relay(winners[i], 0, abi.encodeCall(market.submitWork, (id, keccak256(abi.encode(winners[i])))));
            shares[i] = uint16(i == n - 1 ? left : 10000 / n);
            left -= shares[i];
        }
        activeSubs[id] += n;
        uint256 bal = usdc.balanceOf(address(market));
        bool ok =
            _relay(REQUESTER, 0, abi.encodeCall(market.acceptSubmissions, (id, winners, shares, new bytes32[](0), 0)));
        if (n > 50) {
            if (ok || usdc.balanceOf(address(market)) != bal) ++capViolations;
            ++calls["winnerCapRejected"];
        } else {
            if (!ok) ++capViolations;
            ++calls["winnerCapAccepted"];
        }
    }

    /// @dev Claim and deliver in one step, so review-window paths are reached within a run's depth.
    function claimAndSubmit(uint256 seed, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        ITMPCore.Task memory t = market.getTask(id);
        if (t.mode != TMP_CLAIM || t.status != ITMPCore.TaskStatus.Open) return;
        address w = workers[workerSeed % WORKERS];
        uint256 stake = (t.reward * market.getTaskTerms(id).stakeBps + 9999) / 10000;
        if (!_relay(w, stake, abi.encodeCall(market.claimTask, (id, stake)))) return;
        if (stake > 0) ++calls["claimStaked"];
        _relay(w, 0, abi.encodeCall(market.submitWork, (id, keccak256(abi.encode(w)))));
    }

    function appeal(uint256 seed, uint256 workerSeed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address w = market.getTask(id).worker;
        if (w == address(0)) w = workers[workerSeed % WORKERS];
        if (_relay(w, 0, abi.encodeCall(market.appeal, (id)))) ++calls["appeal"];
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
            w = workers[workerSeed % WORKERS];
            deliverable = keccak256(abi.encode(w));
        }
        bool lapsed = _decisionLapsed(id);
        if (_relay(REQUESTER, 0, abi.encodeCall(market.acceptSubmission, (id, w, deliverable, 0)))) {
            ++calls["acceptSubmission"];
            if (lapsed) ++calls["acceptAfterLapse"];
        }
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
        bytes32 id = _task(seed);
        _lapseGuarded(id, abi.encodeCall(market.cancelTask, (id, 0)));
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
            address w = t.mode == TMP_BOUNTY ? workers[workerSeed % WORKERS] : t.worker;
            awards[0] = ITMPCore.Award({ worker: w, amount: bound(amount, 0, t.reward), rank: 1 });
        }
        if (_relay(EVALUATOR, 0, abi.encodeCall(market.evaluate, (id, verdict, 500, 500, bytes32(0), awards)))) {
            ++calls["evaluate"];
        }
    }

    function resolve(uint256 seed, uint256 amount) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        ITMPCore.Task memory t = market.getTask(id);
        ITMPCore.Award[] memory awards = new ITMPCore.Award[](1);
        awards[0] = ITMPCore.Award({ worker: t.worker, amount: bound(amount, 1, t.reward), rank: 1 });
        vm.prank(RESOLVER);
        try market.resolveDispute(id, ITMPCore.VerdictType.PARTIAL, awards) {
            ++calls["resolveDispute"];
        } catch { }
    }

    function finalize(uint256 seed) external {
        if (taskIds.length == 0) return;
        try market.finalizeVerdict(_task(seed)) {
            ++calls["finalizeVerdict"];
        } catch { }
    }

    function refundExpired(uint256 seed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        bool lapsed = _decisionLapsed(id);
        uint256 before = usdc.balanceOf(address(market));
        bool ok;
        try market.refundExpired(id, 0) {
            ok = true;
            ++calls["refundExpired"];
        } catch { }
        if (lapsed && (ok || usdc.balanceOf(address(market)) != before)) ++lapsedViolations;
    }

    // -------------------------------------------------------------------------
    // Rev025 review window and release
    // -------------------------------------------------------------------------

    function rejectDelivery(uint256 seed) external {
        if (taskIds.length == 0) return;
        if (_relay(REQUESTER, 0, abi.encodeCall(market.rejectDelivery, (_task(seed))))) ++calls["rejectDelivery"];
    }

    function requestRevision(uint256 seed) external {
        if (taskIds.length == 0) return;
        if (_relay(REQUESTER, 0, abi.encodeCall(market.requestRevision, (_task(seed))))) ++calls["requestRevision"];
    }

    function settleLapsedReview(uint256 seed) external {
        if (taskIds.length == 0) return;
        try market.settleLapsedReview(_task(seed)) {
            ++calls["settleLapsedReview"];
        } catch { }
    }

    function releaseClaim(uint256 seed) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address w = market.getTask(id).worker;
        if (w == address(0)) return;
        if (_relay(w, 0, abi.encodeCall(market.releaseClaim, (id)))) ++calls["releaseClaim"];
    }

    /// @dev Moves no funds; it is here so rating an awarded worker interleaves with settlement.
    function rate(uint256 seed, uint256 workerSeed, uint8 rating) external {
        if (taskIds.length == 0) return;
        bytes32 id = _task(seed);
        address w = market.getTask(id).worker;
        if (w == address(0)) w = workers[workerSeed % WORKERS];
        if (_relay(
                REQUESTER,
                0,
                abi.encodeCall(market.rateTask, (id, w, uint8(bound(rating, 0, 100)), 0, 0, "", bytes32(0)))
            )) ++calls["rateTask"];
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
        // An auction records its accepted price in stakeAmount; it is part of the reward, not a stake.
        if (t.mode == TMP_CLAIM) owed += t.stakeAmount;
        owed += ev.evaluatorStake;
    }

    /// @dev rev026: the on-chain counter tracks the same formula, so one pass also checks that
    ///      every task's booked amount equals what it owes and totalLiabilities equals their sum.
    function invariant_BalanceEqualsWhatLiveTasksOwe() public view {
        uint256 n = handler.taskCount();
        uint256 owed;
        for (uint256 i; i < n; i++) {
            bytes32 id = handler.taskIds(i);
            uint256 o = _owed(id);
            (uint256 booked, bool tracked) = market.escrowRecord(id);
            assertTrue(tracked, "every task created on rev026 is booked");
            assertEq(booked, o, "booked amount must equal what the task owes");
            owed += o;
        }
        assertEq(usdc.balanceOf(address(market)), owed, "diamond balance must equal live obligations");
        assertEq(market.totalLiabilities(), owed, "totalLiabilities must equal live obligations");
    }

    function invariant_LapsedDecisionMovesNoFunds() public view {
        assertEq(handler.lapsedViolations(), 0, "reject/cancel/refund must fail past the decision deadline");
    }

    function invariant_WinnerCapHolds() public view {
        assertEq(handler.capViolations(), 0, "acceptSubmissions must settle up to 50 winners and refuse 51");
    }

    function afterInvariant() public view {
        string[18] memory names = [
            "lapsedAttempt",
            "acceptAfterLapse",
            "winnerCapAccepted",
            "winnerCapRejected",
            "rejectSubmission",
            "createWithTerms",
            "acceptSubmission",
            "evaluate",
            "appeal",
            "finalizeVerdict",
            "resolveDispute",
            "refundExpired",
            "rejectDelivery",
            "requestRevision",
            "settleLapsedReview",
            "releaseClaim",
            "rateTask",
            "claimStaked"
        ];
        for (uint256 i; i < names.length; i++) {
            console.log(names[i], handler.calls(names[i]));
        }
    }
}
