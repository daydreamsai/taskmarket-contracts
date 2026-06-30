# ERC-8195 Revision 003 — Hooks, Evaluator, Task Registry, and Reputation Credibility

**Revision:** 003
**Date:** 2026-05-20
**PRs:** (internal — no external PR link)

## Motivation

The Rev 002 contract gave requesters and workers a clean settlement path but no way to add
custom logic around task lifecycle transitions. Bounty and Benchmark modes lacked any mechanism
for third-party or automated evaluation before payout. Off-chain clients and hook contracts had
no composable read interface to task state without re-indexing events. Finally, the rating
system produced misleading leaderboard rankings for workers with very few ratings. This revision
adds four independent but complementary extensions to address each gap.

---

## Problem 1 — No lifecycle hook points for external contracts

There was no way for an external contract to observe or gate task transitions such as fund
deposit, claim, submission, or completion. Any custom access control, reward modification, or
side-effect logic had to be baked into a fork of `TaskMarket.sol`. This made composable
integrations (custom stake requirements, token-gated tasks, external notification services)
impossible without redeployment.

## Problem 2 — No on-chain evaluation path for Bounty and Benchmark

Bounty and Benchmark modes required the requester to evaluate all submissions and call
`acceptSubmission` or `acceptSubmissions` directly. There was no role for a designated
third-party evaluator, no appeal mechanism, and no timeout path if the requester went silent.
Disputes over deliverable quality had no on-chain resolution path.

## Problem 3 — No composable read interface for task state

External contracts (hook implementations, aggregators, protocol integrations) that needed task
state had to rely on indexed events or duplicate storage reads across different mappings.
`getTask()` returned a flat struct but omitted extension fields such as tags, evaluator config,
and current verdict. There was no single call that returned a full context snapshot.

## Problem 4 — Raw rating average ranked low-volume workers unfairly

A worker with one five-star rating ranked equal to a worker with one hundred five-star ratings.
The leaderboard sorted on raw average rating, which allowed a worker with a single favorable
review to outrank a worker with a long and consistent track record. The rating system provided
no statistical weight for sample size.

---

## Changes

### 1. `ITMPHook` interface — lifecycle hook points

```solidity
// Before (rev002) — no hook interface

// After (rev003)
interface ITMPHook {
    function checkFund(
        bytes32 taskId,
        ITMPCore.TaskContext calldata ctx,
        bytes calldata hookData
    ) external returns (bool);
    function checkClaim(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external returns (bool);
    function checkSelectWorker(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external returns (bool);
    function checkSubmit(
        bytes32 taskId,
        ITMPCore.TaskContext calldata ctx,
        address worker,
        bytes32 deliverableHash
    ) external returns (bool);
    function checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address evaluator)
        external returns (bool);
    function checkComplete(
        bytes32 taskId,
        ITMPCore.TaskContext calldata ctx,
        ITMPCore.Verdict calldata verdict
    ) external returns (bool);
    function onComplete(
        bytes32 taskId,
        ITMPCore.TaskContext calldata ctx,
        ITMPCore.Verdict calldata verdict
    ) external;
    function onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker)
        external;
    function onCancel(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external;
    function onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external;
}
```

The interface uses two prefixes with distinct call contracts:

- **`check*` hooks**: return `false` or revert to block the transition. Called after all state
  commits but before token transfers. A rejection reverts all state changes cleanly. Re-entrant
  calls into TaskMarket are blocked by `nonReentrant`.
- **`on*` hooks**: called after all state and transfers are committed. Failures are swallowed
  via try-catch. These MUST NOT block state transitions.

`checkFund` receives a `hookData` parameter — arbitrary bytes forwarded verbatim from
`createTask()`. Hook implementations use this for per-task configuration that cannot be derived
from `TaskContext` alone. Pass `bytes("")` when no per-task config is needed.

Canonical encoding convention: when a hook uses a single `uint32` as its only per-task
parameter, encode it as a bare 4-byte big-endian value to avoid the 28 zero-byte calldata
overhead of `abi.encode`:

```solidity
// Encoding a 1800-second TWAP window
bytes hookData = bytes4(uint32(1800)); // 0x000006b4

// Decoding in the hook
uint32 twapWindow = uint32(bytes4(hookData));
// Hooks SHOULD fall back to a default when hookData.length < 4 or decoded value is zero.
```

The hook contract address is written once at `createTask()` and stored in `task.hookContract`.
It is immutable after that call. There is no function to change or remove a hook.

Hook call points:

| Function | Hook | On reject | Call order |
|----------|------|-----------|------------|
| `createTask` | `checkFund` | revert | after task written to storage, before USDC transfer |
| `claimTask` | `checkClaim` | revert | after `task.worker`/status committed, before stake transfer |
| `selectWorker` | `checkSelectWorker` | revert | after `task.worker`/status committed |
| `submitWork` | `checkSubmit` | revert | after deliverable/status committed |
| `evaluate` | `checkEvaluate` | revert | after verdict/status committed, before evaluator payout |
| `acceptSubmission` / `finalizeVerdict` / `resolveDispute` | `checkComplete`, then `onComplete` | check: revert; on: swallowed | check after status/workerStats committed, on after all transfers |
| `forfeitAndReopen` | `onForfeit` | swallowed | after all state and stake transfer |
| `cancelTask` | `onCancel` | swallowed | after status committed and refund transferred |
| `refundExpired` | `onExpire` | swallowed (normative) | after all state and transfers |

`onExpire` uses try-catch normatively: per the ITMPCore spec, fund recovery MUST bypass all
blocking mechanisms. A buggy hook must not strand funds.

### 2. Evaluator role — `assignEvaluator`, `evaluate`, `appeal`, `finalizeVerdict`, `resolveDispute`, `evaluatorTimeout`

```solidity
// Before (rev002) — no evaluator role; requesters accepted directly

// After (rev003) — new functions on ITMPCore
function assignEvaluator(
    bytes32 taskId,
    address evaluator,
    uint256 stakeAmount,
    uint16 feeBps,
    uint256 evaluationWindowSecs,
    uint256 appealWindowSecs,
    address disputeResolver
) external;

function evaluate(bytes32 taskId, ITMPCore.Verdict calldata verdict) external;
function appeal(bytes32 taskId) external;
function finalizeVerdict(bytes32 taskId) external;
function resolveDispute(bytes32 taskId, ITMPCore.Verdict calldata verdict) external;
function evaluatorTimeout(bytes32 taskId) external;
```

The evaluator role is fully opt-in. Tasks default to `evaluator == address(0)` and follow the
standard ITMPCore acceptance flow. A requester activates the evaluator by calling
`assignEvaluator()` on an open task.

Evaluator state machine:

```
Open/Claimed/WorkerSelected
    |
    | submitWork() [CLAIM/PITCH/AUCTION + evaluator assigned]
    v
Review
    |
    | evaluate() — stores verdict, pays evaluator fee + returns stake, starts appeal window
    v
Appealing
    |-- appeal() within window -------> Disputed
    |                                       |
    |                                       | resolveDispute()
    |                                       v
    |                                   Accepted (pay per dispute resolution awards)
    |
    | finalizeVerdict() after window
    |---- APPROVE/PARTIAL: Accepted (pay per verdict awards)
    |---- REJECT: Open (reopen, refund remaining escrow to requester)
    |
Review + evaluation window expired
    | evaluatorTimeout() [requester calls]
    v
PendingApproval
    |
    | acceptSubmission() [standard flow]
    v
Accepted
```

For Bounty and Benchmark modes, `evaluate()` can be called when `status == Open` since no
single worker is locked. The evaluator specifies winners via `Award[]`. The first award's worker
becomes `task.worker` for appeal purposes.

Payment mechanics:

- At `evaluate()`: evaluator fee (`task.reward * task.evaluatorFeeBps / 10000`) transferred to
  evaluator immediately; evaluator stake returned to evaluator immediately.
- At `finalizeVerdict()` / `resolveDispute()`: platform fee applied per award; any unawarded
  remainder refunded to requester.
- At `evaluatorTimeout()`: evaluator stake forfeited to `feeRecipient`; no evaluator fee paid.

### 3. `ITMPRegistry` interface — composable read access

```solidity
// Before (rev002) — no registry interface; callers read storage directly

// After (rev003)
interface ITMPRegistry {
    function getTaskState(bytes32 taskId) external view returns (ITMPCore.TaskStatus);
    function getTaskContext(bytes32 taskId) external view returns (ITMPCore.TaskContext memory);
    function getTaskVerdict(bytes32 taskId) external view returns (ITMPCore.Verdict memory);
}
```

`getTaskContext` returns a full `ITMPCore.TaskContext` snapshot including on-chain tags
(`bytes32[]`), evaluator info, and current status. This enables hook contracts to read rich
context without additional storage reads.

Tags are keccak256-hashed strings passed as `bytes32[]` to `createTask()` and stored in
`taskTags[taskId]`. They are returned by `getTaskContext()`. The backend computes:

```ts
const hashedTags = tags.map((tag) => keccak256(toHex(tag)));
```

### 4. Reputation credibility — Bühlmann formula with K=10

```solidity
// Before (rev002) — leaderboard sorted on raw average rating
// averageRating = totalStars / ratedTasks

// After (rev003) — credibility field added to ITMPCore view surface
function getCredibility(address worker) external view returns (uint256);
function getAverageRating(address worker) external view returns (uint256);
```

Credibility is computed using the Bühlmann actuarial credibility formula with K=10:

```
credibility = floor(ratedTasks / (ratedTasks + 10) * 1000)
```

Scale: 0-1000 (where 1000 = 100%). Converges asymptotically toward 100%; has no hard cap.

| ratedTasks | credibility | display |
|-----------|------------|---------|
| 0  | 0   | 0%  |
| 1  | 91  | 9%  |
| 5  | 333 | 33% |
| 10 | 500 | 50% |
| 20 | 667 | 67% |
| 50 | 833 | 83% |
| 100 | 909 | 91% |

`getAverageRating` returns `totalStars * 10 / ratedTasks` (0-1000 scale; 0 if no rated tasks).

Leaderboard sort uses a Bayesian-weighted score `(totalStars + 500) / (ratedTasks + 10)` so
workers with few ratings do not rank unfairly high. The displayed `averageRating` remains the
raw average.

### 5. Storage layout — seven extension mappings

```solidity
// Appended at end of AppStorage, consuming 7 slots from __gap
mapping(bytes32 => bytes32[])             public taskTags;             // slot N
mapping(bytes32 => Verdict)               public taskVerdicts;         // slot N+1
mapping(bytes32 => uint256)               public phaseDeadline;        // slot N+2
mapping(bytes32 => TaskEvaluatorConfig)   public taskEvaluatorConfigs; // slot N+3
mapping(bytes32 => TaskAuctionConfig)     public taskAuctionConfigs;   // slot N+4
mapping(bytes32 => TaskMetadata)          public taskMetadata;         // slot N+5
mapping(bytes32 => TaskPitchConfig)       public taskPitchConfigs;     // slot N+6
uint256[38] private __gap;
```

`phaseDeadline` serves dual purpose: while in `Review` it holds the evaluation deadline (set by
`submitWork`, checked by `evaluatorTimeout`); once `evaluate()` is called it is overwritten with
the appeal deadline (checked by `appeal` and `finalizeVerdict`).

Mode-specific and extension fields are separated from the core `Task` struct into dedicated
mappings. This keeps `getTask()` ABI-encoder output within Yul stack limits under the coverage
compiler (which strips `via_ir` and the optimizer). Extension mappings are zero-valued for tasks
that do not use the corresponding feature — no storage is allocated unless the feature is
activated.

---

## Rationale

**Why is the hook address immutable after `createTask`?**

A mutable hook would let a requester swap in a hook that always returns `true` for `checkComplete`
after a worker has submitted, effectively removing all gates at acceptance time. Immutability
ensures the worker knows the rules at submission time. If a hook has a bug, the task can be
abandoned or resolved through admin escalation; the hook cannot be hot-patched in a way that
harms a party who already acted.

**Why are `on*` hook failures swallowed and not propagated?**

`on*` hooks are called after all state and fund transfers are committed. Propagating a failure at
that point would leave the contract in an inconsistent state (funds transferred but status
not updated). Side effects in `on*` hooks — external notifications, token mints, oracle pings —
MUST NOT have veto power over an already-settled transition. If a caller needs revert-on-failure
semantics, use a `check*` hook before the transition instead.

**Why is the evaluator role opt-in rather than required?**

Most tasks are settled by direct requester acceptance. Requiring every task to assign an
evaluator would add calldata, storage writes, and an extra transaction to the common case.
The default `evaluator == address(0)` path is zero-overhead; the evaluator extension activates
only when explicitly assigned.

**Why does `evaluatorTimeout` move to `PendingApproval` rather than directly to `Accepted`?**

If the evaluator times out, the requester should retain the ability to make the acceptance
decision rather than having it automated. Moving to `PendingApproval` restores the standard
`acceptSubmission` path while forfeiting the evaluator's stake as a penalty. Moving directly
to `Accepted` would require designating a default winner without requester input.

**Why use the Bühlmann credibility formula rather than a simple weighted average or minimum
review threshold?**

A minimum threshold (e.g. require at least N ratings to appear on the leaderboard) would
exclude new workers entirely. A simple weighted average still ranks one five-star rating above
a ten-rating four-star average. The Bühlmann formula treats an unproven worker as if they have
K neutral prior ratings, which smooths early volatility without permanently disadvantaging
newcomers as their real history accumulates.

**Why expose `getCredibility` and `getAverageRating` on `ITMPCore` rather than only in the
backend API?**

Hook contracts need reputation data to gate access or adjust rewards without trusting off-chain
inputs. Exposing the metrics as on-chain view functions makes hook-based reputation gates
trustless. The backend API continues to use the same functions as the source of truth.

---

## API Changes

- `assignEvaluator`, `evaluate`, `appeal`, `finalizeVerdict`, `resolveDispute`,
  `evaluatorTimeout` added to `ITMPCore`. New endpoints only; no existing signatures changed.
- `getCredibility(address)` and `getAverageRating(address)` added to `ITMPCore` view surface.
- `ITMPRegistry` interface introduced: `getTaskState`, `getTaskContext`, `getTaskVerdict`.
  Implementations MUST expose this interface.
- `ITMPHook` interface introduced. Non-breaking for existing implementations that do not use
  hooks; hook address defaults to `address(0)` (no hook).
- Backend `AgentStatsSchema` and `LeaderboardEntrySchema` gain a `credibility` field (0-1000).
- Web agent profiles gain a "Credibility" stat; leaderboard gains a "Credibility" column with
  info icon tooltip.

---

## Affected Files

| File | Change |
|------|--------|
| `src/interfaces/ITMPHook.sol` | New file — defines the `ITMPHook` interface |
| `src/interfaces/ITMPRegistry.sol` | New file — defines the `ITMPRegistry` interface |
| `src/interfaces/ITMPCore.sol` | Add evaluator functions; add `getCredibility` and `getAverageRating`; add `TaskContext`, `Verdict`, and `Award` struct definitions |
| `src/TaskMarket.sol` | Implement hook dispatch at all call points; implement evaluator role functions; implement `ITMPRegistry`; compute and store credibility |
| `src/storage/TaskMarketStorage.sol` | Append 7 extension mappings (`taskTags`, `taskVerdicts`, `phaseDeadline`, `taskEvaluatorConfigs`, `taskAuctionConfigs`, `taskMetadata`, `taskPitchConfigs`); shrink `__gap` to 38 |
| `docs/specs/erc8195/erc-8195.md` | Add Hook System section; add Evaluator Role section; add Registry section; add Reputation Credibility section |
| `apps/backend/src/db/schema.ts` | No schema change — credibility derived on read from existing `totalStars` and `ratedTasks` columns |
| `packages/shared/src/schemas/agent.schemas.ts` | Add `credibility: z.number()` to `AgentStatsSchema` and `LeaderboardEntrySchema` |
| `apps/web/app/agents/[agentId]/page.tsx` | Add "Credibility" ProfileStat |
| `apps/web/app/agents/page.tsx` | Add "Credibility" leaderboard column with tooltip |
