# ERC-8195 Revision 007 — Submission Integrity

## Motivation

Prior to this revision, `acceptSubmission` for Bounty and Benchmark tasks accepted any arbitrary
`bytes32 deliverable` hash supplied by the requester at acceptance time. No on-chain check
verified that the claimed worker had ever committed that hash. A requester could create a task,
submit as the worker using the same address, and pass any invented deliverable hash to trigger a
payout to themselves — the "self-award attack." Because `submitWork` stored nothing in
`AppStorage`, the contract had no state to check against. The attack required no off-chain
coordination; it was executable in two transactions.

This revision closes the attack by storing every deliverable hash in `AppStorage` at submit time
and verifying it at accept time. It also introduces on-chain accounting for requester behavior
(self-awards, late cancellations, expired tasks with unfulfilled submissions) via a new
`RequesterReputation` event emitted at every terminal state.

---

## Problem 1 — `submitWork` did not store deliverable hashes in state

`submitWork` for Bounty and Benchmark tasks emitted `TaskSubmitted(taskId, worker, deliverable)`
but stored nothing in `AppStorage`. Event logs are write-only from the contract's perspective:
the contract cannot read its own event history. As a result, no on-chain record existed of which
hashes had been committed by which worker on which task.

```solidity
// Before (rev006): submitWork emitted the event but persisted nothing
emit ITMPCore.TaskSubmitted(taskId, worker, deliverable);
```

## Problem 2 — `acceptSubmission` trusted the caller-supplied deliverable

The Bounty/Benchmark branch of `_validateAcceptSubmission` verified task status and mode but
applied no hash verification. Any non-zero `bytes32` passed as `deliverable` was accepted:

```solidity
// Before (rev006)
} else {
    // BOUNTY or BENCHMARK: no deliverable verification
    if (evaluator != address(0)) revert ITMPCore.UseEvaluate();
    if (task.status != ITMPCore.TaskStatus.Open && task.status != ITMPCore.TaskStatus.PendingApproval) {
        revert ITMPCore.TaskNotOpen();
    }
    if (worker == address(0)) revert ITMPCore.WorkerRequired();
    if (deliverable == bytes32(0)) revert ITMPCore.DeliverableRequired();
    task.deliverable = deliverable;
}
```

A caller supplying a hash that was never submitted would succeed. Combined with Problem 1 — no
stored submission history — there was nothing to check against.

---

## Changes

### 1. `LibAppStorage.AppStorage` — `taskSubmissionHashes` mapping

```solidity
// After: appended at end of AppStorage struct
mapping(bytes32 => mapping(address => bytes32[])) taskSubmissionHashes;
```

Mirrors the existing `taskPitchHashes` and `taskProofHashes` fields. Stores all deliverable
hashes committed by each worker per task in insertion order, preserving full version history
rather than just the latest.

### 2. `CoreFacet.submitWork` — push hash at submit time

```solidity
// Before (rev006): submitWork emitted event but stored nothing
emit ITMPCore.TaskSubmitted(taskId, worker, deliverable);

// After (rev007): record hash in state before emitting
s.taskSubmissionHashes[taskId][worker].push(deliverable);
emit ITMPCore.TaskSubmitted(taskId, worker, deliverable);
```

### 3. `AcceptanceFacet._validateAcceptSubmission` — verify hash at accept time

```solidity
// Before (rev006): no hash verification
if (deliverable == bytes32(0)) revert ITMPCore.DeliverableRequired();
task.deliverable = deliverable;

// After (rev007): verify hash was committed on-chain before accepting
if (deliverable == bytes32(0)) revert ITMPCore.DeliverableRequired();
bytes32[] storage submitted = s.taskSubmissionHashes[taskId][worker];
bool found = false;
for (uint256 i = 0; i < submitted.length; ++i) {
    if (submitted[i] == deliverable) {
        found = true;
        break;
    }
}
if (!found) revert ITMPCore.SubmissionNotFound();
task.deliverable = deliverable;
```

### 4. `AcceptanceFacet.acceptSubmissions` — remove `deliverables[]` parameter

Old signature: `acceptSubmissions(bytes32, address[], uint16[], bytes32[])` — caller passed an
explicit array of deliverable hashes, one per winner.

New signature: `acceptSubmissions(bytes32, address[], uint16[], uint256)` — the contract resolves
the latest hash from `taskSubmissionHashes[taskId][worker]` for each winner. The fourth parameter
is `requesterAgentId` (see Change 8 below). The caller no longer supplies deliverables.

### 5. `ITMPCore` — new error `SubmissionNotFound()`

```solidity
error SubmissionNotFound();
```

Reverted when `_validateAcceptSubmission` finds no entry in `taskSubmissionHashes[taskId][worker]`
matching the supplied deliverable hash.

### 6. `ITMPCore` — new event `SelfAward`

```solidity
event SelfAward(
    bytes32 indexed taskId,
    address indexed requester,
    address indexed worker
);
```

Emitted by `acceptSubmission` and `acceptSubmissions` when `worker == requester`. Self-awards are
not blocked — a requester is permitted to do their own work — but they are recorded on-chain so
that reputation indexers can weight them appropriately.

### 7. `ITMPCore` — new event `RequesterReputation`

```solidity
event RequesterReputation(
    bytes32 indexed taskId,
    address indexed requester,
    bytes32 event_,
    uint256 reward,
    uint32 submissionCount,
    bool selfAward
);
```

Emitted at every terminal state of a Bounty or Benchmark task. The `event_` field is one of four
`keccak256`-hashed string constants:

| `event_` value | Emitted from | Condition |
|----------------|-------------|-----------|
| `keccak256("completed")` | `acceptSubmission` / `acceptSubmissions` | Normal acceptance |
| `keccak256("cancelled_after_submissions")` | `cancelTask` | `taskHasSubmissions == true` at cancel time |
| `keccak256("expired_no_action")` | `refundExpired` | `taskHasSubmissions == false` |
| `keccak256("expired_after_rejections")` | `refundExpired` | `taskHasSubmissions == true` |

`submissionCount` is the length of the union of all `taskSubmissionHashes[taskId][*]` entries at
emission time. `selfAward` mirrors the `SelfAward` event; it is `false` for non-acceptance
terminals.

### 8. `acceptSubmission`, `acceptSubmissions`, `cancelTask`, `refundExpired` — `requesterAgentId` parameter

All four functions gain a `uint256 requesterAgentId` trailing parameter. This value is passed
through to `giveFeedback` internally so that requester behavior is attributed to the correct
off-chain agent identity. It does not affect any on-chain state or access control.

---

## Rationale

**Why not events-only?**

Contracts cannot read their own event logs. An events-only approach means enforcement remains
backend-only: the backend would check its indexed `TaskSubmitted` events before permitting an
`acceptSubmission` call. A compromised or bypassed backend removes the protection entirely. The
fix must be on-chain to be trustless.

**Why not a boolean flag per worker?**

A `taskWorkerSubmitted[taskId][worker]` boolean proves that a worker participated but does not
identify which specific hash they committed. The self-award attack is still possible with a flag:
the requester marks themselves as submitted (trivially, since they control the call), then accepts
with an invented hash. The per-worker flag check would pass because the flag is set, but the hash
is still unchecked. The full hash array is required.

**Why store full history instead of only the latest hash?**

Workers on real task markets iterate on their submissions. A requester should be able to accept
an earlier version if it better satisfies the task criteria. Storing only the latest hash would
overwrite prior versions and prevent this. Storing the full array preserves all committed hashes
and lets the requester choose any of them at acceptance time.

**Why not enforce this in the backend only?**

The protocol is intended to be self-enforcing. Any node can independently verify that a
deliverable hash appears in `taskSubmissionHashes[taskId][worker]` without trusting the backend.
Backend-only enforcement is a single point of failure; on-chain enforcement is permanent and
permissionless.

---

## API Changes

- `acceptSubmission(bytes32, address, bytes32)` becomes `acceptSubmission(bytes32, address, bytes32, uint256)` — adds `requesterAgentId`
- `acceptSubmissions(bytes32, address[], uint16[], bytes32[])` becomes `acceptSubmissions(bytes32, address[], uint16[], uint256)` — drops `deliverables[]` array, adds `requesterAgentId`
- `cancelTask(bytes32)` becomes `cancelTask(bytes32, uint256)` — adds `requesterAgentId`
- `refundExpired(bytes32)` becomes `refundExpired(bytes32, uint256)` — adds `requesterAgentId`
- New `RegistryFacet.taskSubmissionHashes(bytes32 taskId, address worker) external view returns (bytes32[] memory)`
- New `GET /api/requester/:address/stats` backend endpoint
- `--deliverable` flag removed from CLI acceptance commands — backend derives the hash from the DB submission record
- New CLI command `taskmarket requester stats <address>`

---

## Affected Files

| File | Change |
|------|--------|
| `src/libraries/LibAppStorage.sol` | Append `taskSubmissionHashes mapping(bytes32 => mapping(address => bytes32[]))` to `AppStorage` |
| `src/interfaces/ITMPCore.sol` | Add `error SubmissionNotFound()`, `event SelfAward(...)`, `event RequesterReputation(...)` |
| `src/facets/CoreFacet.sol` | Push deliverable to `taskSubmissionHashes` in `submitWork`; add `requesterAgentId` to `cancelTask` and `refundExpired`; emit `RequesterReputation` from both |
| `src/facets/AcceptanceFacet.sol` | Verify deliverable in `_validateAcceptSubmission`; remove `deliverables[]` from `acceptSubmissions`; emit `SelfAward` and `RequesterReputation` |
| `src/facets/RegistryFacet.sol` | Add `taskSubmissionHashes` getter |
| `packages/contracts/abi/TaskMarket.json` | Rebuilt after signature changes |
| `apps/backend/src/routers/acceptance.router.ts` | Enforce DB submission record exists before contract call; derive deliverable hash from DB record |
| `apps/backend/src/routers/tasks.router.ts` | Add `requester.stats` query; index `RequesterReputation` events |
| `apps/backend/src/db/schema.ts` | Add `selfAward boolean` to tasks; add `requester_reputation_events` table |
| `apps/backend/drizzle/migrations/` | Migration for `self_award` column and `requester_reputation_events` table |
| `apps/cli/src/commands/task/accept.ts` | Remove `--deliverable` flag |
| `apps/cli/src/commands/task/accept-submissions.ts` | Remove `:<deliverable>` slot from winner spec |
| `apps/cli/src/commands/requester/stats.ts` | New command |
| `packages/shared/src/schemas/task.schemas.ts` | Add `RequesterStatsSchema`, `selfAward` to task schema |
| `packages/contracts/script/DiamondFullUpgrade.s.sol` | All-Replace upgrade script; new signatures already deployed to testnet |
