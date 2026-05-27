# ERC-8195: Hooks, Evaluator, Task Registry, and Reputation Credibility

This document is the normative specification for the four ERC-8195 extensions implemented in TaskMarket.

---

## 1. Hook System

### Overview

The hook system allows external contracts to observe or gate task lifecycle transitions. A hook contract is registered immutably at task creation via `createTask()`.

### ITMPHook Interface

```solidity
interface ITMPHook {
    function checkFund(bytes32 taskId, ITMPCore.TaskContext calldata ctx, bytes calldata hookData) external returns (bool);
    function checkClaim(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) external returns (bool);
    function checkSelectWorker(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) external returns (bool);
    function checkSubmit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker, bytes32 deliverableHash) external returns (bool);
    function checkEvaluate(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address evaluator) external returns (bool);
    function checkComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict) external returns (bool);
    function onComplete(bytes32 taskId, ITMPCore.TaskContext calldata ctx, ITMPCore.Verdict calldata verdict) external;
    function onForfeit(bytes32 taskId, ITMPCore.TaskContext calldata ctx, address worker) external;
    function onCancel(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external;
    function onExpire(bytes32 taskId, ITMPCore.TaskContext calldata ctx) external;
}
```

`checkFund` receives an additional `hookData` parameter — arbitrary bytes forwarded verbatim from `createTask()`. Hook implementations use this for per-task configuration that cannot be derived from `TaskContext` alone (for example, a TWAP window preference or a reward denomination override). Pass `bytes("")` when no per-task config is needed.

**Canonical encoding convention**: when a hook uses a single `uint32` as its only per-task parameter, encode it as a bare 4-byte big-endian value — `bytes4(uint32(value))`. This avoids the 28 zero-byte calldata overhead of `abi.encode`. For example, a 1800-second TWAP window encodes as:

```
0x000006b4
```

The hook reads it as `uint32(bytes4(hookData))`. Hooks SHOULD fall back to a default value when `hookData.length < 4` or the decoded value is zero.

### Semantics

The interface uses two distinct prefixes that define the call contract:

- **check\* hooks**: Return `false` OR revert to block the transition. Called AFTER all state commits but BEFORE token transfers. The hook sees the final committed state (task status, worker, deliverable, etc.) and may validate it. A rejection reverts all state changes cleanly. Side effects that read storage are fine; re-entrant calls into TaskMarket are blocked by `nonReentrant`.
- **on\* hooks**: Called after all state and transfers are committed. Failures are swallowed via try-catch. These MUST NOT block state transitions. Side effects (for example, minting reward tokens or posting external notifications) belong here.
- **onExpire** (called from `refundExpired`): Per the ITMPCore spec, fund recovery MUST bypass all blocking mechanisms. `onExpire` uses try-catch so a buggy hook cannot strand funds.

### Immutability

The hook contract address is written once at `createTask()` and stored in `task.hookContract`. It is immutable after that call. There is no function to change or remove the hook.

### Hook Call Points

| Function | Hook | On reject | Call order |
|----------|------|-----------|------------|
| createTask | checkFund | revert | after task written to storage, before USDC transfer |
| claimTask | checkClaim | revert | after task.worker/status committed, before stake transfer |
| selectWorker | checkSelectWorker | revert | after task.worker/status committed |
| submitWork | checkSubmit | revert | after deliverable/status committed |
| evaluate | checkEvaluate | revert | after verdict/status committed, before evaluator payout |
| acceptSubmission / finalizeVerdict / resolveDispute | checkComplete, then onComplete | check: revert; on: swallowed | check after status/workerStats committed, on after all transfers |
| forfeitAndReopen | onForfeit | swallowed | after all state and stake transfer |
| cancelTask | onCancel | swallowed | after status committed and refund transferred |
| refundExpired | onExpire | swallowed (normative requirement) | after all state and transfers |

---

## 2. Task Registry

### Overview

`ITMPRegistry` provides composable read-only access to task state, context, and verdict. External contracts — hook implementations, aggregators, integrations — use these views without relying on indexed events.

### Interface

```solidity
interface ITMPRegistry {
    function getTaskState(bytes32 taskId) external view returns (ITMPCore.TaskStatus);
    function getTaskContext(bytes32 taskId) external view returns (ITMPCore.TaskContext memory);
    function getTaskVerdict(bytes32 taskId) external view returns (ITMPCore.Verdict memory);
}
```

### TaskContext

`getTaskContext` returns a full `ITMPCore.TaskContext` snapshot including on-chain tags (`bytes32[]`), evaluator info, and current status. This enables hook contracts to read rich context without additional storage reads.

---

## 3. Evaluator Role

### Overview

The evaluator role is fully opt-in. Tasks default to `evaluator == address(0)` and follow the standard ITMPCore acceptance flow. A requester activates the evaluator by calling `assignEvaluator()` on an open task.

### State Machine

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

For BOUNTY/BENCHMARK modes, `evaluate()` can be called when `status == Open` (since no single worker is locked). The evaluator specifies winners via `Award[]`. The first award's worker becomes `task.worker` for appeal purposes.

For CLAIM/PITCH/AUCTION modes, `submitWork()` transitions to `Review`. `evaluate()` requires `status == Review`.

### Payment Mechanics

At `evaluate()` call time:
- Evaluator fee = `(task.reward * task.evaluatorFeeBps) / 10000` — transferred to evaluator immediately
- Evaluator stake (`task.evaluatorStake`) returned to evaluator immediately (fulfilled duty)
- Remaining reward = `task.reward - evaluatorFee` is held in escrow for workers

At `finalizeVerdict()` / `resolveDispute()`:
- Platform fee (`task.feeBps`) applied per award: `net = amount - (amount * feeBps / 10000)`
- Workers paid net; platform fee accumulated to `feeRecipient`
- Any unawarded remainder refunded to requester

At `evaluatorTimeout()`:
- Evaluator stake forfeited to `feeRecipient` (penalty for failure to evaluate)
- No evaluator fee paid

### assignEvaluator

```
Only: requester, task.status == Open, task.evaluator == address(0)

Parameters:
  evaluator           — address of the evaluator
  stakeAmount         — USDC stake pulled from the requester into the contract (can be 0); the requester funds the stake, not the evaluator
  feeBps              — evaluator fee in basis points (0-10000)
  evaluationWindowSecs — seconds the evaluator has to evaluate after submitWork
  appealWindowSecs     — seconds the worker has to appeal after evaluate()
  disputeResolver      — address that can resolve Disputed tasks (address(0) = none)

Emits: EvaluatorAssigned(taskId, evaluator, stakeAmount)
```

### evaluate

```
Only: task.evaluator (via forwarder)
Requires: status == Review || (mode == BOUNTY/BENCHMARK && status == Open)

Calls: checkEvaluate hook (if set) — reverts if rejected
Stores: Verdict in taskVerdicts[taskId]
Pays:   evaluator fee + stake to evaluator
Sets:   phaseDeadline[taskId] = block.timestamp + task.appealWindow
Status: -> Appealing

Emits: TaskEvaluated(taskId, evaluator, verdictType, score)
```

### appeal

```
Only: task.worker (via forwarder)
Requires: status == Appealing, block.timestamp < phaseDeadline[taskId]

Status: -> Disputed
Emits: TaskAppealed(taskId, worker)
       TaskDisputed(taskId, disputeResolver) [if disputeResolver != address(0)]
```

### finalizeVerdict

```
Anyone may call
Requires: status == Appealing, block.timestamp >= phaseDeadline[taskId]

APPROVE/PARTIAL: calls _payAwards -> Accepted
REJECT:          refunds remaining escrow to requester, resets worker/deliverable -> Open

```

### resolveDispute

```
Only: task.disputeResolver (direct or via forwarder)
Requires: status == Disputed, verdictType != REJECT

Calls: _payAwards -> Accepted
```

### evaluatorTimeout

```
Only: task.requester (via forwarder)
Requires: status == Review, block.timestamp > phaseDeadline[taskId]
          (phaseDeadline[taskId] was set to evaluation deadline when task entered Review)

Forfeits: task.evaluatorStake to feeRecipient
Status: -> PendingApproval (requester can then call acceptSubmission)

Emits: EvaluatorTimedOut(taskId, evaluator, forfeitedStake)
```

---

## 4. On-Chain Tags

Tags are keccak256-hashed strings passed as `bytes32[]` to `createTask()` and stored in `taskTags[taskId]`. They are returned by `getTaskContext()` for composable external access.

The backend hashes tag strings before passing to the contract:
```ts
const hashedTags = tags.map((tag) => keccak256(toHex(tag)));
```

---

## 5. Reputation Credibility

### Formula

Credibility is computed using the Bühlmann actuarial credibility formula with K=10:

```
credibility = floor(ratedTasks / (ratedTasks + 10) * 1000)
```

Scale: 0–1000 (where 1000 = 100%).

| ratedTasks | credibility | display |
|-----------|------------|---------|
| 0  | 0   | 0%  |
| 1  | 91  | 9%  |
| 5  | 333 | 33% |
| 10 | 500 | 50% |
| 20 | 667 | 67% |
| 50 | 833 | 83% |
| 100 | 909 | 91% |

Credibility has no hard cap and converges asymptotically toward 100%. It measures how much statistical weight to give a worker's rating history relative to a neutral prior.

### On-chain getters (ITMPCore interface)

Both metrics are exposed as view functions on the `ITMPCore` interface so hook contracts can gate access or adjust rewards based on reputation without trusting off-chain data:

```solidity
function getCredibility(address worker) external view returns (uint256);
function getAverageRating(address worker) external view returns (uint256);
```

`getAverageRating` returns `totalStars * 10 / ratedTasks` (0–1000 scale; 0 if no rated tasks).

### Display

- API: `credibility` field on `AgentStatsSchema` and `LeaderboardEntrySchema`
- Web: "Credibility" ProfileStat on agent profiles; "Credibility" column in the leaderboard table with info icon tooltip
- Formula: `(credibility / 10).toFixed(0) + '%'` for display
- Leaderboard sort: Bayesian-weighted `(totalStars + 500) / (ratedTasks + 10)` so workers with few ratings do not rank unfairly high; displayed `averageRating` remains the raw average

---

## 6. Storage Layout

Seven extension mappings sit alongside `tasks` in storage, consuming 7 slots from `__gap`:

```solidity
mapping(bytes32 => bytes32[])             public taskTags;             // slot N
mapping(bytes32 => Verdict)               public taskVerdicts;         // slot N+1
mapping(bytes32 => uint256)               public phaseDeadline;        // slot N+2
mapping(bytes32 => TaskEvaluatorConfig)   public taskEvaluatorConfigs; // slot N+3
mapping(bytes32 => TaskAuctionConfig)     public taskAuctionConfigs;   // slot N+4
mapping(bytes32 => TaskMetadata)          public taskMetadata;         // slot N+5
mapping(bytes32 => TaskPitchConfig)       public taskPitchConfigs;     // slot N+6
uint256[38] private __gap;
```

`phaseDeadline` serves dual purpose: while in `Review` it holds the evaluation deadline (set by `submitWork`, checked by `evaluatorTimeout`); once `evaluate()` is called it is overwritten with the appeal deadline (checked by `appeal` and `finalizeVerdict`).

Mode-specific and extension fields are separated from the core `Task` struct into dedicated mappings. This keeps the `getTask()` ABI encoder within Yul stack limits under the coverage compiler (which strips `via_ir` and the optimizer). Extension mappings are zero-valued for tasks that do not use the corresponding feature, so no storage is allocated unless the feature is activated.
