# ERC-8195 Revision 009 — Multi-Submission Rejection Count Fix

## Motivation

Rev006 introduced open-contest bounty and benchmark modes where any worker may call `submitWork`
multiple times on the same task (to iterate on their deliverable). The `taskActiveSubmissionCount`
mapping tracks how many submissions are outstanding so that `cancelTask` and `refundExpired` can
protect workers: the requester cannot reclaim escrow while unreviewed work exists.

The rejection mechanism that clears the count — `rejectSubmission(taskId, worker)` — was designed
for the single-submission-per-worker model: it decremented `taskActiveSubmissionCount` by exactly
one, set `taskRejectedWorkers[taskId][worker] = true`, and blocked further submissions from that
worker. When a worker submitted more than once the rejection call only removed one unit from the
count, leaving the remainder permanently undrainable. A second `rejectSubmission` call for the same
worker reverted with `SubmissionAlreadyRejected`, making it impossible for the requester to reach
`taskActiveSubmissionCount == 0`. Both `cancelTask` and `refundExpired` were therefore permanently
blocked, locking the full task reward in escrow with no on-chain recovery path.

This revision fixes the decrement so one `rejectSubmission` call correctly clears the count for
all of a worker's submissions in a single operation.

---

## Problem — rejectSubmission decremented by 1 regardless of worker submission count

`submitWork` incremented `taskActiveSubmissionCount` on every call:

```solidity
// CoreFacet.submitWork (before this revision)
s.taskHasSubmissions[taskId] = true;
s.taskActiveSubmissionCount[taskId]++;
s.taskSubmissionHashes[taskId][worker].push(deliverable);
s.taskSubmissionHashExists[taskId][worker][deliverable] = true;
```

`rejectSubmission` always decremented by exactly one:

```solidity
// CoreFacet.rejectSubmission (before this revision)
s.taskRejectedWorkers[taskId][worker] = true;
s.taskActiveSubmissionCount[taskId]--;
```

A worker who called `submitWork` N times contributed N to the count but could only be rejected
once (the flag set on the first call blocked all further calls). After rejecting every unique
worker on a task with multi-submitters the count remained positive and neither `cancelTask` nor
`refundExpired` could proceed:

```
Worker A submits 5×  → taskActiveSubmissionCount = 5
Worker B submits 2×  → taskActiveSubmissionCount = 7
Reject worker A      → taskActiveSubmissionCount = 6  (only -1)
Reject worker B      → taskActiveSubmissionCount = 5  (only -1)
cancelTask           → reverts: SubmissionsExist       (count = 5, not 0)
```

There was no further on-chain action available to the requester. The escrow was permanently locked.

---

## Change — decrement by the worker's full submission count

`rejectSubmission` now reads `taskSubmissionHashes[taskId][worker].length` — the on-chain record
of how many times the worker called `submitWork` — and uses that as the decrement:

```solidity
// CoreFacet.rejectSubmission (after this revision)
s.taskRejectedWorkers[taskId][worker] = true;
// Decrement by the worker's full submission count so that workers who submitted
// multiple times don't leave a phantom count that blocks cancelTask/refundExpired.
// Falls back to 1 for pre-rejection (worker hasn't submitted yet) and for
// submissions made before taskSubmissionHashes tracking was introduced.
uint256 workerCount = s.taskSubmissionHashes[taskId][worker].length;
uint256 decrement = workerCount > 0 ? workerCount : 1;
uint256 active = s.taskActiveSubmissionCount[taskId];
s.taskActiveSubmissionCount[taskId] = active > decrement ? active - decrement : 0;
```

The same scenario now resolves correctly:

```
Worker A submits 5×  → taskActiveSubmissionCount = 5
Worker B submits 2×  → taskActiveSubmissionCount = 7
Reject worker A      → taskActiveSubmissionCount = 2  (decrement by 5)
Reject worker B      → taskActiveSubmissionCount = 0  (decrement by 2)
cancelTask           → succeeds, escrow returned
```

The fallback to 1 preserves two existing behaviors:
- **Pre-rejection**: a requester may call `rejectSubmission` for a worker who has not submitted
  yet (to pre-emptively block them). The worker has no hashes in `taskSubmissionHashes` so length
  is 0; the count decrements by 1 as before.
- **Legacy submissions**: submissions made before `taskSubmissionHashes` was introduced do not
  appear in the mapping. The fallback keeps the single-decrement behavior for these tasks, which
  is the same as the old behavior and no worse than before.

---

## Rationale

**Why not per-submission rejection (reject by hash)?**

An alternative design would change the signature to `rejectSubmission(bytes32 taskId, bytes32
submissionHash)`, decrementing by 1 per hash. This gives the requester fine-grained control —
reject v1 but leave v2 open for acceptance. It also cleanly maps to the per-submission DB records
held by the backend.

The downside is that it turns "I don't want work from this person" into N sequential transactions
when a worker spammed N submissions. A spammy worker could inflate the requester's gas cost and
block cancellation for as long as the requester delays. Per-worker rejection collapses N
transactions into one, which is the right default for the anti-spam case.

Fine-grained per-submission control remains available at the acceptance layer: the requester can
accept any specific submission hash they choose via `acceptSubmission`. Rejection is the "close
out this worker" operation, not the "review each version individually" operation.

**Why not prevent multi-submissions in the backend?**

Blocking re-submissions in the backend router would be a band-aid that the contract cannot enforce.
A worker interacting with the contract directly (or through a different relayer) could still
multi-submit. The count would diverge from the backend's view of the world. The fix belongs in
the contract, which is the authoritative source of truth.

Multi-submissions should remain allowed: an iterative bounty market where workers can improve and
re-submit their deliverable is a first-class use case. The bug was in the accounting, not in the
permission to re-submit.

**Why the safe-floor `active > decrement ? active - decrement : 0`?**

Unsigned integer subtraction that goes negative wraps to a very large value in Solidity. The floor
prevents underflow in the edge case where the DB and chain are temporarily diverged or a
pre-rejection is counted alongside the worker's submission hashes.

---

## Backend fix included in this revision

`refundExpired` in `tasks.router.ts` checked whether ANY submission rows existed for the task,
including rows already marked `rejected_at IS NOT NULL`. This caused `refundExpired` to throw "Task
has submissions" even when all submissions had been rejected and `submissionCount` was reported as 0
to the caller. The query now filters to active submissions only:

```typescript
// Before
.where(eq(submissions.taskId, input.taskId))

// After
.where(and(eq(submissions.taskId, input.taskId), isNull(submissions.rejectedAt)))
```

Additionally, `rejectSubmission` in `tasks.router.ts` previously relied entirely on the indexer to
set `rejected_at` on submission rows after a `SubmissionRejected` event was emitted on-chain. The
indexer introduces a processing delay, during which the backend's `submissionCount` still showed
the rejected submissions as active. The handler now writes `rejected_at` immediately after the
contract call succeeds, before returning the transaction hash.

---

## Affected Files

| File | Change |
|---|---|
| `packages/contracts/src/facets/CoreFacet.sol` | `rejectSubmission`: decrement by worker's submission hash count |
| `packages/contracts/test/TaskMarket.t.sol` | Two new tests: single worker multi-submit and mixed worker multi-submit |
| `apps/backend/src/routers/tasks.router.ts` | `refundExpired`: filter to active submissions only; `rejectSubmission`: set `rejected_at` inline |
