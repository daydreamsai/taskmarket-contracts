# EXT-001: Token Reward Hook

**Status:** Draft
**Type:** Daydreams Extension (not a TMP protocol standard)
**Branch:** `feat/ext-001-token-reward-hook`

---

## Overview

EXT-001 rewards task contributors with Daydreams protocol tokens on top of their USDC
payment. It is implemented as an opt-in ERC-8195 hook — no core protocol changes are
required, and tasks without the hook are unaffected.

Token amounts are denominated in USD terms and converted to tokens at the market price
when a worker claims or is selected. The TWAP is read once at that point; no oracle
read occurs at completion. This removes oracle liveness from the critical payment path
and gives the worker a predictable reward from the moment they commit to the task.
Budget enforcement prevents runaway token emission through per-epoch global, per-worker,
and per-requester caps.

This is a Daydreams-specific extension. It is not part of the ERC-8195 or TMP protocol
standard and is not included in TaskMarket.sol.

---

## Contracts

| Contract | Role |
|---|---|
| `TaskTokenRewardHook` | `ITaskHook` implementation; orchestrates reservation and payment |
| `RewardVault` | Holds pre-funded protocol tokens; tracks per-task reserved balances |
| `TokenUsdOracle` | Uniswap V3 TWAP wrapper; returns validated price and harmonic mean liquidity |
| `EpochBudget` | Enforces global, per-worker, and per-requester emission caps per epoch |

All four contracts are standalone. They do not modify the TaskMarket proxy or any
existing storage.

---

## Reward Formula

The TWAP is read once when a worker claims or is selected. That price becomes `startPrice`
and is used for both the reservation and the final payment — no second oracle read occurs.

```
// rewardUsd: USD value in 6 decimals (same scale as USDC). e.g. $100 = 100_000000
// startPrice: TOKEN/USDC TWAP in 18 decimals. e.g. $0.01/token = 10_000000000000000
// rewardTokenDecimals: e.g. 18 for most ERC-20s.

tokenReward = (rewardUsd * 10^(rewardTokenDecimals + 12)) / startPrice
tokenReward = min(tokenReward, maxTokensPerTask, epochCaps)
```

The reservation matches the payment exactly — no drift buffer is needed because the
price does not change between reservation and payout.

**Worked example:** $100 USD task, TOKEN price $0.01, 18-decimal token:

```
tokenReward = (100_000000 * 10^30) / 10_000000000000000 = 10_000 tokens
reserved    = 10_000 tokens
paid        = min(10_000, maxTokensPerTask, epochCaps)
released    = reserved - paid
```

---

## hookData Encoding

`hookData` is a bare 4-byte big-endian `uint32` representing the TWAP window in seconds:

```solidity
// Encode (off-chain, e.g. CLI):
bytes memory hookData = abi.encodePacked(uint32(1800));  // 30-minute TWAP

// Decode (on-chain, in the hook):
uint32 twapWindow = uint32(bytes4(hookData));
```

Pass `bytes("")` or omit `--hook-data` to use the hook's `defaultTwapWindow`.

The bare 4-byte encoding (not `abi.encode`) avoids 28 zero bytes of padding in
calldata, saving gas on every task creation that uses the hook.

---

## Lifecycle

| Event | Hook call | Action |
|---|---|---|
| `createTask` | `checkFund` | Validates oracle is live and has sufficient liquidity. Validates `rewardUsd > 0`. Stores reward config. Does not reserve tokens — price is not locked yet. Reverts if config is invalid. |
| `claimTask` / `selectWorker` | `checkClaim` / `checkSelectWorker` | Reads TOKEN/USDC TWAP. Stores `startPrice` and `worker`. Computes `tokenReward = rewardUsd / startPrice`. Reserves `tokenReward` from vault. Reverts if oracle invalid, vault exhausted, or epoch budget insufficient. |
| `submitWork` | `checkSubmit` | Validates worker matches reserved worker. Validates reservation exists. Reverts on mismatch. |
| `evaluate` | `checkEvaluate` | No-op. |
| `acceptSubmission` / `finalizeVerdict(APPROVE)` / `resolveDispute` | `checkComplete` | Transfers reserved tokens to worker(s). Releases any remainder (epoch cap shortfall) to vault. Marks reward as paid. Reverts if not reserved, worker mismatch, transfer fails, or already paid. |
| `cancelTask` | `onCancel` | Releases full reservation to vault. |
| `refundExpired` | `onExpire` | Releases full reservation to vault. |
| `forfeitAndReopen` | `onForfeit` | Releases full reservation to vault. |

**Multi-winner path:** If `verdict.awards` is non-empty (evaluator path or
`acceptSubmissions`), tokens are split proportionally by USDC award amount. Each
winner's share passes through `EpochBudget.consume` — if the cap is exhausted, the
allowed amount (which may be zero) is paid and the remainder released.

**Direct acceptSubmission path:** If `verdict.awards` is empty (no evaluator, single
winner via `acceptSubmission`), the hook pays `worker` the full reserved amount,
subject to epoch cap.

**Bounty / Benchmark (no claim step):** These modes have no `checkClaim` or
`checkSelectWorker` call. Reservation is deferred to `checkSubmit` — the first
`submitWork` call triggers the TWAP read and reservation for that worker. If multiple
workers submit, each reserves independently; `checkComplete` pays the winner and
`onComplete` releases the others.

---

## Reward State

```solidity
struct RewardState {
    uint256 rewardUsd;          // USD value in 6 decimals
    uint256 startPrice;         // TOKEN/USDC TWAP at claim/select, 18 decimals
    uint256 reservedTokenAmount;
    address worker;
    bool    reserved;
    bool    paid;
}
```

---

## EpochBudget

`EpochBudget` enforces three independent emission caps per epoch:

| Cap | Default |
|---|---|
| Global tokens per epoch | Set at deploy |
| Per-worker tokens per epoch | `globalBudget / 10` |
| Per-requester tokens per epoch | `globalBudget / 5` |

`consume(taskId, worker, requester, requested)` returns the lesser of `requested` and
the three remaining caps, deducting atomically from all three. Returns 0 if any cap is
fully consumed. Epochs are time-based: `(block.timestamp - deployedAt) / epochDuration`.

---

## Security Considerations

**TWAP, not spot.** The oracle reads a time-weighted average price to resist
manipulation. The default window is 30 minutes; a longer window reduces manipulation
risk at the cost of price staleness.

**No oracle read at completion.** The TWAP is read once at claim/select and the result
is stored. `checkComplete` uses the stored `startPrice` — it has no oracle dependency.
A stale or manipulated oracle at completion time cannot affect payout or block task
completion.

**Reservation blocks vault exhaustion race.** Tokens are reserved at claim/select.
If the vault is exhausted after reservation but before completion, the reserved
amount is still available — it is held exclusively for this task.

**Vault exhaustion at claim reverts.** If the vault cannot cover the full reservation,
`checkClaim` / `checkSelectWorker` reverts. Workers should not be able to claim a task
they cannot be paid for. This is a hard failure, not graceful degradation.

**on* hook safety.** `onCancel`, `onExpire`, and `onForfeit` call `_safeRelease`,
which wraps `vault.release()` in try-catch and checks the `paid` flag before acting.
A malicious or buggy vault cannot block fund recovery.

**Double-release prevention.** The `paid` flag on `RewardState` is set atomically at
first settlement and checked before any subsequent vault call. Double-release is
impossible.

**Gas guard.** `checkComplete` reverts if `verdict.awards.length > 50`. This caps the
loop and prevents gas exhaustion from a malformed or adversarial awards array.

**Ownership.** `RewardVault` and `EpochBudget` are owned by the deployer EOA at deploy
time. Transfer ownership to a multisig before directing any production token funding
into the vault.

---

## Deployment

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `FORGE_REWARD_TOKEN_ADDRESS` | yes | ERC-20 protocol token address |
| `FORGE_UNISWAP_V3_POOL_ADDRESS` | yes | Uniswap V3 pool (rewardToken / USDC) |
| `FORGE_EPOCH_DURATION` | yes | Seconds per emission epoch (e.g. 604800 = 1 week) |
| `FORGE_GLOBAL_EPOCH_BUDGET` | yes | Max tokens to emit per epoch |
| `FORGE_REWARD_TOKEN_DECIMALS` | yes | Decimals of the reward token (e.g. 18) |
| `FORGE_REWARD_VAULT_INITIAL_FUNDING` | no | Tokens to transfer to vault at deploy (default 0) |
| `FORGE_DEFAULT_TWAP_WINDOW` | no | Default TWAP window seconds (default 1800) |
| `FORGE_MAX_STALENESS` | no | Max oracle staleness seconds (default 3600) |
| `FORGE_MIN_LIQUIDITY` | no | Min harmonic mean liquidity for a valid price (default 0) |
| `FORGE_WORKER_EPOCH_CAP` | no | Per-worker cap (default globalBudget / 10) |
| `FORGE_REQUESTER_EPOCH_CAP` | no | Per-requester cap (default globalBudget / 5) |
| `FORGE_MAX_TOKENS_PER_TASK` | no | Hard cap per task in token units (default unlimited) |

### Deploy

```bash
forge script script/DeployRewardHook.s.sol \
  --broadcast \
  --rpc-url base_sepolia \
  --private-key $FORGE_DEV_PRIVATE_KEY
```

After deploy, transfer `RewardVault` and `EpochBudget` ownership to a multisig, then
fund the vault with protocol tokens before directing any live task traffic to the hook.

### Post-deploy

1. Transfer `RewardVault` ownership: `vault.transferOwnership(multisig)`
2. Transfer `EpochBudget` ownership: `budget.transferOwnership(multisig)`
3. Fund vault: `rewardToken.transfer(vaultAddress, initialFunding)`
4. Add env vars to backend:
   - `REWARD_HOOK_ADDRESS` — TaskTokenRewardHook address
   - `REWARD_ORACLE_ADDRESS` — TokenUsdOracle address
5. Add env var to web:
   - `NEXT_PUBLIC_REWARD_HOOK_ADDRESS` — same TaskTokenRewardHook address

---

## Integration

Opt a task into token rewards by passing the hook address at creation:

```bash
# 30-minute TWAP window (1800 seconds = 0x00000708)
taskmarket task create \
  --mode bounty \
  --reward 100 \
  --hook 0x<TaskTokenRewardHookAddress> \
  --hook-data 0x00000708 \
  ...
```

Omit `--hook-data` to use the default TWAP window configured at deploy time.

The backend indexer subscribes to `RewardConfigured`, `RewardPaid`, and
`RewardReleased` events when `REWARD_HOOK_ADDRESS` is present. The web task detail page
shows estimated and settled token rewards when `NEXT_PUBLIC_REWARD_HOOK_ADDRESS` matches
`task.hookContract`.

---

## Implementation Plan

See the implementation plan for sequencing, test cases, backend/frontend changes, and
the full directory layout.

Contracts: `packages/contracts/src/hooks/`
Tests: `packages/contracts/test/TaskTokenRewardHook.t.sol`
Deploy script: `packages/contracts/script/DeployRewardHook.s.sol`
Backend service: `apps/backend/src/services/rewardHook.ts`
Frontend component: `apps/web/components/market/task-reward-hook.tsx`
Smoke test: `apps/backend/scripts/smoke-token-reward.ts`
