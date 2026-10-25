# Rev026 -- escrow liabilities and the solvency check

## Status

Deployed on 2026-10-25 on Base Sepolia (84532), Tempo Moderato (42431), Tempo mainnet (4217) and
Base mainnet (8453). Every chain's live tasks are backfilled and `liabilitiesInitialised` is true.
The hook gas stipend is 7,000,000 on both Tempo chains and the 1,000,000 default on Base.

## Problem

The diamond holds every task's reward, every Claim worker stake and every evaluator stake in one
pooled USDC balance, with no record of what that pool owes. rev025 binds each funding call to the
forwarded payment, so an underpaid relay already reverts. Nothing checks the payout side: a payout
path that pays a task more than it holds takes the difference out of other tasks' escrow, and the
shortfall surfaces only when the last of them settles. That is how the rev016 drain happened, and
rev024 closed several more paths of the same shape.

## Change

### Storage

Appended to `AppStorage`:

- `totalLiabilities`: the sum of every booked task's booked amount.
- `escrowRecords`: one slot per task, `{ uint128 booked; bool tracked; }`.
- `liabilitiesInitialised`: true on a fresh deploy, and on an upgraded diamond once the owner has
  backfilled every live task and called `completeLiabilities`.
- `hookGasStipend`: the gas forwarded to each hook call on this chain (see "Per-chain hook gas
  stipend" below). Zero means never set and reads as the 1,000,000 default.

### What a task owes

`LibEscrow.owed(task)` is the escrow conservation formula the Foundry invariant has asserted since
rev024:

```text
owed(task) = 0                                if Accepted, Expired or Cancelled
           = reward + evaluatorStake          otherwise, plus stakeAmount if Claim mode
```

The reject fee is subtracted from `reward` when paid, and the evaluator fee is deferred inside
`reward` until the verdict is final. An auction's `stakeAmount` is the accepted price, part of the
reward.

### Book and release

Rather than adjusting the books at each of the thirty-odd transfers, every money-moving entrypoint
calls one helper at its end, which re-derives `owed` from the task's state:

- **Funding** (`createTask`, `updateTask` reward increase, `claimTask`, `assignEvaluator`):
  `LibEscrow.book` books the growth in `owed` and requires `balanceOf(diamond) >= totalLiabilities`
  afterwards. The funds arrived before the call through the forwarded payment, so this requires the
  unbooked balance to cover what is booked. It does not require it to equal it: rev025 already checks
  the exact payment, and an exact check would let a stray transfer to the diamond block every
  funding call. Each booking emits `EscrowFunded(taskId, payer, amount, component)`, so the payer
  is recorded in events, not storage. The evaluator stake's payer is the requester.
- **Payouts** (`acceptSubmission`, `acceptSubmissions`, `settleLapsedReview`, `rejectDelivery`,
  `releaseClaim`, `forfeitAndReopen`, `cancelTask`, `refundExpired`, `updateTask` reward decrease,
  `evaluate`, `finalizeVerdict`, `resolveDispute`, `evaluatorTimeout`): the entrypoint records the
  diamond's balance when it starts, and `LibEscrow.release` requires that what left the diamond
  during the call is no more than the fall in the task's `owed`. That is the per-task payout cap:
  no task can be paid more than was booked for it. It then releases the fall and requires
  `balanceOf(diamond) >= totalLiabilities`.

A payout that leaves `owed` higher than booked reverts `EscrowMismatch`; one that pays out more
than it releases reverts `EscrowOverdrawn`; any call that leaves the pool short reverts
`EscrowInsolvent`. Each replaces a silent drain with a revert in the transaction that causes it.
`updateTask`'s pool-wide `balanceOf >= newReward` check is gone: `book` covers it per task.

The check runs on every payout path, not only the permissionless ones. It costs one `balanceOf`
call at the start and one at the end, a counter write and a per-task slot write, and the bug class
is not limited to permissionless calls.

### Tasks created before rev026

A task created before the upgrade has no record (`tracked` false). Until it is backfilled, its
funding calls book nothing and emit `UnbookedFunding`, and its payouts release nothing and emit
`UnbookedRelease(taskId, paidOut)`. A migration gap therefore never strands a legacy task's funds.

The owner backfills with `backfillLiabilities(taskIds)`, in batches of live task IDs exported from
the indexer. Each task is booked at what its state owes in that transaction; unknown, terminal and
already-booked IDs are skipped, so a repeated or stale ID is harmless, and the batch ends with the
solvency check. No pause is needed: a task that settles before its batch is terminal and skipped,
and one that settles after it releases what it was booked at. The owner then reconciles
`balanceOf - totalLiabilities` against the off-chain escrow monitor and calls `completeLiabilities`,
which sets `liabilitiesInitialised` and opens the surplus sweep. `completeLiabilities` reverts once
it is set; `backfillLiabilities` stays open. The export comes from an off-chain database and can miss
a live task, and a sweep would then send that task's escrow to the fee recipient, leaving its
payout to fail the solvency check. Keeping the backfill open lets the owner recover such a task:
return its escrow to the diamond, then book it. The solvency check refuses the booking until the
escrow is back.

### Forwarders must report the payment

Every funding path (`createTask`, `assignEvaluator`, `claimTask` and an `updateTask` reward
increase) requires the calling forwarder to report, through `pgtrPaymentAmount`, exactly the amount
the call books. A forwarder that cannot report one (the original ERC-8194 forwarder, before the
rev005 payment-amount extension) is refused with `ForwardedPaymentMismatch`, or
`StakePaymentMismatch` on a claim, even for a zero amount. rev025 still accepted such a forwarder: it
trusted it to have funded a create, pulled an evaluator stake from the requester's allowance,
allowed an unstaked claim, and checked an unreported reward increase on an unbooked task only
against the pool-wide balance (`RewardIncreaseNotFunded`). Each of those let a task be booked
for money the forwarder never reported, so rev026 removes them, along with the
`RewardIncreaseNotFunded` and `StakeTransferFailed` errors they raised. Only `TaskMarketForwarderV2` is deployed, and the original forwarder contract is
removed from this package.

### Surplus sweep

`sweepSurplus()` (owner only) sends `balanceOf - totalLiabilities` to the fee recipient and emits
`SurplusSwept`. It reverts `LiabilitiesNotInitialised` until the backfill is complete, because
until then the unbooked balance still holds legacy tasks' escrow.

### Views

`RegistryFacet` adds `totalLiabilities()`, `escrowRecord(taskId)` and `liabilitiesInitialised()`.

### Removed: the rev018 `createTask` and `normalizeTerms`

rev025 kept two pieces of migration surface for one revision, and rev026 removes both.

- The rev018 `createTask(TaskConfig, StakeConfig, HookConfig, TaskContent, TaskEvaluatorConfig)`
  (selector `0xa810726c`). It recorded the protocol default terms with the call's stake. The
  terms-taking `createTask(TaskConfig, HookConfig, TaskContent, TaskEvaluatorConfig, TaskTerms)` is
  now the only overload; a caller that wants the old behaviour passes version 1 terms with its stake
  and every other field zero.
- `normalizeTerms(bytes32[])` (selector `0xe7056c4e`), with the lazy normalization in
  `LibTerms.terms`, the pre-rev025 branch of `getTaskTerms`, and the branch of `reviewDeadline`
  that read an unnormalized delivery's window as starting now. Every task live at the rev025 cut was
  normalized in that rollout, and every task created since records version 1 terms at creation, so
  no non-terminal task can still hold a version 0 record. A task that was terminal at the cut keeps
  its version 0 record, which `getTaskTerms` returns as stored; no settlement path reads it.

Removing them recovers CoreFacet and SettlementFacet bytecode and drops a code path no live task can
reach.

### Per-chain hook gas stipend

Every hook call gets a fixed gas stipend (`LibHooks._safeHookCall`), and the after-hook paths
(`_dispatchAfterHooksFullGas`: verdicts, cancel, expiry) refuse to start a hook call with less than
that stipend left. Through rev025 the stipend was the constant 1,000,000, sized on Base, where a new
storage slot costs about 20,000 gas.

Tempo prices state creation far higher: about 250,000 gas per new slot. A hook whose `checkFund`
books new state in several slots cannot fit in 1,000,000 there. The Sponsored Task hook's
`checkFund` (a vault reservation, a fee-bank charge receipt and the hook's allocation records)
measured 5.5M to 6.0M gas per call on a local Tempo chain, so every sponsored task creation reverted
`HookCheckFundRejected`. The same facet code has to run on Base and Tempo, so one constant cannot be
right for both.

rev026 makes the stipend a per-chain value:

- `AppStorage.hookGasStipend`, read through `LibHooks._hookGasStipend`, which returns
  `HOOK_GAS_STIPEND` (1,000,000) while it is unset. A diamond upgraded into rev026 keeps the
  stipend it had until the owner changes it.
- `AdminFacet.setHookGasStipend(uint256)` (owner only) accepts 1,000,000 to 8,000,000 and emits
  `HookGasStipendUpdated`; `hookGasStipend()` reads the effective value. The floor is today's
  default, so no chain can starve a hook that works now. The ceiling keeps an after-hook path, which
  needs the stipend left before each hook call on top of its own settlement work (about 3.5M on
  Tempo), under the 2^24 per-transaction gas cap.
- Both `_safeHookCall` and the after-hook gas guard read the same value, so raising the stipend
  also raises the gas every after-hook transaction must carry. A chain should run the smallest
  stipend its hooks need.

Tempo runs 7,000,000: the measured 6.0M peak plus about 16% headroom. Base keeps the default. The
backend's relay gas limits size each hook call from the same per-chain figure, so a change to it on
chain ships with the matching backend change.

An owner-settable stipend gives the owner a lever over how much gas a relayed call can lose to a
hook. The bounds limit that lever, and the event makes every change visible.

### Sponsored Task vault: the emergency exit accepts a short delivery

Every outgoing transfer from a Sponsored Task vault goes through `_transferExact`, which reverts
unless the vault's balance falls by exactly the amount and the recipient's rises by exactly the
amount. That protects workers and fee recipients from being paid short. But if the project token
starts charging a transfer fee after the vault is funded, every exact transfer reverts: claims,
`claimFee`, `withdrawAvailable`, and `emergencyExitVault`, the owner's last resort. No path is left
that can move the balance, so the funds are locked for good.

rev026 gives `emergencyExitVault` its own transfer check, `_transferExit`. The vault must not lose
more than it sends, it must send something, and the recipient must receive something, but a token's
fee may take part of it. The owner recovers the balance net of the fee. Claims, fee claims and
withdrawals keep the exact check. A token that delivers nothing to the named recipient, such as one
whose receive policy redirects the transfer, still makes the exit revert.

This does not cover a token that blocks the vault outright. Then every transfer out of the vault
reverts inside the token, and no vault code can move the funds. That limit is recorded in ERC-8195's
Security Considerations, item 8. The change reaches existing vaults only through a new vault
implementation behind the factory, because vaults are clones of a fixed implementation.

## Upgrade

`Rev026Upgrade` Replaces CoreFacet, SettlementFacet, AcceptanceFacet, EvaluatorFacet, AuctionFacet,
AdminFacet and RegistryFacet, Adds `sweepSurplus`, `backfillLiabilities`, `completeLiabilities`,
`hookGasStipend`, `setHookGasStipend` and the three views, Removes the rev018 `createTask` and
`normalizeTerms`, and sets `diamondVersion` to 26. AuctionFacet is Replaced because it dispatches
hooks and must read the per-chain stipend like the others. When `FORGE_HOOK_GAS_STIPEND` is set the
same broadcast sets the stipend; `script/tempo.sh` requires it on Tempo. `Rev026Backfill` then books the exported task IDs.

## Trade-offs

- Every funding and payout call costs more gas.
- A money-moving path that does not call the helpers is a bug in its own right: an over-count
  reverts honest calls, an under-count weakens the check. The escrow invariant asserts
  `totalLiabilities == sum(owed)` and `booked == owed` per task after every handler action.
- A live task missing from the export is tolerated, not caught, so the reconciliation step is
  load-bearing.
- A stray transfer to the diamond sits as surplus until swept.
- This does not protect against a compromised relayer or owner.

## Tests

- `test/SponsoredTasksVaultTokenLockout.t.sol`: a token that switches on a transfer fee after
  funding blocks claims, fee claims and withdrawals, and the owner can still exit net of the fee.
- `test/SponsoredTasksVault.t.sol`: the exit under a fee token from the start now succeeds net of
  the fee, and an exit to the vault itself still reverts.

- `test/invariant/EscrowConservation.t.sol`: `invariant_LiabilitiesMatchWhatLiveTasksOwe`.
- `test/EscrowLiabilities.t.sol`: booking, unfunded creation and increase, release, the payout cap,
  insolvency, unbooked tasks and the sweep, with a test-only facet standing in for a buggy payout.
- `test/Rev026Upgrade.t.sol`: the cut and backfill from a diamond with unbooked live tasks, then
  every payout path; the two removed selectors stop routing.
- `test/TaskTerms.t.sol`: a version 0 record reads as stored and is never rewritten.
- `test/TaskMarket.t.sol`: the stipend's default, bounds, owner check and event; a hook whose
  `checkFund` outgrows the default is rejected and funds once the stipend is raised; the after-hook
  guard demands the raised stipend.
- `test/Rev026Upgrade.t.sol`: an unset stipend reads the default after the cut, the Tempo value is
  set by the upgrade, and AuctionFacet is Replaced.
