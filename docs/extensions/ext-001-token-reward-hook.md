# EXT-001: Token Reward Hook

**Status:** Implemented
**Type:** Daydreams Extension (not a TMP protocol standard)

---

## Overview

EXT-001 rewards task contributors with DREAMS protocol tokens on top of their USDC
payment. It is implemented as an opt-in ERC-8195 hook — no core protocol changes are
required, and tasks without the hook are unaffected.

Token amounts are computed from two deliberately independent admin-set knobs: `bonusBps`
(what fraction of a task's USD value becomes a bonus — the tokenomics intensity
decision) and `dreamsPerUsdc` (the pure DREAMS/USDC market exchange rate, with no
on-chain price oracle). Both are read once at claim/select-worker time for reserved
modes (Claim, Pitch, Auction); Bounty tasks (no pre-reservation) use the current values
at completion. The reserved modes also refresh `rewardUsd` from the current task context
at claim/select-worker time, so any reward decrease and USDC refund made while the task
was Open is excluded from the later DREAMS reservation. Budget enforcement prevents
runaway token emission through per-epoch global, per-worker, and per-requester USD caps.

This is a Daydreams-specific extension. It is not part of the ERC-8195 or TMP protocol
standard.

---

## Contracts

| Contract | Role |
|---|---|
| `TaskTokenRewardHook` | `ITMPHook` implementation; orchestrates reservation, payment, and claimable escrow |
| `RewardVault` | Holds pre-funded DREAMS tokens; tracks per-task reserved balances |
| `EpochBudget` | Enforces global, per-worker, and per-requester USD emission caps per epoch |

All three contracts are standalone. They do not modify the Diamond proxy or any
existing storage — the hook is wired in via `setDefaultHooks()` on the Diamond's
AdminFacet.

---

## Reward Formula

`bonusBps` (bps of task USD value, e.g. `750` = 7.5%) is set by the contract owner via
`setBonusBps(uint16)`. `dreamsPerUsdc` is DREAMS wei (18 decimals) per 1 USDC, set via
`setDreamsPerUsdc(uint256)`. Neither has an on-chain price feed or automated update —
the owner updates `dreamsPerUsdc` manually when the market price of DREAMS moves
materially (in practice: >20% move or weekly, whichever comes first), and updates
`bonusBps` only as a deliberate tokenomics policy change. The two are computed in
sequence, never combined into one variable:

```
// rewardUsd:     USDC base units (6 decimals). e.g. $100 = 100_000000
// bonusBps:      bps of task value that becomes a bonus. e.g. 750 = 7.5%
// dreamsPerUsdc: DREAMS wei per 1 USDC (18 decimals). e.g. 347 DREAMS/$1 = 347e18

usdBonusValue = rewardUsd * bonusBps / 10000
tokenReward   = usdBonusValue * dreamsPerUsdc / 1e6
```

For Claim / Pitch / Auction tasks, `dreamsPerUsdc` is snapshotted into
`RewardState.startPrice` and the derived `usdBonusValue` is snapshotted into
`RewardState.usdBonusValue` when the worker is locked in (`checkClaim` /
`checkSelectWorker`). The `rewardUsd` input is the task's current reward at that same
moment, not necessarily its creation-time reward. Those values are then used at
settlement — the payout is deterministic once the worker is locked in, with no drift
band or re-read needed, regardless of later changes to either `bonusBps` or
`dreamsPerUsdc`.

For Bounty tasks (no pre-reservation), the *current* `bonusBps` and `dreamsPerUsdc` at
`checkComplete` time are used.

**Worked example:** $100 USD task, `bonusBps = 750` (7.5%), rate 347 DREAMS/$1:

```
usdBonusValue = 100_000000 * 750 / 10000 = 7_500000   ($7.50)
tokenReward   = 7_500000 * 347_000000000000000000 / 1_000000 = 2_602.5 DREAMS
```

---

## hookData

`hookData` is ignored — all configuration lives on the hook contract (rate, caps,
worker split, ramp), set by the owner at deploy time or updated afterward via the
owner-only setters. Tasks opt in by passing the hook's address in `HookConfig`; no
per-task `hookData` payload is needed.

---

## Lifecycle

| Event | Hook call | Action |
|---|---|---|
| `createTask` | `checkFund` | Stores the initial `rewardUsd` from the task's USDC reward. Does not reserve tokens or read a rate yet. |
| `claimTask` / `selectWorker` | `checkClaim` / `checkSelectWorker` | Refreshes `rewardUsd` from the current task context, then computes `usdBonusValue = rewardUsd * bonusBps / 10000` and snapshots the current `dreamsPerUsdc` into `startPrice`. Computes `tokenReward = usdBonusValue * startPrice / 1e6`. Consumes `usdBonusValue` (not raw `rewardUsd`) from `EpochBudget` and reserves `tokenReward` from the vault. If no rate or bonus is configured, reserves nothing but does not block the USDC flow. If the vault cannot cover the reservation, the claim/select-worker call reverts. |
| `submitWork` | `checkSubmit` | Validates worker matches the reserved worker (reserved tasks only). |
| `evaluate` | `checkEvaluate` | No-op. |
| `acceptSubmission` / `finalizeVerdict(APPROVE)` / `resolveDispute` | `checkComplete` | Reserved path: pays exactly the reserved amount (deterministic, no drift). Bounty path: prices each winner at the current rate, capped by USD budget and vault balance, then credits tokens. Marks the reward paid. |
| `cancelTask` | `onCancel` | Releases the full reservation (vault tokens + USD budget) to the pools. |
| `refundExpired` | `onExpire` | Same as cancel. |
| `forfeitAndReopen` | `onForfeit` | Same as cancel. |

**Multi-winner (Bounty) path:** `verdict.awards` lists each winner's pre-fee USDC
amount. Each winner's USD basis is capped by `min(workerUsd, epochBudget.remaining(...),
epochBudget.maxUsdPerTask())`, converted to tokens at the current rate, then further
clamped to the vault's available balance (recomputing the USD amount actually consumed
if the vault clamp binds). A shortfall for one winner never blocks payment to the
others or blocks the underlying USDC payout.

---

## Reward State

```solidity
struct RewardState {
    uint256 rewardUsd;            // USDC 6-decimal amount (= task reward)
    uint256 usdBonusValue;        // rewardUsd * bonusBps/10000 at lock time; the USD basis
                                   // actually converted to tokens and consumed against EpochBudget caps
    uint256 startPrice;           // dreamsPerUsdc snapshot at lock time; 0 for bounty/unreserved
    uint256 reservedTokenAmount;  // tokens reserved from vault (Path A only)
    address requester;
    address worker;
    bool    reserved;             // true for Claim/Pitch/Auction (pre-reserved)
    bool    paid;
}
```

Tokens are credited to a claimable escrow (`claimable[wallet]`) rather than pushed to
wallets directly. A wallet-age ramp (`firstSeen`, `rampThresholds`, `rampMultipliers`)
scales down rewards for wallets younger than the configured thresholds, to limit Sybil
farming. Workers and requesters withdraw their claimable balance via `withdrawFor`,
called by the authorized relayer (the server wallet) — see
[DREAMS Token Rewards](/reference/rewards) for the withdrawal flow.

---

## EpochBudget

`EpochBudget` enforces three independent USD emission caps per epoch, all denominated
in USDC base units (6 decimals) — not DREAMS token amounts, so caps stay meaningful as
the DREAMS/USDC rate moves:

| Cap | Setter |
|---|---|
| Global USD per epoch | `setGlobalCapUsd` |
| Per-worker USD per epoch | `setWorkerCapUsd` |
| Per-requester USD per epoch | `setRequesterCapUsd` |
| Max USD per task | `setMaxUsdPerTask` |

`checkAndConsume(requester, worker, usdAmount)` reverts if any cap would be exceeded;
`release(requester, worker, usdAmount)` reverses a previous consumption (cancel/expire/
forfeit, or a settlement paying less than reserved). Epochs are time-based:
`(block.timestamp - epochStart) / epochDuration`, rolled over lazily on the next call.

Caps are always checked/consumed/released against `usdBonusValue` (the bonus amount
actually converted to tokens), never the raw `rewardUsd`. This was a latent bug in an
earlier revision — before `bonusBps` existed as an independent variable, the bonus was
implicitly 100% of `rewardUsd`, so passing `rewardUsd` directly happened to be correct.
Once `bonusBps` became configurable, budget accounting had to switch to
`usdBonusValue` to avoid releasing a larger amount than was actually consumed.

---

## Security Considerations

**No on-chain price oracle.** The rate is a trusted owner-set value with no automated
staleness or liquidity checks. This is a deliberate simplification at current emission
volumes (~$3-5k/week) — the tradeoff is manual rate-update discipline instead of oracle
manipulation/liveness risk. `setDreamsPerUsdc` rejects a zero rate but has no bounds
check on the magnitude of a change; a fat-fingered rate (e.g. off by 1e18) is not
caught on-chain.

**`bonusBps` and `dreamsPerUsdc` are independent by design.** They were originally a
single conflated variable; splitting them out means a market-price update
(`setDreamsPerUsdc`) can never accidentally change how generous the protocol is being
(`bonusBps`), and vice versa. `setBonusBps` rejects values above `10000` (100%) but `0`
is valid — it deliberately disables the bonus without touching the exchange rate.

**Locked rate for reserved tasks.** Once a worker claims/is selected, `startPrice` is
fixed — later rate changes cannot affect that task's payout. This protects workers from
a rate cut mid-task and protects the protocol from a rate spike mid-task.

**Reservation blocks vault exhaustion race.** Tokens are reserved at claim/select. If
the vault is exhausted after reservation but before completion, the reserved amount is
still available — it is held exclusively for this task.

**Vault exhaustion at claim reverts.** If the vault cannot cover the full reservation,
`checkClaim` / `checkSelectWorker` reverts (the `vault.reserve()` call is not
try-caught). This is a hard failure, not graceful degradation — workers should not be
able to claim a task they cannot be paid for.

**Budget/vault failures never block USDC.** If `EpochBudget.checkAndConsume` fails at
reserve time, or the vault has zero DREAMS available at bounty settlement, the DREAMS
bonus is silently skipped (or partially paid) but the underlying USDC payout always
proceeds.

**Double-payment prevention.** The `paid` flag on `RewardState` is set atomically at
the start of `checkComplete`, before any external call, so a reentrant token-transfer
callback cannot double-pay.

**Withdrawal is authorized by the wallet, not by the relayer.** `withdrawFor` is called
by the authorized relayer, which relays and pays gas — so `msg.sender` is never the wallet and
cannot authorize anything on its behalf. The hook therefore recovers the wallet's own
EIP-191 signature over
`taskmarket:withdraw-dreams:<destination>:<nonce>:<validBefore>` and reverts unless the
signer is the wallet whose balance is being moved. `validBefore` is enforced on-chain,
and `usedWithdrawNonce` (keyed on `keccak256(wallet, nonce)`) rejects replays, so a
captured authorization cannot be re-presented by whoever holds the relaying key.

The same binding was enforced off-chain before this, and still is; the checks
are complementary rather than alternatives. What changed is that the rule is now
enforceable against *any* caller, including a future code path that forgets to apply it,
rather than resting on one hot key remaining correct forever.

The signed message is the one clients already produce. EIP-712 would be cheaper on-chain
but would change what every client signs, so it is deliberately not used here; it could
be added later as a second accepted format rather than a replacement.

**Ownership.** `RewardVault`, `EpochBudget`, and `TaskTokenRewardHook` are owned by the
deployer key at deploy time. Transfer ownership to a multisig before directing
production token funding into the vault.

**Upgradeability concentrates power in the owner.** The hook sits behind an ERC-1967
proxy and is UUPS-upgradeable, so its owner can replace the logic governing every
wallet's claimable balance. That is the same shape of concentration the withdrawal
signature removes, one level up, and it is the reason the multisig transfer above is not
optional. `RewardVault` is deliberately **not** upgradeable: it holds the tokens, and a
treasury whose logic can be rewritten is a strictly worse thing to own.

**Wallet-history seeding is a one-way capability.** `seedWalletHistory` exists to carry
`firstSeen` and `banned` across a hook replacement. It refuses to overwrite a wallet that
already has history on the current hook, and `sealWalletHistory()` disables it
permanently. Seal it once a migration is verified — an owner able to backdate wallet age
indefinitely is more power than the migration needs.

---

## Deployment

### Environment variables

See `DeployRewardHook.s.sol` and `DeployRewardHookTestnet.s.sol` for the authoritative
list — do not rely on this doc for exact names; grep the scripts before deploying.
Summary:

| Variable | Required | Description |
|---|---|---|
| `FORGE_PROTOCOL_TOKEN` | yes | DREAMS token address |
| `FORGE_DIAMOND_ADDRESS` | yes | TaskMarket Diamond proxy |
| `FORGE_DREAMS_PER_USDC` | yes | Whole DREAMS per $1 (e.g. `347`); scaled ×1e18 by the script |
| `FORGE_BONUS_BPS` | yes (mainnet) | USD bonus intensity in bps, e.g. `750` = 7.5% of task value; testnet script defaults to `750` |
| `FORGE_EPOCH_DURATION` | yes | Seconds per emission epoch (e.g. `604800` = 1 week) |
| `FORGE_GLOBAL_EPOCH_CAP_USD` | yes | Max USD-value emitted per epoch (USDC base units) |
| `FORGE_WORKER_CAP_USD` | yes | Per-worker per-epoch cap (USDC base units) |
| `FORGE_REQUESTER_CAP_USD` | yes | Per-requester per-epoch cap (USDC base units) |
| `FORGE_MAX_USD_PER_TASK` | yes | Per-task emission cap (USDC base units) |
| `FORGE_WORKER_SPLIT_BPS` | no | Worker share in bps (default 8000 = 80%) |
| _(none)_ | — | The authorized relayer is read from the forwarder's `authorizedRelayer()` at deploy time rather than supplied separately, so the hook and the forwarder cannot disagree about who may relay |
| `FORGE_INITIAL_VAULT_BALANCE` | no | Tokens to seed the vault with at deploy (wei) |

### Deploy

```bash
make deploy-reward-hook testnet   # mocks a DREAMS token, uses DeployRewardHookTestnet.s.sol
make deploy-reward-hook mainnet   # uses the real DREAMS token, DeployRewardHook.s.sol
```

Both scripts wire the hook into `vault.setHook` / `budget.setHook` and call
`setDefaultHooks([hook])` on the Diamond, replacing the prior default-hook list.

The hook is deployed behind an ERC-1967 proxy (`script/lib/DeployRewardHookProxy.sol`),
which deploys the implementation and initializes it through the proxy in one step. **Every
other contract must be pointed at the proxy address, never the implementation** — the
implementation's own initializers are disabled at construction, so it holds no state and
has no owner. `hook.upgradeToAndCall(newImplementation, "")` replaces the logic while
keeping all storage in place.

After deploy, transfer `RewardVault` and `EpochBudget` ownership to a multisig, then
fund the vault with DREAMS tokens before directing live task traffic to the hook.

### Post-deploy

1. Transfer `RewardVault` ownership: `vault.transferOwnership(multisig)`
2. Transfer `EpochBudget` ownership: `budget.transferOwnership(multisig)`
3. Transfer `TaskTokenRewardHook` ownership: `hook.transferOwnership(multisig)`
4. Fund vault: `dreamsToken.transfer(vaultAddress, initialFunding)` (or via
   `FORGE_INITIAL_VAULT_BALANCE` at deploy time)
5. **When replacing an existing hook**, seed wallet history before live traffic reaches
   the new one — see [Replacing an existing hook](#replacing-an-existing-hook) below.
6. Set `DREAMS_HOOK_ADDRESS` in the backend environment — this is the sole switch that
   enables `wallet.dreamsBalance`, `wallet.withdrawDreams`, `wallet.exchangeRate`, the
   `estimatedWorkerDreamsBonus`/`estimatedRequesterDreamsBonus`/`dreamsPerUsdc`/
   `bonusBps` fields on `task.get`, and reward-hook event indexing (see
   [Event indexing](#event-indexing) below).

### Replacing an existing hook

`make swap-reward-hook <testnet|mainnet>` deploys a new hook + `EpochBudget` pair and reuses
the existing `RewardVault`. It requires zero outstanding reservations in the vault.

A replacement hook starts with **empty storage**, and two mappings matter:

- `firstSeen[wallet]` is the basis for the wallet-age ramp, and `rampMultipliers[0]` is `0`.
  Without migration every existing wallet looks brand new and earns **nothing** until it
  ages past `rampThresholds[0]` again — two weeks at current settings, then eight to ramp
  back.
- `banned[wallet]` resets the other way, which is worse: a wallet the owner removed returns
  admitted.

`claimable` is unaffected — the old hook stays authorized until drained, so balances remain
withdrawable from it. `rewardStates` is unaffected because the swap requires zero outstanding
reservations.

A third mapping matters more than either, because losing it costs money rather than rewards:

- `rewardStates[taskId]` is the only thing that can settle a vault reservation. `vault.release`
  and `vault.pay` are `onlyHook`, and the hook only calls them from a lifecycle path that reads
  this mapping. A task reserved against the old hook and carried into a hook that does not know
  it becomes **permanently unsettleable**: its tokens stay counted in `totalReserved`, and since
  that figure gates the next swap, one orphaned reservation blocks every future one.

  This is not hypothetical. An earlier testnet cutover stranded five reservations exactly this
  way; they are still counted, and `totalReserved()` there can never return to zero.

**Do not wait for a drain.** `totalReserved() == 0` is a snapshot, not a state you can hold: on a
live marketplace a new claim can reserve at any moment, so waiting for the number to reach zero
and stay there is waiting for a quiet moment that never arrives. Freeze it instead.

**Procedure:**

1. Deploy the new hook + proxy. It is not authorized yet and takes no traffic.
2. Reconstruct the wallet set from the old hook's logs: workers from `RewardReserved` and
   `RewardPaid`, requesters from `RewardConfigured` plus a Diamond task lookup for each `taskId`.
   Read `firstSeen(wallet)` and `banned(wallet)` from the **old** hook and write them in batches
   via `seedWalletHistory(wallets, firstSeenAt, isBanned)`. No race here -- this can be done days
   ahead, since it only reads state the old hook will not change.
3. **`make contract pause <network>`.** Claim and select-worker now revert, so the set of
   outstanding reservations is frozen.
4. Carry **every non-settled reward state**, not only the reserved ones. Read
   `rewardStates(taskId)` from the old hook for every task in `RewardConfigured` (union the
   vault's unsettled `Reserved` set), and carry each one whose `paid` is false and whose
   `rewardUsd` is non-zero, via `seedRewardStates(taskIds, states)`.

   The narrower "in-flight" reading of this step is wrong, and quietly so. `rewardStates[taskId]`
   is written when a task is **funded**, not when it is claimed, so a funded-but-unclaimed task
   holds a real configured reward while appearing in no vault reservation at all. Left behind, its
   state on the new hook is empty, and `_reserveForWorker` computes
   `bonusUsd = state.rewardUsd * bonusBps / 10000` = 0 and takes its `rate == 0 || bonusUsd == 0`
   branch: it emits `RewardReserved(taskId, worker, rate, 0)` and returns true. Nothing reverts,
   USDC still settles, and the worker simply never receives a token reward.

   This is not a corner case. At the time of writing the deployed hook had zero in-flight
   reservations and 58 funded-but-unclaimed tasks holding $608.78 of configured reward, so the
   narrow filter would have carried nothing at all and reported success.

   `paid` states are excluded because `seedRewardStates` rejects them; empty ones because there is
   nothing to carry. That also excludes reservations orphaned by an earlier swap, whose state
   lives on a hook that is no longer the one being read.
5. Re-point: `vault.setHook(proxy)`, `budget.setHook(proxy)`, and `setDefaultHooks([proxy])` on
   the Diamond.
6. **`make contract unpause <network>`.** In-flight tasks now settle against the new hook exactly
   as they would have against the old one.
7. Point the consuming application at the new hook address **and rewind its event cursor** to the
   new hook's deploy block. A seed block configured for a fresh deployment is typically only a
   fallback used when no cursor exists yet, so an already-running indexer ignores it and resumes
   from wherever it had reached -- skipping every event the new hook emitted before that point,
   including the seeding transactions themselves. Nothing errors; the data is simply absent.
8. Spot-check seeded wallets and tasks against the old hook, then call `sealWalletHistory()` and
   `sealRewardState()`.

**Keep the existing `EpochBudget`.** `setEpochBudget` on the hook means it does not have to be
replaced, and it should not be: `EpochBudget.release` returns early when `epoch != consumedEpoch`,
so a freshly deployed budget would silently no-op every release for a carried task, leaking
consumed budget that is never credited back. It fails closed rather than reverting, which is
precisely what makes it easy to miss. The budget's own state is epoch-stamped and self-expiring,
so there is nothing in it worth migrating -- the reason to keep it is the carried tasks, not the
budget's own history.

Since this release `banWallet`/`unbanWallet` emit `WalletBanned`/`WalletUnbanned`, so future
reconstructions can read bans from logs directly. A hook deployed **before** that change has
no such events, so its bans are only discoverable by reading `banned(wallet)` for each wallet
found in step 1 — a wallet banned without ever having earned anything cannot be found that
way and must be re-banned by hand.

Once the hook is upgradeable, a logic fix needs none of this: `upgradeToAndCall` keeps the
address and the storage, so the vault is never re-pointed and no reservation is ever orphaned.
The procedure above applies only to this one migration onto the proxy, and to any later move to a
genuinely new contract.

---

## Integration

Tasks opt into token rewards by passing the hook's address in `HookConfig` at
creation — no `hookData` payload is needed (see [hookData](#hookdata) above).

The backend reads the hook's `dreamsPerUsdc()`, `bonusBps()`, and `workerSplitBps()`
directly (`apps/backend/src/services/contract.ts`) and surfaces them via
`wallet.exchangeRate` and on `task.get` when the hook is attached to a task. The web
task detail page, publish wizard, and submit-work flow show the estimated DREAMS bonus
using the same values — see [DREAMS Token Rewards](/reference/rewards) for the full
withdrawal and transparency surface.

---

## Event indexing

Every state-changing hook event (`RewardConfigured`, `RewardReserved`, `RewardPaid`,
`RewardReserveReleased`, `RewardsWithdrawn`, `PriceUpdated`, `BonusBpsUpdated`) is
polled by `apps/backend/src/services/indexer.ts` when `DREAMS_HOOK_ADDRESS` is set,
and written to the generic `protocol_events` audit table (same pattern as the main
Diamond's `FeesUpdated`/`FeeRecipientUpdated` admin events) — no dedicated migration
needed. `DREAMS_HOOK_SEED_BLOCK` controls where indexing starts (defaults to `0`).
This is the only historical record of past payouts and rate/bonus changes; every other
reward-hook read (current rate, current bonus, claimable balance) is an on-demand
`readContract` call with no built-in history.

---

## Implementation

Contracts: `packages/contracts/src/hooks/`
Tests: `packages/contracts/test/TaskTokenRewardHook.t.sol`, `EpochBudget.t.sol`
Deploy scripts: `packages/contracts/script/DeployRewardHook.s.sol`,
`DeployRewardHookTestnet.s.sol`
Backend service: `apps/backend/src/services/contract.ts` (`contractGetDreamsPerUsdc`,
`contractGetDreamsBonusBps`, `contractGetDreamsWorkerSplitBps`,
`contractGetDreamsClaimable`, `contractWithdrawDreamsRewards`)
Backend router: `apps/backend/src/routers/wallet.router.ts`,
`apps/backend/src/routers/tasks.router.ts` (estimate fields on `task.get`)
Backend indexer: `apps/backend/src/services/indexer.ts` (`processRewardHookEvents`)
Shared estimate helpers: `packages/shared/src/lib/dreams.ts`
Frontend: `apps/web/components/market/dreams-rewards-card.tsx`,
`apps/web/components/market/wizard/step-publish.tsx`,
`apps/web/components/market/tasks.tsx` (task detail caption),
`apps/web/components/market/actions/submit-artifacts-form.tsx` (submit-work reminder)
CLI: `apps/cli/src/commands/stats.ts`, `apps/cli/src/commands/wallet/withdraw-dreams.ts`
Smoke test: `apps/backend/src/scripts/smoke-token-reward-hook.ts`
