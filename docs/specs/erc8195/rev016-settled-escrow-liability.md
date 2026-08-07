# ERC-8195 Revision 016 — Settled Escrow Liability

## Motivation

Escrow in this contract is a single pooled USDC balance. There is no per-task sub-account, so the
only record of what the pool owes is the set of `task.reward` values in `AppStorage`. Every
guarantee that a funded task can actually pay out rests on that record staying in step with the
money — and nothing enforced it.

Two defects fell out of the same gap, in opposite directions. `refundExpired` paid a task's reward
out without ever zeroing the record, and did not treat `Expired` — the status it sets itself — as
terminal, so a second call passed every guard and paid the same reward again out of the pool that
funds every other task. `updateTask` was the mirror image: the forwarder pulls a reward increase
from the requester *before* the Diamond executes, and the Diamond has no path to hand it back, so
a repeated relay of the same increase hit a now-false `newReward != task.reward` guard, no-op'd,
and kept money corresponding to no liability at all.

The first was confirmed exploitable on Base mainnet with a passing Forge proof of concept before
this fix was written: roughly 430 USDC of pooled escrow, five tasks sitting in `Expired`, the
contract unpaused, and the call permissionless by design (ADR-0026).

This revision writes each settled fact together with what it settles: the reward is zeroed by the
statement group that pays it out, and a payment that will not produce a change reverts rather than
being absorbed.

---

## Problem 1 — `refundExpired` is repeatable and drains other tasks' escrow (#432)

`CoreFacet.refundExpired` rejected `Accepted` and `Cancelled`, but not `Expired` — the status its
own refund path assigns. No refund path zeroed `task.reward`. Escrow is pooled. Those three facts
compose into a repeatable full payout:

```solidity
// before
if (task.status == ITMPCore.TaskStatus.Accepted) revert ITMPCore.TaskAlreadyAccepted();
if (task.status == ITMPCore.TaskStatus.Cancelled) revert ITMPCore.TaskIsCancelled();
// ... no Expired guard, and the refund paths never touch task.reward
```

The call is permissionless, so any address could drive it. The caller gains nothing directly — the
money still goes to that task's requester — but every repeat is funded from the pooled balance, so
unrelated, fully funded tasks become unable to pay out. The auction branch was reachable
identically: `_refundAuctionClaimed`'s claimed-but-never-delivered path also sets `Expired` and
also left the reward standing, an identical defect in a second function.

Issue #198 had already fixed the neighbouring bug in this same function and passed directly over
this one; see the Rationale.

## Problem 2 — `updateTask` absorbs a duplicate reward-increase payment

`updateTask` guarded a reward change on `newReward != task.reward`. When a relayed call is
retried, the guard is false the second time and the function silently no-ops — but the forwarder
has already pulled `newReward - currentReward` from the requester for that attempt, and the
Diamond has no path to return it.

The forwarder's replay guard does not help. It keys on a caller-supplied receipt nonce, so it
stops a byte-identical resubmission but not a retry, and the backend's relayed-intent machinery
retries with a fresh nonce by design. The requester is charged twice for one increase, and the
second payment lands in the pool corresponding to no liability at all — the same divergence as
Problem 1, arriving from the other side.

---

## Changes

### 1. `CoreFacet.refundExpired` — `Expired` is terminal (#432)

```solidity
// before
if (task.status == ITMPCore.TaskStatus.Cancelled) revert ITMPCore.TaskIsCancelled();

// after
if (task.status == ITMPCore.TaskStatus.Cancelled) revert ITMPCore.TaskIsCancelled();
if (task.status == ITMPCore.TaskStatus.Expired) revert ITMPCore.TaskAlreadyRefunded();
```

### 2. `CoreFacet` refund paths — zero the reward before paying

Both refund paths now extinguish the recorded liability in the same statement group that decides
to pay it out, before any transfer (checks-effects-interactions). The amount is captured into a
local first, so zeroing does not change what is paid.

```solidity
// before
task.status = ITMPCore.TaskStatus.Expired;
uint256 refundAmount = task.reward - evalFeeAlreadyPaid;

// after
task.status = ITMPCore.TaskStatus.Expired;
uint256 refundAmount = task.reward - evalFeeAlreadyPaid;
task.reward = 0;
```

The same zeroing is added to `_refundAuctionClaimed`'s no-deliverable branch, where `refundAmount`
is the full `task.reward`.

### 3. `CoreFacet.updateTask` — revert instead of no-op'ing a named-but-unchanged reward

```solidity
// before
uint256 refund = 0;
if (newReward != 0 && newReward != task.reward) {

// after
if (newReward != 0 && newReward == task.reward) revert ITMPCore.NoRewardChange();

uint256 refund = 0;
if (newReward != 0 && newReward != task.reward) {
```

Callers leave a field unchanged by passing `0`, so this rejects nothing legitimate.

### 4. `script/upgrades/Rev016Upgrade.s.sol` — diamond-cut upgrade step

No parameter list changed, so no selector changed. CoreFacet is a pure `Replace` over
`FacetSelectors.coreFacetSelectors()` with no `Remove`/`Add`, in the shape of rev015. The two new
errors are ABI surface but not routing surface — the diamond registers no selector for an error —
so they need no cut of their own. Precondition `diamondVersion == 15`; sets it to 16.

---

## Rationale

**Why zero the liability instead of just adding the missing status check (#432)?**

The status check alone is a fix for one path; it leaves the invariant unstated and unenforced
anywhere. The history is the argument. Issue #198 fixed the neighbouring bug in this exact
function — `refundExpired` refunding an evaluator fee that `evaluate()` had already paid out — and
#198's own suggested remedy was to reduce `task.reward`, which would have closed #432 as a side
effect. The implemented fix instead deducted `evalFeeAlreadyPaid` at read time and left the reward
liability standing. The bug was found once, the correct remedy was written down once, and the
cheaper local fix was taken, so the same defect was still there for #432 to find in the same
function. Doing it at the liability level means a future status that reaches this path cannot
double-pay even if its guard is wrong, which is the difference between a fix and an invariant.

**Why not track a `totalOutstandingLiability` in `AppStorage` instead?**

It would make the invariant checkable in one place, but it is an `AppStorage` addition on a live
diamond, it has to be maintained correctly at every payout site — including the
`Accepted`-terminating paths this revision deliberately leaves alone — and a maintenance bug in it
is a new way to brick payouts. Zeroing per task needs no new state and is locally verifiable. The
invariant is instead asserted in the test suite, across a real transition sequence, which catches
the same class of divergence without putting new state on chain.

**Why make `updateTask` revert rather than genuinely no-op and transfer nothing?**

Not implementable on this side of the forwarder boundary. The forwarder pulls the USDC before the
Diamond executes and the Diamond never learns the amount. Reverting is the only mechanism
available that unwinds the transfer, because the whole transaction unwinds with it.

**Why a new `TaskAlreadyRefunded` rather than reusing `TaskIsExpired`?**

`TaskIsExpired` already means "this task's window has closed, so the thing you asked for is no
longer available" and is thrown from claim and submission paths. Reusing it here would collapse
two states an operator has to tell apart: a task that expired and still owes a refund, and a task
that expired and has already been paid. The second is a no-op-shaped success from the caller's
point of view and needs to be distinguishable from a genuine failure without reading storage.

**Why does `getTask` now report `0` for a settled task's reward?**

Zeroing is the point of the fix, so the read follows it. The original value is not lost: it
survives in the `TaskCreated` and `TaskExpired` events and in the indexed database row, which is
where any caller wanting the historical amount should already be reading it.

---

## API Changes

**New errors.** `TaskAlreadyRefunded()` from `refundExpired` when the task is already `Expired`;
`NoRewardChange()` from `updateTask` when a caller names the reward the task already has. Both are
reachable by callers that were previously succeeding, and that is the point of the revision: the
calls they replace are exactly the ones that were succeeding when they should not have. A second
`refundExpired` on an already-refunded task used to pass every guard and pay the reward a second
time out of pooled escrow; it now reverts `TaskAlreadyRefunded()`. An `updateTask` naming the
reward the task already has used to succeed as a silent no-op while the forwarder had already
pulled the USDC for the increase; it now reverts `NoRewardChange()` so the transfer unwinds with
the transaction. Any client that treated either as a success was being paid, or charged, for
something that did not happen.

**Adding a custom error to a facet is not complete until the backend can decode it.** Relayed calls
are decoded against `FORWARDER_ABI`, so viem only ever supplies the raw selector and an unmapped
Diamond revert resolves to the string `unknown revert`. `classifyRelayFailure` treats that as
**transient** — deliberately, since wrongly abandoning recoverable work is the more expensive
mistake — and therefore retries it for ever. Both new errors are permanently true once true, so an
unmapped one is an intent that can never succeed and never stops asking. Both selectors must be
present in `KNOWN_ERRORS` in `apps/backend/src/services/contract.ts` before this facet is cut in.
That ordering is API-visible, not an implementation detail: it decides whether a client's failed
write reports a reason or hangs.

**`getTask(taskId).reward` returns `0` for a settled expired task.** Callers that read the reward
after settlement must read the `TaskCreated`/`TaskExpired` events or the indexed row instead.

**No function signature, selector, event, REST or CLI surface changes.**

---

## Affected Files

| File | Change |
|---|---|
| `packages/contracts/src/facets/CoreFacet.sol` | `refundExpired` rejects `Expired`; both refund paths zero `task.reward` before transferring; `updateTask` reverts `NoRewardChange` on a named-but-unchanged reward |
| `packages/contracts/src/interfaces/ITMPCore.sol` | Add `error TaskAlreadyRefunded()` and `error NoRewardChange()` |
| `packages/contracts/script/upgrades/Rev016Upgrade.s.sol` | New: pure `Replace` of `coreFacetSelectors()`; `diamondVersion` 15 → 16 |
| `packages/contracts/test/Rev016Upgrade.t.sol` | New: advances a helper-baseline diamond to rev015, applies the step, asserts the version bump and that every CoreFacet selector still routes |
| `packages/contracts/test/TaskMarket.t.sol` | Repeat-refund rejection on both the normal and auction-claimed paths, reward zeroing, the cross-task escrow-drain proof, the duplicate reward-increase relay, and a solvency invariant across a full transition sequence |
| `packages/contracts/.gas-snapshot` | Regenerated |

## References

- Issue #432 — repeatable `refundExpired`
- Issue #198, Issue #203 — the rev013 fixes in the same two functions
- ADR-0026 — Refunding an expired task is permissionless
- ADR-0011 — Diamond selectors: single source and versioned upgrades
- `rev013-bounty-security-fixes.md` — the earlier fixes to `refundExpired` and `updateTask`
