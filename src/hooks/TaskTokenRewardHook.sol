// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { OwnableUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
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
///         trusted authorizedRelayer server wallet.
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
contract TaskTokenRewardHook is ITMPHook, OwnableUpgradeable, UUPSUpgradeable {
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
        uint64 consumedEpoch;
    }

    /// @notice All hook state, held at a fixed slot rather than in sequential storage.
    /// @dev This contract sits behind a proxy, so its storage has to survive every future
    ///      upgrade. Declared normally, Solidity assigns state to slots 0, 1, 2... in
    ///      declaration order, and inserting, reordering or removing a field silently
    ///      repoints every field after it -- including `claimable`, which is real money.
    ///
    ///      Holding it all in one struct at a fixed `keccak256` slot removes that hazard
    ///      rather than guarding it: the struct's base never moves, so appending is always
    ///      safe and there is no slot budget to track. Same pattern and same reasoning as
    ///      `AppStorage` in LibAppStorage.sol -- the Diamond adopted it because facets share
    ///      one proxy's storage, and the upgrade safety it provides is exactly what this
    ///      contract needs now that it is upgradeable.
    ///
    ///      Fields must only ever be APPENDED. Never insert, reorder, or remove.
    struct HookStorage {
        IRewardVault vault;
        EpochBudget epochBudget;
        address diamond; // TaskMarket Diamond proxy for registry lookups
        // Storage rather than immutable: an immutable lives in the implementation's code
        // rather than in proxy storage, so every upgrade would have to re-supply it
        // identically and a mismatch would be silent.
        uint8 tokenDecimals;
        // DREAMS wei per 1 USDC (1e6 base units). Pure exchange rate -- tracks market price,
        // independent of the bonus % below.
        uint256 dreamsPerUsdc;
        // USD bonus intensity in bps of task value; e.g. 500 = 5%. The tokenomics knob,
        // independent of dreamsPerUsdc.
        uint16 bonusBps;
        // Claimable escrow -- pushed here from the vault, then claimed via withdrawFor().
        mapping(address => uint256) claimable;
        // Set once on a wallet's first hook interaction, never updated. Basis for the ramp.
        mapping(address => uint40) firstSeen;
        mapping(address => bool) banned;
        // Running sum of all claimable values; guards sweepUnclaimed against over-sweeping.
        uint256 totalClaimable;
        address token; // DREAMS token
        uint16 workerSplitBps; // worker's share in bps; default 8000 = 80%
        // The server key authorized to relay withdrawals. Named to match
        // TaskMarketForwarder's `authorizedRelayer`, because it is the same address: the
        // deploy scripts read it straight off the forwarder.
        address authorizedRelayer;
        uint40[3] rampThresholds; // age breakpoints: [2 weeks, 4 weeks, 8 weeks]
        uint16[4] rampMultipliers; // multipliers in bps: [0, 2500, 5000, 10000]
        mapping(bytes32 => RewardState) rewardStates;
        // Withdrawal authorizations already spent, keyed by keccak256(wallet, nonce). Keyed
        // by wallet as well as nonce so two wallets cannot collide on a shared nonce.
        mapping(bytes32 => bool) usedWithdrawNonce;
        // One-way: once true, wallet history can never be seeded again.
        bool walletHistorySealed;
        // One-way: once true, in-flight reward state can never be seeded again.
        bool rewardStateSealed;
    }

    bytes32 private constant HOOK_STORAGE_SLOT = keccak256("taskmarket.tokenrewardhook.storage.v1");

    function _s() private pure returns (HookStorage storage hs) {
        bytes32 slot = HOOK_STORAGE_SLOT;
        assembly {
            hs.slot := slot
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public getters
    //
    // Hand-written because struct fields generate none. Signatures are exactly those the
    // compiler produced for the previous public variables, so the ABI is unchanged and no
    // caller -- backend, script, or test -- has to know the storage moved.
    // ─────────────────────────────────────────────────────────────────────────

    function vault() external view returns (IRewardVault) {
        return _s().vault;
    }

    function epochBudget() external view returns (EpochBudget) {
        return _s().epochBudget;
    }

    function diamond() external view returns (address) {
        return _s().diamond;
    }

    function tokenDecimals() external view returns (uint8) {
        return _s().tokenDecimals;
    }

    function dreamsPerUsdc() external view returns (uint256) {
        return _s().dreamsPerUsdc;
    }

    function bonusBps() external view returns (uint16) {
        return _s().bonusBps;
    }

    function claimable(address wallet) external view returns (uint256) {
        return _s().claimable[wallet];
    }

    function firstSeen(address wallet) external view returns (uint40) {
        return _s().firstSeen[wallet];
    }

    function banned(address wallet) external view returns (bool) {
        return _s().banned[wallet];
    }

    function totalClaimable() external view returns (uint256) {
        return _s().totalClaimable;
    }

    function token() external view returns (address) {
        return _s().token;
    }

    function workerSplitBps() external view returns (uint16) {
        return _s().workerSplitBps;
    }

    function authorizedRelayer() external view returns (address) {
        return _s().authorizedRelayer;
    }

    function rampThresholds(uint256 index) external view returns (uint40) {
        return _s().rampThresholds[index];
    }

    function rampMultipliers(uint256 index) external view returns (uint16) {
        return _s().rampMultipliers[index];
    }

    function rewardStates(bytes32 taskId)
        external
        view
        returns (
            uint256 rewardUsd,
            uint256 usdBonusValue,
            uint256 startPrice,
            uint256 reservedTokenAmount,
            address requester,
            address worker,
            bool reserved,
            bool paid,
            uint64 consumedEpoch
        )
    {
        RewardState storage state = _s().rewardStates[taskId];
        return (
            state.rewardUsd,
            state.usdBonusValue,
            state.startPrice,
            state.reservedTokenAmount,
            state.requester,
            state.worker,
            state.reserved,
            state.paid,
            state.consumedEpoch
        );
    }

    function usedWithdrawNonce(bytes32 key) external view returns (bool) {
        return _s().usedWithdrawNonce[key];
    }

    function walletHistorySealed() external view returns (bool) {
        return _s().walletHistorySealed;
    }

    function rewardStateSealed() external view returns (bool) {
        return _s().rewardStateSealed;
    }

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
    event WalletBanned(address indexed wallet);
    event WalletUnbanned(address indexed wallet);
    /// Emitted once per wallet seeded from a previous hook deployment.
    event WalletHistorySeeded(address indexed wallet, uint40 firstSeenAt, bool banned);
    /// Emitted when seeding is permanently disabled. One-way.
    event WalletHistorySealed();
    /// Emitted once per task whose in-flight reward state was carried over from a previous hook.
    event RewardStateSeeded(bytes32 indexed taskId, address indexed worker, uint256 reservedTokenAmount);
    /// Emitted when reward-state seeding is permanently disabled. One-way.
    event RewardStateSealed();
    event PriceUpdated(uint256 dreamsPerUsdc);
    event BonusBpsUpdated(uint16 bonusBps);

    error ZeroAddress();
    error ZeroRate();
    error RewardAlreadyPaid(bytes32 taskId);
    error RewardNotReserved(bytes32 taskId);
    error WorkerMismatch(bytes32 taskId, address expected, address got);
    error NoWorkerFound(bytes32 taskId);
    error CallerNotDiamond();
    error UnauthorizedRelayer();
    error NothingToClaim();
    error InvalidWithdrawSignature();
    error WithdrawAuthorizationExpired();
    error WithdrawNonceUsed();
    error WalletHistoryAlreadySealed();
    error SeedLengthMismatch();
    error RewardStateAlreadySealed();
    error RewardStateAlreadySettled(bytes32 taskId);
    error InvalidBps();
    error InvalidRamp();
    error InsufficientSweepable();

    modifier onlyDiamond() {
        if (msg.sender != _s().diamond) revert CallerNotDiamond();
        _;
    }

    /// @dev The implementation is never used directly -- all state lives behind the proxy -- so
    ///      its own initializers are disabled at construction. Without this, anyone could
    ///      initialize the implementation and take ownership of it, which is harmless for state
    ///      but is a foothold for `upgradeToAndCall` on some proxy patterns.
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vault,
        address _epochBudget,
        address _diamond,
        uint8 _tokenDecimals,
        uint256 _dreamsPerUsdc,
        uint16 _bonusBps,
        address _token,
        uint16 _workerSplitBps,
        address _authorizedRelayer,
        address _owner
    ) external initializer {
        // UUPSUpgradeable holds no state of its own in this OpenZeppelin version, so it has no
        // initializer to call -- upgrade authorization is the `_authorizeUpgrade` override below.
        __Ownable_init(_owner);
        if (
            _vault == address(0) || _epochBudget == address(0) || _diamond == address(0) || _token == address(0)
                || _authorizedRelayer == address(0)
        ) revert ZeroAddress();
        if (_dreamsPerUsdc == 0) revert ZeroRate();
        if (_bonusBps > 10000) revert InvalidBps();
        if (_workerSplitBps > 10000) revert InvalidBps();

        _s().vault = IRewardVault(_vault);
        _s().epochBudget = EpochBudget(_epochBudget);
        _s().diamond = _diamond;
        _s().tokenDecimals = _tokenDecimals;
        _s().dreamsPerUsdc = _dreamsPerUsdc;
        _s().bonusBps = _bonusBps;
        _s().token = _token;
        _s().workerSplitBps = _workerSplitBps;
        _s().authorizedRelayer = _authorizedRelayer;
        _s().rampThresholds = [uint40(2 weeks), uint40(4 weeks), uint40(8 weeks)];
        _s().rampMultipliers = [uint16(0), uint16(2500), uint16(5000), uint16(10000)];
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

        _s().rewardStates[taskId] = RewardState({
            rewardUsd: ctx.reward,
            usdBonusValue: 0,
            startPrice: 0,
            reservedTokenAmount: 0,
            requester: ctx.requester,
            worker: address(0),
            reserved: false,
            paid: false,
            consumedEpoch: 0
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
        RewardState storage state = _s().rewardStates[taskId];
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

    /// @notice Atomic _s().token credit at task completion.
    ///         Tokens are transferred from the _s().vault to this hook, then credited to
    ///         _s().claimable balances for the worker and requester according to _s().workerSplitBps
    ///         and the wallet-age ramp. Ramp-discounted tokens remain in hook balance
    ///         and are recoverable via sweepUnclaimed.
    ///
    ///         Path A (reserved): the rate and bonus % were locked at reserve time, so the
    ///                            _s().token amount is deterministic — pay exactly
    ///                            state.reservedTokenAmount.
    ///         Path B (Bounty):   pay each winner proportionally using verdict.awards, at the
    ///                            current _s().dreamsPerUsdc rate and _s().bonusBps. Skips the _s().token
    ///                            bonus gracefully if no rate/bonus is configured or
    ///                            _s().vault/budget is exhausted — the USDC payout is never blocked.
    function checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict)
        external
        override
        onlyDiamond
        returns (bool)
    {
        RewardState storage state = _s().rewardStates[taskId];

        if (state.paid) revert RewardAlreadyPaid(taskId);

        // Effects before interactions: mark paid up front so a _s().token-transfer
        // callback cannot re-enter and double-pay.
        state.paid = true;

        if (state.reserved) {
            // Path A — Claim / Pitch / Auction
            // Rate and USD budget were already locked/consumed at reserve time
            // (_reserveForWorker), so the payout is exactly the reserved amount.
            uint256 tokenReward = state.reservedTokenAmount;
            if (tokenReward == 0) return true; // no rate at reserve time or reservation failed

            // Transfer tokens from _s().vault to this hook; on failure release the reserve and
            // let the USDC payout proceed rather than blocking settlement.
            bool paid = false;
            try _s().vault.pay(taskId, address(this), tokenReward) {
                paid = true;
            } catch { }

            if (!paid) {
                try _s().vault.release(taskId, tokenReward) { } catch { }
                try _s().epochBudget
                    .release(state.requester, state.worker, state.usdBonusValue, state.consumedEpoch) { }
                    catch { }
                return true;
            }

            _creditWithSplit(state.requester, state.worker, tokenReward);
            emit RewardPaid(taskId, state.worker, state.rewardUsd, state.usdBonusValue, state.startPrice, tokenReward);
        } else {
            // Path B — Bounty (no pre-reservation): pay each winner proportionally.
            // If no rate or bonus is configured, skip the _s().token bonus; USDC payout is not blocked.
            uint256 rate = _s().dreamsPerUsdc;
            uint256 bonus = _s().bonusBps;
            if (rate == 0 || bonus == 0) return true;
            if (verdict.awards.length == 0) revert NoWorkerFound(taskId);

            for (uint256 i; i < verdict.awards.length; i++) {
                address worker = verdict.awards[i].worker;
                _touchFirstSeen(worker);
                // Use per-winner pre-fee USDC amount as the task-value basis, then apply
                // the USD bonus % to get the actual USD value converted to tokens.
                uint256 workerUsd = verdict.awards[i].amount;
                uint256 workerBonusUsd = workerUsd * bonus / 10000;
                uint256 budgetRemaining = _s().epochBudget.remaining(ctx.requester, worker);
                uint256 taskCapUsd = _s().epochBudget.maxUsdPerTask();
                uint256 cappedUsd = _min3(workerBonusUsd, budgetRemaining, taskCapUsd);
                if (cappedUsd == 0) continue; // budget exhausted; skip for this worker

                uint256 tokenReward = cappedUsd * rate / 1e6;
                uint256 vaultAvail = _s().vault.available();
                if (tokenReward > vaultAvail) {
                    // Vault can't cover the full USD-capped amount; scale down and
                    // recompute the USD amount actually being consumed so budget
                    // accounting stays consistent with what is actually paid out.
                    // Intentional round-trip (divide then multiply then divide): the
                    // _s().token amount is the true constraint here, and the tiny rounding
                    // loss only ever under-consumes budget, never over-consumes it.
                    tokenReward = vaultAvail;
                    // slither-disable-next-line divide-before-multiply
                    cappedUsd = tokenReward * 1e6 / rate;
                    if (cappedUsd == 0 || tokenReward == 0) continue;
                }

                // TOCTOU guard: remaining() was read above but the budget may have been
                // exhausted by a concurrent call before checkAndConsume runs. Wrap in
                // try-catch so an unexpected revert silently skips the _s().token reward
                // instead of reverting checkComplete and blocking the USDC payout.
                //
                // Ordering note: EpochBudget state is committed here BEFORE the _s().token
                // transfer in _s().vault.payDirect below. This is intentionally NOT
                // checks-effects-interactions-safe against the paid _s().token itself — if
                // `_s().token` were ever an ERC777-style callback _s().token, a malicious worker
                // contract's receive-hook could reenter between this consume and the
                // credit below with budget already spent but tokens not yet accounted
                // for locally. This is safe today only because: (1) `_s().token` is
                // immutable and assumed to be a plain, non-callback ERC20 for the
                // lifetime of this contract, (2) `_s().vault`/`_s().epochBudget` are onlyHook-
                // gated so a reentrant call can't touch them directly, and (3) this
                // whole call executes inside the Diamond's own reentrancy guard, so a
                // reentrant call back into any Diamond-facing function reverts. If
                // `_s().token` is ever changed to a callback-capable _s().token, this ordering
                // must be revisited.
                uint64 consumeEpoch = 0;
                try _s().epochBudget.checkAndConsume(ctx.requester, worker, cappedUsd) returns (uint64 epoch) {
                    consumeEpoch = epoch;
                } catch {
                    continue;
                }

                bool tokenPaid = false;
                // _s().vault is a trusted internal contract; hook is called inside Diamond reentrancy guard
                // slither-disable-next-line reentrancy-no-eth
                try _s().vault.payDirect(address(this), tokenReward) {
                    tokenPaid = true;
                } catch { }
                if (tokenPaid) {
                    _creditWithSplit(ctx.requester, worker, tokenReward);
                    emit RewardPaid(taskId, worker, workerUsd, cappedUsd, rate, tokenReward);
                } else {
                    try _s().epochBudget.release(ctx.requester, worker, cappedUsd, consumeEpoch) { } catch { }
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
        RewardState storage state = _s().rewardStates[taskId];
        if (state.reserved && !state.paid && state.reservedTokenAmount > 0) {
            try _s().vault.release(taskId, state.reservedTokenAmount) { } catch { }
            try _s().epochBudget.release(state.requester, state.worker, state.usdBonusValue, state.consumedEpoch) { }
                catch { }
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
    ///         Only callable by the trusted _s().authorizedRelayer address.
    /// @notice Withdraw a wallet's _s().claimable balance to `destination`, relayed by the _s().authorizedRelayer.
    /// @dev The _s().authorizedRelayer relays and pays gas, so `msg.sender` is never the wallet and cannot
    ///      authorize anything on its own. Authorization is the wallet's own signature over
    ///      (destination, nonce, validBefore), verified here rather than taken on trust.
    ///
    ///      Before this, `msg.sender == _s().authorizedRelayer` was the only check: the contract never
    ///      verified that `destination` had anything to do with `wallet`. The _s().authorizedRelayer did
    ///      enforce that binding off-chain, so this was not exploitable, but it meant the
    ///      whole _s().claimable ledger rested on one hot key being correct forever -- including
    ///      in every future code path that might call this without replicating the check.
    ///
    ///      The signed message is byte-identical to the one clients already produce
    ///      (`taskmarket:withdraw-dreams:<destination>:<nonce>:<validBefore>`, EIP-191), so
    ///      no wallet, CLI or web client has to change how it signs. Reconstructing the
    ///      string on-chain costs gas that a withdrawal can afford, and buys compatibility
    ///      that an EIP-712 migration would have spent.
    ///
    ///      `_s().usedWithdrawNonce` makes replay protection on-chain rather than solely in the
    ///      _s().authorizedRelayer's database, which is the same argument one layer down: a captured
    ///      signature must not be replayable by whoever holds the relaying key.
    function withdrawFor(
        address wallet,
        address destination,
        string calldata nonce,
        uint256 validBefore,
        bytes calldata signature
    ) external {
        if (msg.sender != _s().authorizedRelayer) revert UnauthorizedRelayer();
        if (block.timestamp >= validBefore) revert WithdrawAuthorizationExpired();

        bytes32 nonceKey = keccak256(abi.encodePacked(wallet, nonce));
        if (_s().usedWithdrawNonce[nonceKey]) revert WithdrawNonceUsed();

        string memory message = string.concat(
            "taskmarket:withdraw-dreams:",
            Strings.toHexString(destination),
            ":",
            nonce,
            ":",
            Strings.toString(validBefore)
        );
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(bytes(message));
        if (ECDSA.recover(digest, signature) != wallet) revert InvalidWithdrawSignature();

        _s().usedWithdrawNonce[nonceKey] = true;

        uint256 amount = _s().claimable[wallet];
        if (amount == 0) revert NothingToClaim();
        _s().claimable[wallet] = 0;
        _s().totalClaimable -= amount;
        IERC20(_s().token).safeTransfer(destination, amount);
        emit RewardsWithdrawn(wallet, destination, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner config
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Copy `_s().firstSeen` and `_s().banned` for wallets from a previous hook deployment.
    /// @dev A swapped-in hook starts with empty storage. `_s().firstSeen` is the basis for the
    ///      wallet-age ramp, and `_s().rampMultipliers[0]` is 0, so without this every existing
    ///      wallet looks brand new and earns nothing until it ages past the first threshold
    ///      again. Bans reset the other way, which is worse: a _s().banned wallet would come back
    ///      unbanned.
    ///
    ///      Three guards, because this function writes user-visible history by decree:
    ///
    ///      1. It only ever writes where `_s().firstSeen` is still 0. A wallet that has already
    ///         interacted with this hook has real history, and real history always wins over
    ///         seeded history -- so a late or repeated seed cannot rewrite it.
    ///      2. `sealWalletHistory()` disables it permanently. Migration is a phase, not a
    ///         standing capability, and an owner key that can backdate wallet age forever is
    ///         a bigger power than the migration needs.
    ///      3. Every seeded wallet is logged, so the migration is auditable after the fact
    ///         rather than inferred from balances.
    function seedWalletHistory(address[] calldata wallets, uint40[] calldata firstSeenAt, bool[] calldata isBanned)
        external
        onlyOwner
    {
        if (_s().walletHistorySealed) revert WalletHistoryAlreadySealed();
        if (wallets.length != firstSeenAt.length || wallets.length != isBanned.length) {
            revert SeedLengthMismatch();
        }

        for (uint256 i = 0; i < wallets.length; i++) {
            address wallet = wallets[i];
            // slither-disable-next-line incorrect-equality
            if (_s().firstSeen[wallet] != 0) continue; // real history wins; never overwrite
            if (firstSeenAt[i] == 0) continue; // 0 is the "never seen" sentinel, not a value

            _s().firstSeen[wallet] = firstSeenAt[i];
            if (isBanned[i]) _s().banned[wallet] = true;

            emit WalletHistorySeeded(wallet, firstSeenAt[i], isBanned[i]);
        }
    }

    /// @notice Carry in-flight reward state for tasks reserved against a previous hook.
    /// @dev This is what makes a hook replacement possible without stranding money.
    ///
    ///      A reservation in the `RewardVault` is only ever settled by the hook calling
    ///      `_s().vault.release` or `_s().vault.pay`, and the hook only does that from a lifecycle path
    ///      that reads `_s().rewardStates[taskId]`. A replacement hook starts empty, so a task
    ///      reserved against the old hook becomes unsettleable: its tokens stay counted in
    ///      `totalReserved` forever, and because that figure gates the next swap, one stranded
    ///      reservation blocks every future one. That has already happened once on testnet --
    ///      five reservations orphaned by an earlier cutover, permanently.
    ///
    ///      Seeding the state closes that. The new hook can then settle those tasks exactly as
    ///      the old one would have, so a cutover no longer has to wait for a quiet moment that a
    ///      live marketplace never provides: pause, seed whatever is in flight, cut over, unpause.
    ///
    ///      The same three guards as `seedWalletHistory`, for the same reasons: never overwrite
    ///      a task this hook already knows about, sealable so the capability is a phase rather
    ///      than a standing power, and logged so the migration is auditable afterwards.
    ///
    ///      A `paid` state is rejected rather than skipped. Seeding one would be inert at best --
    ///      every settlement path checks `paid` first -- and at worst it is a sign the operator is
    ///      replaying the wrong set, which is worth stopping on rather than silently ignoring.
    function seedRewardStates(bytes32[] calldata taskIds, RewardState[] calldata states) external onlyOwner {
        if (_s().rewardStateSealed) revert RewardStateAlreadySealed();
        if (taskIds.length != states.length) revert SeedLengthMismatch();

        for (uint256 i = 0; i < taskIds.length; i++) {
            bytes32 taskId = taskIds[i];
            RewardState calldata incoming = states[i];

            // Real state wins over seeded state, exactly as in seedWalletHistory. `rewardUsd`
            // is the discriminator: every configured task has a non-zero reward.
            if (_s().rewardStates[taskId].rewardUsd != 0) continue;
            if (incoming.rewardUsd == 0) continue; // nothing to carry
            if (incoming.paid) revert RewardStateAlreadySettled(taskId);

            _s().rewardStates[taskId] = incoming;
            _touchFirstSeen(incoming.requester);
            if (incoming.worker != address(0)) _touchFirstSeen(incoming.worker);

            emit RewardStateSeeded(taskId, incoming.worker, incoming.reservedTokenAmount);
        }
    }

    /// @notice Permanently disable `seedRewardStates`. One-way.
    function sealRewardState() external onlyOwner {
        _s().rewardStateSealed = true;
        emit RewardStateSealed();
    }

    /// @notice Permanently disable `seedWalletHistory`. One-way.
    function sealWalletHistory() external onlyOwner {
        _s().walletHistorySealed = true;
        emit WalletHistorySealed();
    }

    /// @dev Only the owner may replace the logic that governs every wallet's balance. That is a
    ///      real concentration of power and the reason this contract was not upgradeable before:
    ///      it should sit behind whatever multisig or timelock the owner key sits behind.
    function _authorizeUpgrade(address) internal override onlyOwner { }

    function banWallet(address wallet) external onlyOwner {
        _s().banned[wallet] = true;
        emit WalletBanned(wallet);
    }

    function unbanWallet(address wallet) external onlyOwner {
        _s().banned[wallet] = false;
        emit WalletUnbanned(wallet);
    }

    function setAuthorizedRelayer(address _authorizedRelayer) external onlyOwner {
        if (_authorizedRelayer == address(0)) revert ZeroAddress();
        _s().authorizedRelayer = _authorizedRelayer;
    }

    function setWorkerSplitBps(uint16 bps) external onlyOwner {
        if (bps > 10000) revert InvalidBps();
        _s().workerSplitBps = bps;
    }

    function setRamp(uint40[3] calldata thresholds, uint16[4] calldata multipliers) external onlyOwner {
        if (thresholds[0] >= thresholds[1] || thresholds[1] >= thresholds[2]) revert InvalidRamp();
        if (
            multipliers[0] > multipliers[1] || multipliers[1] > multipliers[2] || multipliers[2] > multipliers[3]
                || multipliers[3] > 10000
        ) revert InvalidRamp();
        _s().rampThresholds = thresholds;
        _s().rampMultipliers = multipliers;
    }

    /// @notice Sweep ramp-discounted excess tokens (not owed to any wallet) to `destination`.
    ///         Cannot sweep tokens that are credited in any wallet's _s().claimable balance.
    function sweepUnclaimed(address destination, uint256 amount) external onlyOwner {
        uint256 balance = IERC20(_s().token).balanceOf(address(this));
        if (balance < _s().totalClaimable + amount) revert InsufficientSweepable();
        IERC20(_s().token).safeTransfer(destination, amount);
    }

    function setDreamsPerUsdc(uint256 _rate) external onlyOwner {
        if (_rate == 0) revert ZeroRate();
        _s().dreamsPerUsdc = _rate;
        emit PriceUpdated(_rate);
    }

    /// @notice Set the USD bonus intensity in bps of task value (e.g. 500 = 5%). This is
    ///         the tokenomics decision — independent of _s().dreamsPerUsdc, which only tracks
    ///         market price. Set to 0 to pause the DREAMS bonus without touching the rate.
    function setBonusBps(uint16 _bonusBps) external onlyOwner {
        if (_bonusBps > 10000) revert InvalidBps();
        _s().bonusBps = _bonusBps;
        emit BonusBpsUpdated(_bonusBps);
    }

    function setVault(address _vault) external onlyOwner {
        _s().vault = IRewardVault(_vault);
    }

    function setEpochBudget(address _epochBudget) external onlyOwner {
        _s().epochBudget = EpochBudget(_epochBudget);
    }

    function setDiamond(address _diamond) external onlyOwner {
        _s().diamond = _diamond;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _touchFirstSeen(address wallet) internal {
        // uint40 sentinel: 0 means "never seen"; equality is the only correct check
        // slither-disable-next-line incorrect-equality
        if (_s().firstSeen[wallet] == 0) _s().firstSeen[wallet] = uint40(block.timestamp);
    }

    function _ageMultiplierBps(address wallet) internal view returns (uint256) {
        uint40 seen = _s().firstSeen[wallet];
        // uint40 sentinel: 0 means "never seen"; equality is the only correct check
        // slither-disable-next-line incorrect-equality
        if (seen == 0) return 0;
        uint256 age = block.timestamp - uint256(seen);
        if (age < _s().rampThresholds[0]) return _s().rampMultipliers[0];
        if (age < _s().rampThresholds[1]) return _s().rampMultipliers[1];
        if (age < _s().rampThresholds[2]) return _s().rampMultipliers[2];
        return _s().rampMultipliers[3];
    }

    function _creditWithSplit(address requester, address worker, uint256 total) internal {
        uint256 workerAmt = total * _s().workerSplitBps / 10000;
        uint256 requesterAmt = total - workerAmt;
        uint256 credited = 0;
        if (!_s().banned[worker]) {
            // intentional two-step bps scaling: split first, then apply age multiplier
            // slither-disable-next-line divide-before-multiply
            uint256 w = workerAmt * _ageMultiplierBps(worker) / 10000;
            _s().claimable[worker] += w;
            credited += w;
        }
        if (!_s().banned[requester]) {
            // intentional two-step bps scaling: split first, then apply age multiplier
            // slither-disable-next-line divide-before-multiply
            uint256 r = requesterAmt * _ageMultiplierBps(requester) / 10000;
            _s().claimable[requester] += r;
            credited += r;
        }
        _s().totalClaimable += credited;
        // ramp-discounted remainder (total - credited) stays in hook balance;
        // recoverable by owner via sweepUnclaimed.
    }

    function _reserveForWorker(bytes32 taskId, address requester, address worker) internal returns (bool) {
        RewardState storage state = _s().rewardStates[taskId];

        // Guard against double-reservation: a task can return to Open after already
        // being reserved once (e.g. EvaluatorFacet.finalizeVerdict's REJECT branch
        // reopens a claimed task without calling any reward-hook release path), and
        // then be claimed/selected again. Release any stale reservation first so the
        // _s().vault and EpochBudget accounting for the old worker never gets orphaned or
        // double-consumed when this function reserves fresh for the new worker below.
        // _s().vault.release/_s().epochBudget.release are pure internal-accounting calls on
        // trusted owner-set contracts (no _s().token transfer, no calls to attacker-
        // controlled addresses), so the state writes further below in this function
        // being "after" this external call is not an exploitable reentrancy path.
        if (state.reserved && !state.paid) {
            // slither-disable-next-line reentrancy-no-eth
            _releaseReserve(taskId);
        }

        uint256 rate = _s().dreamsPerUsdc;
        // intentional two-step bps scaling: bonusUsd is a real checkpoint value (stored
        // in state.usdBonusValue and consumed against EpochBudget independently of the
        // _s().token conversion below), not an algebraic simplification opportunity.
        // slither-disable-next-line divide-before-multiply
        uint256 bonusUsd = state.rewardUsd * _s().bonusBps / 10000;
        state.startPrice = rate;
        state.usdBonusValue = bonusUsd;
        state.worker = worker;
        state.reserved = true;
        state.reservedTokenAmount = 0;

        if (rate == 0 || bonusUsd == 0) {
            // No rate/bonus configured — no _s().token reward owed, but USDC flow is never blocked.
            emit RewardReserved(taskId, worker, rate, 0);
            return true;
        }

        uint256 tokenAmount = bonusUsd * rate / 1e6;

        // TOCTOU guard: budget may be exhausted between remaining() and checkAndConsume.
        // reservedTokenAmount stays 0 on failure so no _s().token reward is owed without
        // blocking USDC payout. If _s().vault.reserve() itself reverts (insufficient _s().vault
        // balance), that propagates and reverts the whole claim/select-worker call —
        // consistent with _s().epochBudget's consumption being rolled back too. _s().epochBudget
        // is a trusted owner-set contract with no callback mechanism, so the
        // reentrancy-no-eth finding is a false positive.
        // slither-disable-next-line reentrancy-no-eth
        try _s().epochBudget.checkAndConsume(requester, worker, bonusUsd) returns (uint64 epoch) {
            state.reservedTokenAmount = tokenAmount;
            state.consumedEpoch = epoch;
            _s().vault.reserve(taskId, tokenAmount);
        } catch { }

        emit RewardReserved(taskId, worker, rate, state.reservedTokenAmount);
        return true;
    }

    function _releaseReserve(bytes32 taskId) internal {
        RewardState storage state = _s().rewardStates[taskId];
        if (!state.reserved || state.paid || state.reservedTokenAmount == 0) return;
        uint256 tokenAmount = state.reservedTokenAmount;
        uint256 usdAmount = state.usdBonusValue;
        // Clear state before external calls to prevent double-release on re-entry or
        // a second terminal dispatch emitting a phantom RewardReserveReleased event.
        state.reserved = false;
        state.reservedTokenAmount = 0;
        try _s().vault.release(taskId, tokenAmount) { } catch { }
        try _s().epochBudget.release(state.requester, state.worker, usdAmount, state.consumedEpoch) { } catch { }
        emit RewardReserveReleased(taskId, tokenAmount);
    }

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        uint256 ab = a < b ? a : b;
        return ab < c ? ab : c;
    }
}
