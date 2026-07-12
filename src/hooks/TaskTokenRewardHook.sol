// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ITMPHook } from "../interfaces/ITMPHook.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { IRewardVault } from "../interfaces/IRewardVault.sol";
import { EpochBudget } from "./EpochBudget.sol";

/// @title TaskTokenRewardHook
/// @notice Hook that credits DREAMS tokens to workers and requesters on task completion.
///         Two independent admin-set knobs determine the payout:
///           1. `bonusBps`     — the reward INTENSITY, expressed as a % of a task's USD
///                               value (e.g. 500 = 5%). This is the tokenomics decision
///                               (how generous the incentive is) and should stay stable.
///           2. `dreamsPerUsdc` — the pure DREAMS/USDC EXCHANGE RATE, tracking market
///                               price. Updating this to stay accurate as DREAMS' price
///                               moves does NOT change the effective bonus %, because the
///                               two are applied as separate steps:
///
///                                 usdBonusValue = rewardUsd * bonusBps / 10000
///                                 tokenReward   = usdBonusValue * dreamsPerUsdc / 1e6
///
///         Tokens are held in the hook as claimable escrow rather than pushed to wallets
///         immediately. Workers and requesters withdraw via `withdrawFor` called by the
///         trusted backend server wallet.
///
///         A wallet-age ramp limits rewards for new wallets, reducing incentive for Sybil
///         farming. Workers receive `workerSplitBps / 10000` of the reward; requesters
///         receive the remainder.
///
///         For Claim / Pitch / Auction tasks: bonusBps and rate both lock when the worker
///         is selected, tokens are reserved from the vault, and credited atomically at
///         completion.
///
///         For Bounty tasks: bonusBps, rate, and payment all happen atomically at
///         completion with no pre-reservation.
contract TaskTokenRewardHook is ITMPHook, Ownable {
    using SafeERC20 for IERC20;

    struct RewardState {
        uint256 rewardUsd; // USDC 6-decimal amount (= task reward)
        uint256 usdBonusValue; // rewardUsd * bonusBps/10000 at lock time; the USD basis
        // actually converted to tokens and consumed against EpochBudget caps
        uint256 startPrice; // dreamsPerUsdc snapshot at lock time (DREAMS wei per 1 USDC); 0 for bounty/unreserved
        uint256 reservedTokenAmount; // tokens reserved from vault (Path A only)
        address requester;
        address worker;
        bool reserved; // true for Claim/Pitch/Auction (pre-reserved)
        bool paid;
    }

    IRewardVault public vault;
    EpochBudget public epochBudget;
    address public diamond; // TaskMarket Diamond proxy for registry lookups
    uint8 public immutable tokenDecimals;

    // DREAMS wei per 1 USDC (1e6 base units), admin-settable. e.g. 347e18 = 347 DREAMS per $1.
    // Pure exchange rate — tracks market price, independent of the bonus % below.
    uint256 public dreamsPerUsdc;

    // USD bonus intensity in bps of task value; e.g. 500 = 5%. This is the tokenomics
    // knob (how generous the DREAMS incentive is) — independent of dreamsPerUsdc.
    uint16 public bonusBps;

    // Claimable escrow — tokens are pushed here from the vault, then claimed by wallets
    // via withdrawFor() called by the trusted backend.
    mapping(address => uint256) public claimable;
    // firstSeen is set once on a wallet's first hook interaction and never updated.
    // It is the basis for the wallet-age ramp.
    mapping(address => uint40) public firstSeen;
    mapping(address => bool) public banned;
    // Running sum of all claimable[] values; guards sweepUnclaimed against over-sweeping.
    uint256 public totalClaimable;
    address public immutable token; // DREAMS token
    uint16 public workerSplitBps; // worker's share in bps; default 8000 = 80%
    address public backend; // trusted caller for withdrawFor
    uint40[3] public rampThresholds; // age breakpoints: [2 weeks, 4 weeks, 8 weeks]
    uint16[4] public rampMultipliers; // multipliers in bps: [0, 2500, 5000, 10000]

    mapping(bytes32 => RewardState) public rewardStates;

    event RewardConfigured(bytes32 indexed taskId, uint256 rewardUsd);
    event RewardReserved(bytes32 indexed taskId, address indexed worker, uint256 startPrice, uint256 reservedAmount);
    event RewardPaid(
        bytes32 indexed taskId,
        address indexed worker,
        uint256 rewardUsd,
        uint256 usdBonusValue,
        uint256 price,
        uint256 tokenAmount
    );
    event RewardReserveReleased(bytes32 indexed taskId, uint256 releasedAmount);
    event RewardsWithdrawn(address indexed wallet, address indexed destination, uint256 amount);
    event PriceUpdated(uint256 dreamsPerUsdc);
    event BonusBpsUpdated(uint16 bonusBps);

    error ZeroAddress();
    error ZeroRate();
    error RewardAlreadyPaid(bytes32 taskId);
    error RewardNotReserved(bytes32 taskId);
    error WorkerMismatch(bytes32 taskId, address expected, address got);
    error NoWorkerFound(bytes32 taskId);
    error CallerNotDiamond();
    error NotBackend();
    error NothingToClaim();
    error InvalidBps();
    error InvalidRamp();
    error InsufficientSweepable();

    modifier onlyDiamond() {
        if (msg.sender != diamond) revert CallerNotDiamond();
        _;
    }

    constructor(
        address _vault,
        address _epochBudget,
        address _diamond,
        uint8 _tokenDecimals,
        uint256 _dreamsPerUsdc,
        uint16 _bonusBps,
        address _token,
        uint16 _workerSplitBps,
        address _backend,
        address _owner
    ) Ownable(_owner) {
        if (
            _vault == address(0) || _epochBudget == address(0) || _diamond == address(0) || _token == address(0)
                || _backend == address(0)
        ) revert ZeroAddress();
        if (_dreamsPerUsdc == 0) revert ZeroRate();
        if (_bonusBps > 10000) revert InvalidBps();
        if (_workerSplitBps > 10000) revert InvalidBps();

        vault = IRewardVault(_vault);
        epochBudget = EpochBudget(_epochBudget);
        diamond = _diamond;
        tokenDecimals = _tokenDecimals;
        dreamsPerUsdc = _dreamsPerUsdc;
        bonusBps = _bonusBps;
        token = _token;
        workerSplitBps = _workerSplitBps;
        backend = _backend;
        rampThresholds = [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)];
        rampMultipliers = [uint16(0), uint16(2500), uint16(5000), uint16(10000)];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ITMPHook — check hooks (revert to block, return false not used)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Validate config at task creation and store initial state.
    ///         hookData is ignored — all config lives on this contract.
    function checkFund(
        bytes32 taskId,
        ITMPCore.TaskContext calldata ctx,
        bytes calldata /* hookData */
    )
        external
        override
        onlyDiamond
        returns (bool)
    {
        _touchFirstSeen(ctx.requester);

        rewardStates[taskId] = RewardState({
            rewardUsd: ctx.reward,
            usdBonusValue: 0,
            startPrice: 0,
            reservedTokenAmount: 0,
            requester: ctx.requester,
            worker: address(0),
            reserved: false,
            paid: false
        });

        emit RewardConfigured(taskId, ctx.reward);
        return true;
    }

    /// @notice Lock price and reserve max tokens when a worker claims (Claim mode).
    function checkClaim(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external
        override
        onlyDiamond
        returns (bool)
    {
        _touchFirstSeen(worker);
        return _reserveForWorker(taskId, ctx.requester, worker);
    }

    /// @notice Lock price and reserve max tokens when a worker is selected (Pitch/Auction).
    function checkSelectWorker(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external
        override
        onlyDiamond
        returns (bool)
    {
        _touchFirstSeen(worker);
        return _reserveForWorker(taskId, ctx.requester, worker);
    }

    /// @notice For reserved tasks, verify the submitting worker matches the locked worker.
    function checkSubmit(
        bytes32 taskId,
        ITMPCore.TaskContext calldata,
        /* ctx */
        address worker,
        bytes32 /* deliverableHash */
    )
        external
        view
        override
        onlyDiamond
        returns (bool)
    {
        RewardState storage state = rewardStates[taskId];
        if (state.reserved && state.worker != worker) {
            revert WorkerMismatch(taskId, state.worker, worker);
        }
        return true;
    }

    /// @notice Not used — return true.
    function checkEvaluate(
        bytes32,
        /* taskId */
        ITMPCore.TaskContext calldata,
        /* ctx */
        address /* evaluator */
    )
        external
        view
        override
        onlyDiamond
        returns (bool)
    {
        return true;
    }

    /// @notice Atomic token credit at task completion.
    ///         Tokens are transferred from the vault to this hook, then credited to
    ///         claimable balances for the worker and requester according to workerSplitBps
    ///         and the wallet-age ramp. Ramp-discounted tokens remain in hook balance
    ///         and are recoverable via sweepUnclaimed.
    ///
    ///         Path A (reserved): the rate and bonus % were locked at reserve time, so the
    ///                            token amount is deterministic — pay exactly
    ///                            state.reservedTokenAmount.
    ///         Path B (Bounty):   pay each winner proportionally using verdict.awards, at the
    ///                            current dreamsPerUsdc rate and bonusBps. Skips the token
    ///                            bonus gracefully if no rate/bonus is configured or
    ///                            vault/budget is exhausted — the USDC payout is never blocked.
    function checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        external
        override
        onlyDiamond
        returns (bool)
    {
        RewardState storage state = rewardStates[taskId];

        if (state.paid) revert RewardAlreadyPaid(taskId);

        // Effects before interactions: mark paid up front so a token-transfer
        // callback cannot re-enter and double-pay.
        state.paid = true;

        if (state.reserved) {
            // Path A — Claim / Pitch / Auction
            // Rate and USD budget were already locked/consumed at reserve time
            // (_reserveForWorker), so the payout is exactly the reserved amount.
            uint256 tokenReward = state.reservedTokenAmount;
            if (tokenReward == 0) return true; // no rate at reserve time or reservation failed

            // Transfer tokens from vault to this hook; on failure release the reserve and
            // let the USDC payout proceed rather than blocking settlement.
            bool paid = false;
            try vault.pay(taskId, address(this), tokenReward) {
                paid = true;
            } catch { }

            if (!paid) {
                try vault.release(taskId, tokenReward) { } catch { }
                try epochBudget.release(state.requester, state.worker, state.usdBonusValue) { } catch { }
                return true;
            }

            _creditWithSplit(state.requester, state.worker, tokenReward);
            emit RewardPaid(taskId, state.worker, state.rewardUsd, state.usdBonusValue, state.startPrice, tokenReward);
        } else {
            // Path B — Bounty (no pre-reservation): pay each winner proportionally.
            // If no rate or bonus is configured, skip the token bonus; USDC payout is not blocked.
            uint256 rate = dreamsPerUsdc;
            uint256 bonus = bonusBps;
            if (rate == 0 || bonus == 0) return true;
            if (verdict.awards.length == 0) revert NoWorkerFound(taskId);

            for (uint256 i; i < verdict.awards.length; i++) {
                address worker = verdict.awards[i].worker;
                _touchFirstSeen(worker);
                // Use per-winner pre-fee USDC amount as the task-value basis, then apply
                // the USD bonus % to get the actual USD value converted to tokens.
                uint256 workerUsd = verdict.awards[i].amount;
                uint256 workerBonusUsd = workerUsd * bonus / 10000;
                uint256 budgetRemaining = epochBudget.remaining(ctx.requester, worker);
                uint256 taskCapUsd = epochBudget.maxUsdPerTask();
                uint256 cappedUsd = _min3(workerBonusUsd, budgetRemaining, taskCapUsd);
                if (cappedUsd == 0) continue; // budget exhausted; skip for this worker

                uint256 tokenReward = cappedUsd * rate / 1e6;
                uint256 vaultAvail = vault.available();
                if (tokenReward > vaultAvail) {
                    // Vault can't cover the full USD-capped amount; scale down and
                    // recompute the USD amount actually being consumed so budget
                    // accounting stays consistent with what is actually paid out.
                    // Intentional round-trip (divide then multiply then divide): the
                    // token amount is the true constraint here, and the tiny rounding
                    // loss only ever under-consumes budget, never over-consumes it.
                    tokenReward = vaultAvail;
                    // slither-disable-next-line divide-before-multiply
                    cappedUsd = tokenReward * 1e6 / rate;
                    if (cappedUsd == 0 || tokenReward == 0) continue;
                }

                // TOCTOU guard: remaining() was read above but the budget may have been
                // exhausted by a concurrent call before checkAndConsume runs. Wrap in
                // try-catch so an unexpected revert silently skips the token reward
                // instead of reverting checkComplete and blocking the USDC payout.
                //
                // Ordering note: EpochBudget state is committed here BEFORE the token
                // transfer in vault.payDirect below. This is intentionally NOT
                // checks-effects-interactions-safe against the paid token itself — if
                // `token` were ever an ERC777-style callback token, a malicious worker
                // contract's receive-hook could reenter between this consume and the
                // credit below with budget already spent but tokens not yet accounted
                // for locally. This is safe today only because: (1) `token` is
                // immutable and assumed to be a plain, non-callback ERC20 for the
                // lifetime of this contract, (2) `vault`/`epochBudget` are onlyHook-
                // gated so a reentrant call can't touch them directly, and (3) this
                // whole call executes inside the Diamond's own reentrancy guard, so a
                // reentrant call back into any Diamond-facing function reverts. If
                // `token` is ever changed to a callback-capable token, this ordering
                // must be revisited.
                try epochBudget.checkAndConsume(ctx.requester, worker, cappedUsd) {
                // consume succeeded — vault payment follows below
                }
                catch {
                    continue;
                }

                bool tokenPaid = false;
                // vault is a trusted internal contract; hook is called inside Diamond reentrancy guard
                // slither-disable-next-line reentrancy-no-eth
                try vault.payDirect(address(this), tokenReward) {
                    tokenPaid = true;
                } catch { }
                if (tokenPaid) {
                    _creditWithSplit(ctx.requester, worker, tokenReward);
                    emit RewardPaid(taskId, worker, workerUsd, cappedUsd, rate, tokenReward);
                } else {
                    try epochBudget.release(ctx.requester, worker, cappedUsd) { } catch { }
                }
            }
        }

        return true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ITMPHook — on hooks (try-catch wrapped by Diamond, must not revert)
    // ─────────────────────────────────────────────────────────────────────────

    function onComplete(
        bytes32 taskId,
        ITMPCore.TaskContext calldata,
        /* ctx */
        ITMPCore.Verdict calldata /* verdict */
    )
        external
        override
        onlyDiamond
    {
        // Payment was already handled in checkComplete. Defensive: if somehow
        // reserved but not paid, release the reserve.
        RewardState storage state = rewardStates[taskId];
        if (state.reserved && !state.paid && state.reservedTokenAmount > 0) {
            try vault.release(taskId, state.reservedTokenAmount) { } catch { }
            try epochBudget.release(state.requester, state.worker, state.usdBonusValue) { } catch { }
            emit RewardReserveReleased(taskId, state.reservedTokenAmount);
        }
    }

    function onForfeit(
        bytes32 taskId,
        ITMPCore.TaskContext calldata,
        /* ctx */
        address /* worker */
    )
        external
        override
        onlyDiamond
    {
        _releaseReserve(taskId);
    }

    function onCancel(
        bytes32 taskId,
        ITMPCore.TaskContext calldata /* ctx */
    )
        external
        override
        onlyDiamond
    {
        _releaseReserve(taskId);
    }

    function onExpire(
        bytes32 taskId,
        ITMPCore.TaskContext calldata /* ctx */
    )
        external
        override
        onlyDiamond
    {
        _releaseReserve(taskId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC-165
    // ─────────────────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITMPHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Claimable escrow
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Transfer a wallet's accumulated DREAMS rewards to `destination`.
    ///         Only callable by the trusted backend address.
    function withdrawFor(address wallet, address destination) external {
        if (msg.sender != backend) revert NotBackend();
        uint256 amount = claimable[wallet];
        if (amount == 0) revert NothingToClaim();
        claimable[wallet] = 0;
        totalClaimable -= amount;
        IERC20(token).safeTransfer(destination, amount);
        emit RewardsWithdrawn(wallet, destination, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner config
    // ─────────────────────────────────────────────────────────────────────────

    function banWallet(address wallet) external onlyOwner {
        banned[wallet] = true;
    }

    function unbanWallet(address wallet) external onlyOwner {
        banned[wallet] = false;
    }

    function setBackend(address _backend) external onlyOwner {
        if (_backend == address(0)) revert ZeroAddress();
        backend = _backend;
    }

    function setWorkerSplitBps(uint16 bps) external onlyOwner {
        if (bps > 10000) revert InvalidBps();
        workerSplitBps = bps;
    }

    function setRamp(uint40[3] calldata thresholds, uint16[4] calldata multipliers) external onlyOwner {
        if (thresholds[0] >= thresholds[1] || thresholds[1] >= thresholds[2]) revert InvalidRamp();
        if (
            multipliers[0] > multipliers[1] || multipliers[1] > multipliers[2] || multipliers[2] > multipliers[3]
                || multipliers[3] > 10000
        ) revert InvalidRamp();
        rampThresholds = thresholds;
        rampMultipliers = multipliers;
    }

    /// @notice Sweep ramp-discounted excess tokens (not owed to any wallet) to `destination`.
    ///         Cannot sweep tokens that are credited in any wallet's claimable balance.
    function sweepUnclaimed(address destination, uint256 amount) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < totalClaimable + amount) revert InsufficientSweepable();
        IERC20(token).safeTransfer(destination, amount);
    }

    function setDreamsPerUsdc(uint256 _rate) external onlyOwner {
        if (_rate == 0) revert ZeroRate();
        dreamsPerUsdc = _rate;
        emit PriceUpdated(_rate);
    }

    /// @notice Set the USD bonus intensity in bps of task value (e.g. 500 = 5%). This is
    ///         the tokenomics decision — independent of dreamsPerUsdc, which only tracks
    ///         market price. Set to 0 to pause the DREAMS bonus without touching the rate.
    function setBonusBps(uint16 _bonusBps) external onlyOwner {
        if (_bonusBps > 10000) revert InvalidBps();
        bonusBps = _bonusBps;
        emit BonusBpsUpdated(_bonusBps);
    }

    function setVault(address _vault) external onlyOwner {
        vault = IRewardVault(_vault);
    }

    function setEpochBudget(address _epochBudget) external onlyOwner {
        epochBudget = EpochBudget(_epochBudget);
    }

    function setDiamond(address _diamond) external onlyOwner {
        diamond = _diamond;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _touchFirstSeen(address wallet) internal {
        // uint40 sentinel: 0 means "never seen"; equality is the only correct check
        // slither-disable-next-line incorrect-equality
        if (firstSeen[wallet] == 0) firstSeen[wallet] = uint40(block.timestamp);
    }

    function _ageMultiplierBps(address wallet) internal view returns (uint256) {
        uint40 seen = firstSeen[wallet];
        // uint40 sentinel: 0 means "never seen"; equality is the only correct check
        // slither-disable-next-line incorrect-equality
        if (seen == 0) return 0;
        uint256 age = block.timestamp - uint256(seen);
        if (age < rampThresholds[0]) return rampMultipliers[0];
        if (age < rampThresholds[1]) return rampMultipliers[1];
        if (age < rampThresholds[2]) return rampMultipliers[2];
        return rampMultipliers[3];
    }

    function _creditWithSplit(address requester, address worker, uint256 total) internal {
        uint256 workerAmt = total * workerSplitBps / 10000;
        uint256 requesterAmt = total - workerAmt;
        uint256 credited = 0;
        if (!banned[worker]) {
            // intentional two-step bps scaling: split first, then apply age multiplier
            // slither-disable-next-line divide-before-multiply
            uint256 w = workerAmt * _ageMultiplierBps(worker) / 10000;
            claimable[worker] += w;
            credited += w;
        }
        if (!banned[requester]) {
            // intentional two-step bps scaling: split first, then apply age multiplier
            // slither-disable-next-line divide-before-multiply
            uint256 r = requesterAmt * _ageMultiplierBps(requester) / 10000;
            claimable[requester] += r;
            credited += r;
        }
        totalClaimable += credited;
        // ramp-discounted remainder (total - credited) stays in hook balance;
        // recoverable by owner via sweepUnclaimed.
    }

    function _reserveForWorker(bytes32 taskId, address requester, address worker) internal returns (bool) {
        RewardState storage state = rewardStates[taskId];

        // Guard against double-reservation: a task can return to Open after already
        // being reserved once (e.g. EvaluatorFacet.finalizeVerdict's REJECT branch
        // reopens a claimed task without calling any reward-hook release path), and
        // then be claimed/selected again. Release any stale reservation first so the
        // vault and EpochBudget accounting for the old worker never gets orphaned or
        // double-consumed when this function reserves fresh for the new worker below.
        // vault.release/epochBudget.release are pure internal-accounting calls on
        // trusted owner-set contracts (no token transfer, no calls to attacker-
        // controlled addresses), so the state writes further below in this function
        // being "after" this external call is not an exploitable reentrancy path.
        if (state.reserved && !state.paid) {
            // slither-disable-next-line reentrancy-no-eth
            _releaseReserve(taskId);
        }

        uint256 rate = dreamsPerUsdc;
        // intentional two-step bps scaling: bonusUsd is a real checkpoint value (stored
        // in state.usdBonusValue and consumed against EpochBudget independently of the
        // token conversion below), not an algebraic simplification opportunity.
        // slither-disable-next-line divide-before-multiply
        uint256 bonusUsd = state.rewardUsd * bonusBps / 10000;
        state.startPrice = rate;
        state.usdBonusValue = bonusUsd;
        state.worker = worker;
        state.reserved = true;
        state.reservedTokenAmount = 0;

        if (rate == 0 || bonusUsd == 0) {
            // No rate/bonus configured — no token reward owed, but USDC flow is never blocked.
            emit RewardReserved(taskId, worker, rate, 0);
            return true;
        }

        uint256 tokenAmount = bonusUsd * rate / 1e6;

        // TOCTOU guard: budget may be exhausted between remaining() and checkAndConsume.
        // reservedTokenAmount stays 0 on failure so no token reward is owed without
        // blocking USDC payout. If vault.reserve() itself reverts (insufficient vault
        // balance), that propagates and reverts the whole claim/select-worker call —
        // consistent with epochBudget's consumption being rolled back too. epochBudget
        // is a trusted owner-set contract with no callback mechanism, so the
        // reentrancy-no-eth finding is a false positive.
        // slither-disable-next-line reentrancy-no-eth
        try epochBudget.checkAndConsume(requester, worker, bonusUsd) {
            state.reservedTokenAmount = tokenAmount;
            vault.reserve(taskId, tokenAmount);
        } catch { }

        emit RewardReserved(taskId, worker, rate, state.reservedTokenAmount);
        return true;
    }

    function _releaseReserve(bytes32 taskId) internal {
        RewardState storage state = rewardStates[taskId];
        if (!state.reserved || state.paid || state.reservedTokenAmount == 0) return;
        uint256 tokenAmount = state.reservedTokenAmount;
        uint256 usdAmount = state.usdBonusValue;
        // Clear state before external calls to prevent double-release on re-entry or
        // a second terminal dispatch emitting a phantom RewardReserveReleased event.
        state.reserved = false;
        state.reservedTokenAmount = 0;
        try vault.release(taskId, tokenAmount) { } catch { }
        try epochBudget.release(state.requester, state.worker, usdAmount) { } catch { }
        emit RewardReserveReleased(taskId, tokenAmount);
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 ab = a < b ? a : b;
        return ab < c ? ab : c;
    }
}
