# ERC-8195 Revision 006 — Open-Contest State Machine

## Motivation

Prior to this revision several state-machine rules either locked out legitimate actors or
conflated two distinct concepts (submission deadline vs. acceptance window) in ways that
caused funds to get stranded. This revision fixes four related problems across three modes.

---

## Problem 1 — Bounty/Benchmark: `submitWork` flipped status to `PendingApproval`

`submitWork` on a Bounty or Benchmark task transitioned the task status from `Open` to
`PendingApproval` on the first submission. This caused:

**Requester lock-out.** `cancelTask` and `updateTask` both gate on `TaskStatus.Open`. Once the
first submission arrived the requester could no longer cancel or adjust reward/deadline while
the contest was still accepting additional entries. A multi-submission contest is by definition
still collecting work after the first entry; the requester should retain management control.

**Misleading API signal.** `pending_approval` was surfaced to off-chain clients and interpreted
as "decision required now". For open contests this was wrong: the task is still actively
collecting entries, not waiting for an immediate decision.

## Problem 2 — Bounty/Benchmark: `acceptSubmission` gated on `expiryTime`

`acceptSubmission` enforced `block.timestamp <= task.expiryTime`. Because `expiryTime` is also
the submission deadline, a requester who did not accept before `expiryTime` could not accept at
all — even when valid submissions had been received. Funds refunded to the requester;
workers were not paid on-chain.

`expiryTime` conflates two distinct concerns: when new submissions stop being accepted
("submission window") and when the requester must decide ("acceptance window"). For
Bounty/Benchmark these should be independent.

## Problem 3 — Bounty/Benchmark: `cancelTask`/`refundExpired` could drain escrow after submissions arrived

With no submission guard, a requester could call `cancelTask` (or anyone could call
`refundExpired` on an expired task) after workers had submitted valid entries, clawing back
the escrow and leaving workers unpaid. This removed the requester's commitment to evaluate.

## Problem 4 — Pitch: `selectWorker` gated on `pitchDeadline`

`selectWorker` reverted if called after `pitchDeadline`. `pitchDeadline` is meant to close the
window for new pitch submissions; it has no meaningful relation to when the requester reviews
and selects from the pitches already received. The gate prevented legitimate delayed selection.

---

## Changes

### 1. `CoreFacet.submitWork` — no status flip for Bounty / Benchmark

```solidity
// Before (rev005)
if (task.mode == BOUNTY || task.mode == BENCHMARK) {
    if (task.status != Open && task.status != PendingApproval) revert TaskNotOpen();
    if (task.status == Open) task.status = PendingApproval;
}

// After (rev006)
if (task.mode == BOUNTY || task.mode == BENCHMARK) {
    if (task.status != Open) revert TaskNotOpen();
    s.taskHasSubmissions[taskId] = true;
    // Status stays Open. Submission presence is tracked by taskHasSubmissions
    // and derivable from the TaskSubmitted event log.
}
```

Bounty and Benchmark tasks stay `Open` from creation until `acceptSubmission` /
`acceptSubmissions` moves them to `Accepted`. There is no intermediate `PendingApproval` step.

### 2. `LibAppStorage.AppStorage` — `taskHasSubmissions` flag

```solidity
// Appended at end of AppStorage struct
mapping(bytes32 => bool) taskHasSubmissions;
```

Set to `true` on the first `submitWork` call for Bounty or Benchmark tasks. Used as the guard
for cancel and refund operations (see Changes 3 and 4). Separate from status so that the task
can remain `Open` while still recording that entries have arrived.

### 3. `ITMPCore` — `SubmissionsExist` error

```solidity
error SubmissionsExist();
```

Reverted when an operation that would drain escrow is attempted after submissions exist for a
Bounty or Benchmark task.

### 4. `CoreFacet.cancelTask` and `CoreFacet.refundExpired` — submission guard

```solidity
if ((task.mode == BOUNTY || task.mode == BENCHMARK) && s.taskHasSubmissions[taskId]) {
    revert ITMPCore.SubmissionsExist();
}
```

Added at the start of both functions, before any balance transfer. Once a worker has submitted,
the escrow is locked until the requester accepts or an admin intervention occurs. This commits
the requester to evaluate received work rather than abandoning it.

### 5. `AcceptanceFacet.acceptSubmission` — `expiryTime` check made mode-conditional

```solidity
// Before (rev005) — blanket check for all modes
if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();

// After (rev006) — only for Claim, Pitch, Auction
if (task.mode != BOUNTY && task.mode != BENCHMARK) {
    if (block.timestamp > task.expiryTime) revert ITMPCore.TaskIsExpired();
}
```

For Bounty and Benchmark, `expiryTime` is now the **submission window deadline** only. The
acceptance window is open-ended: once submissions exist the requester may accept at any time.
The locked escrow is the incentive to act; no hard acceptance deadline is imposed.

For Claim, Pitch, and Auction the original check is unchanged — a single worker committed to
the task, so the requester's acceptance window is still bounded by `expiryTime`.

The same change applies in `AcceptanceFacet._acceptSubmissions` (the multi-winner path, which
is Bounty/Benchmark-only — the check there is removed entirely).

### 6. `CoreFacet.selectWorker` — `pitchDeadline` check removed

```solidity
// Removed (rev005 check)
if (block.timestamp > task.pitchConfig.pitchDeadline) revert ITMPCore.PitchDeadlinePassed();

// After (rev006) — pitchDeadline only gates new pitch submissions, not selection
// The requester may review received pitches and select a worker after the window closes.
```

`pitchDeadline` continues to gate `submitWork` calls in Pitch mode (new pitches are rejected
after the deadline). It no longer gates `selectWorker`. A requester who collects pitches during
the open window can take time to review and select after it closes.

### 7. `PendingApproval` status — evaluator-timeout path only

`TaskStatus.PendingApproval` remains in the enum for backwards ABI compatibility. It is now
only reachable via the evaluator extension: when an assigned evaluator misses its evaluation
window, `EvaluatorFacet.evaluatorTimeout` moves the task from `Review` to `PendingApproval`,
restoring the requester's ability to accept directly.

No normal submission flow sets `PendingApproval`.

---

## Updated State Machines

### Bounty Mode

```
Open
  --[submitWork*]--------> Open          (emits TaskSubmitted; sets taskHasSubmissions;
                                          no status change; task keeps accepting entries)
  --[cancelTask*]--------> Cancelled     (only if taskHasSubmissions == false)
  --[acceptSubmission*]--> Accepted      (single winner; deliverable written here;
                                          valid after expiryTime if submissions exist)
  --[acceptSubmissions*]-> Accepted      (N winners with share basis points;
                                          valid after expiryTime if submissions exist)
  --[expire+noSubmissions]-> Expired     (refundExpired callable only if no submissions)
```

- `Open -> PendingApproval` transition (rev001-rev005) removed.
- `cancelTask` and `refundExpired` blocked once submissions exist.
- Acceptance window is unbounded for tasks with submissions.

### Benchmark Mode

```
Open
  --[submitProof*]-------> Open          (proof hash + metric anchored; emits ProofSubmitted)
  --[submitWork*]--------> Open          (emits TaskSubmitted; sets taskHasSubmissions;
                                          no status change)
  --[cancelTask*]--------> Cancelled     (only if taskHasSubmissions == false)
  --[acceptSubmission*]--> Accepted      (single winner; valid after expiryTime if submissions exist)
  --[acceptSubmissions*]-> Accepted      (N winners; valid after expiryTime if submissions exist)
  --[expire+noSubmissions]-> Expired     (refundExpired callable only if no submissions)
```

### Pitch Mode

```
Open
  --[submitWork*]--------> Open          (pitch hash stored; valid before pitchDeadline only)
  --[selectWorker*]------> WorkerSelected (valid after pitchDeadline; deadline no longer a gate)
  --[expire]-------------> Expired

WorkerSelected
  --[submitWork*]--------> WorkerSelected (final delivery from selected worker)
  --[acceptSubmission*]--> Accepted
  --[expire]-------------> Expired
```

`selectWorker` is now callable both before and after `pitchDeadline`.

### PendingApproval (evaluator-timeout path only, unchanged)

```
Review
  --[evaluatorTimeout]---> PendingApproval   (evaluator missed window; requester reclaims)

PendingApproval
  --[acceptSubmission*]--> Accepted
  --[expire]-------------> Expired
```

---

## Rationale

**Why not add a separate `acceptDeadline`?**

An `acceptDeadline` field would recreate the same problem in a different form: once it expires
the requester is locked out again. Locked escrow is a more effective pressure mechanism —
the requester has an economic incentive to accept without needing a hard cutoff that could
strand funds. An explicit deadline adds complexity without adding value.

**Why block `cancelTask` rather than allow it?**

Once a worker has submitted, they have fulfilled their side of the agreement. Allowing the
requester to cancel and recover the full escrow after receiving work would let them exploit
workers. The escrow lock commits the requester to evaluate; if they genuinely cannot accept
any submission, owner-level `adminRelease` (separate PR) exists as an off-protocol backstop.

**Why block `refundExpired` rather than allow it?**

`refundExpired` is designed for tasks that expire with no activity. If submissions exist, the
task has not been abandoned — it is waiting on a requester decision. Auto-refunding the escrow
while workers wait for payment contradicts the purpose of the timeout mechanism.

**Why does `PendingApproval` stay in the enum?**

Removing it would renumber subsequent enum values, breaking ABI compatibility with off-chain
consumers that decode raw `TaskStatus` integers. The value is preserved at its original
ordinal; it is simply no longer emitted by `submitWork`.

---

## API Changes

The EVM cannot auto-transition state on time without a keeper. After rev006, a Bounty/Benchmark
task remains `status: "open"` on-chain even after `expiryTime` passes (submission window closed,
acceptance window open). Off-chain clients need a way to distinguish "still accepting work" from
"window closed, awaiting requester decision."

The backend derives this boolean and surfaces it in every task API response:

```json
"submissionWindowOpen": false
```

| Mode | Window closed when |
|------|--------------------|
| Bounty | `expiryTime` has passed |
| Benchmark | `expiryTime` has passed |
| Claim | `expiryTime` has passed |
| Pitch | `pitchDeadline` has passed (or `expiryTime` if no `pitchDeadline`) |
| Auction | `bidDeadline` has passed |

When `submissionWindowOpen` is `false`, the backend also omits the submit/bid/pitch/claim worker
action from `pendingActions`. Clients MUST check `submissionWindowOpen` (or `pendingActions`)
before calling any submission-type action; the on-chain call will revert with `TaskIsExpired` or
similar if the window is closed.

### `refund_expired` in `pendingActions`

For Bounty and Benchmark tasks that are past `expiryTime` with no submissions, the backend
surfaces a requester-only action in `pendingActions`:

```json
{
  "role": "requester",
  "action": "refund_expired",
  "command": "taskmarket task refund-expired <taskId>"
}
```

This action is absent when `taskHasSubmissions` is true — the on-chain `refundExpired` call
would revert with `SubmissionsExist` in that case. Clients should read this action from
`pendingActions` rather than re-deriving the condition client-side.

## Affected Files

| File | Change |
|------|--------|
| `src/libraries/LibAppStorage.sol` | Append `taskHasSubmissions mapping(bytes32 => bool)` to `AppStorage` |
| `src/interfaces/ITMPCore.sol` | Add `error SubmissionsExist()` |
| `src/facets/CoreFacet.sol` | Remove `PendingApproval` flip; set `taskHasSubmissions`; add cancel/refund guards; remove `pitchDeadline` gate from `selectWorker` |
| `src/facets/AcceptanceFacet.sol` | Make `expiryTime` check mode-conditional (skip for Bounty/Benchmark) |
| `test/TaskMarket.t.sol` | Update tests for new state machine behavior |
| `docs/specs/erc8195/erc-8195.md` | Update Bounty/Benchmark/Pitch state machines and `PendingApproval` description |
| `docs/specs/erc8195/rev005-diamond-proxy.md` | Update AppStorage field table (offset 23: `taskHasSubmissions`) |
| `apps/backend/src/routers/tasks.router.ts` | Add `computeSubmissionWindowOpen` helper; surface `submissionWindowOpen` in all task responses; fix `computePendingActions` to omit submission actions when window closed |
| `packages/shared/src/schemas/task.schemas.ts` | Add `submissionWindowOpen: z.boolean()` to `TaskResponseSchema` |
