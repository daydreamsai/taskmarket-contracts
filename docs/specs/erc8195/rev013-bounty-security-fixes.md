# ERC-8195 Revision 013 — Security-Bounty Fixes (Escrow, Appeal, Auction, Epoch Accounting)

## Motivation

A public Taskmarket security-review bounty surfaced six independently-verified findings across
`CoreFacet`, `EvaluatorFacet`, and the reward-hook stack (`EpochBudget`/`TaskTokenRewardHook`).
Five are fixed by replacing `CoreFacet` and `EvaluatorFacet` in one diamond-cut upgrade step
(this revision, applied via `script/upgrades/Rev013Upgrade.s.sol`); the sixth
(`EpochBudget.release()`'s epoch-mismatch bug, issue #202) is fixed by redeploying the
reward-hook pair instead, since `TaskTokenRewardHook`/`EpochBudget` are not Diamond facets and
are upgraded by a separate script (`script/SwapRewardHook.s.sol`, see ADR-0028) rather than a
`diamondCut`. All six are grouped into this one revision document because they shipped from the
same bounty round and the same review pass, even though they deploy via two different
mechanisms.

---

## Problem 1 — `refundExpired` double-refunds an already-paid evaluator fee (#198)

`CoreFacet.refundExpired` refunded the full `task.reward` on expiry with no check for whether
`EvaluatorFacet.evaluate()` had already paid an evaluator fee out of that same reward. Because
escrow is one pooled USDC balance across all tasks (not accounted per task), a requester could
assign an evaluator (potentially one they controlled), let `evaluate()` pay the fee and move the
task to `Appealing`, then let it expire and call the permissionless `refundExpired` to recover the
*entire original reward* on top of the fee already paid — a repeatable double payment funded from
other tasks' escrow.

## Problem 2 — `rejectSubmission`'s non-submitter fallback phantom-clears the active-submission guard (#199)

`rejectSubmission`'s counter-decrement fell back to `1` for any address, including one that never
submitted work. A requester could call `rejectSubmission(taskId, randomAddress)` against a
throwaway address purely to decrement `taskActiveSubmissionCount`, zeroing it out while a real
worker's submission was still live — bypassing the `SubmissionsExist` guard that `cancelTask`/
`refundExpired` rely on to protect a submitting worker.

## Problem 3 — auction winner is auto-paid on expiry with no deliverable check (#200)

`CoreFacet._refundAuctionClaimed` (reached via `refundExpired` for a `Claimed` auction task) paid
the claiming worker their full stake and marked the task `Accepted` with no check that
`task.deliverable` was ever set. A worker could claim an auction task, submit nothing, and still
be paid once the task expired.

## Problem 4 — an empty-award evaluator verdict permanently blocks appeal (#201)

For Bounty/Benchmark tasks, `EvaluatorFacet.evaluate()` only set `task.worker` when the verdict's
`awards` array was non-empty, but `appeal()` authorized only the address stored in `task.worker`.
A REJECT (or any) verdict issued with an empty awards array left `task.worker` at `address(0)`,
so no real submitter — even one tracked in `taskSubmissionHashes[taskId][worker]` — could ever
appeal it. After the appeal window elapsed, the requester recovered the remaining escrow with the
adverse verdict never having been contestable.

## Problem 5 — `EpochBudget.release()` decrements the wrong epoch's usage (#202)

`EpochBudget.release()` rolled to whatever epoch was *current at release time* and decremented
that epoch's recorded usage, with no record of which epoch the original `checkAndConsume`
reservation actually belonged to. A reservation consumed in epoch N but released after the epoch
rolled to N+1 silently corrupted N+1's unrelated, legitimate usage instead of reversing N's —
undermining the emission-cap accounting the budget exists to enforce.

## Problem 6 — `updateTask` allows a reward increase with no corresponding USDC pull (#203)

`CoreFacet.updateTask` let a requester increase `task.reward` with no code path that pulled the
additional USDC delta into escrow — the increased amount was simply promised, relying entirely on
the forwarder having separately transferred a matching `paymentAmount`, which `updateTask` never
checked. Re-assessed during triage as backend-bug-only rather than externally exploitable
(`updateTask` requires the forwarder, and the only live forwarder caller — `tasks.router.ts`'s
X402-funded reward-increase endpoint — already computes the correct funding delta), which
downgraded the fix from a breaking funding-model change to cheap defense-in-depth. See ADR-0025.

---

## Changes

### 1. `CoreFacet._refundExpiredNormal` — subtract any already-paid evaluator fee (#198)

```solidity
// Before
task.status = ITMPCore.TaskStatus.Expired;
uint256 refundAmount = task.reward;
ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];

// After
ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
uint256 evalFeeAlreadyPaid = 0;
if (
    (task.status == ITMPCore.TaskStatus.Appealing || task.status == ITMPCore.TaskStatus.Disputed)
        && evalCfg.evaluatorFeeBps > 0
) {
    evalFeeAlreadyPaid = (task.reward * evalCfg.evaluatorFeeBps) / 10000;
}
task.status = ITMPCore.TaskStatus.Expired;
uint256 refundAmount = task.reward - evalFeeAlreadyPaid;
```

### 2. `CoreFacet.rejectSubmission` — skip the decrement entirely for a non-submitter (#199)

```solidity
// Before
uint256 workerCount = s.taskSubmissionHashes[taskId][worker].length;
uint256 decrement = workerCount > 0 ? workerCount : 1;
uint256 active = s.taskActiveSubmissionCount[taskId];
s.taskActiveSubmissionCount[taskId] = active > decrement ? active - decrement : 0;

// After
uint256 workerCount = s.taskSubmissionHashes[taskId][worker].length;
if (workerCount > 0) {
    uint256 active = s.taskActiveSubmissionCount[taskId];
    s.taskActiveSubmissionCount[taskId] = active > workerCount ? active - workerCount : 0;
}
```

### 3. `CoreFacet._refundAuctionClaimed` — require a deliverable before auto-paying (#200)

```solidity
// Before
function _refundAuctionClaimed(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private {
    uint256 fee = (task.stakeAmount * task.feeBps) / 10000;
    uint256 workerPayment = task.stakeAmount - fee;
    task.status = ITMPCore.TaskStatus.Accepted;
    // ... pays workerPayment unconditionally

// After
function _refundAuctionClaimed(bytes32 taskId, ITMPCore.Task storage task, AppStorage storage s) private {
    if (task.deliverable == bytes32(0)) {
        // No deliverable was ever submitted -- full refund to the requester, matching
        // the non-auction _refundExpiredNormal path, instead of auto-paying the stake.
        task.status = ITMPCore.TaskStatus.Expired;
        uint256 refundAmount = task.reward;
        address requesterAddr = task.requester;

        // An evaluator can be assigned to an auction task while still Open; since the task
        // never reaches Review without a deliverable, evaluate() never runs and never
        // returns the evaluator's stake -- forfeit it here instead of stranding it.
        ITMPCore.TaskEvaluatorConfig storage evalCfg = s.taskEvaluatorConfigs[taskId];
        address timedOutEvaluator = evalCfg.evaluator;
        uint256 evaluatorForfeited = evalCfg.evaluatorStake;
        if (evaluatorForfeited > 0) {
            evalCfg.evaluatorStake = 0;
            evalCfg.evaluator = address(0);
            s.totalFeesCollected += evaluatorForfeited;
        }

        if (!s.usdcToken.transfer(requesterAddr, refundAmount)) revert ITMPCore.RefundFailed();
        if (evaluatorForfeited > 0) {
            if (!s.usdcToken.transfer(s.feeRecipient, evaluatorForfeited)) revert ITMPCore.ForfeitTransferFailed();
            emit ITMPEvaluator.EvaluatorTimedOut(taskId, timedOutEvaluator, evaluatorForfeited);
        }
        emit ITMPCore.TaskExpired(taskId, requesterAddr, refundAmount);
        LibTaskMarket._onExpireHooks(taskId, s);
        return;
    }
    uint256 fee = (task.stakeAmount * task.feeBps) / 10000;
    // ... unchanged paid path for tasks with a real deliverable
```

### 4. `EvaluatorFacet.appeal` — fall back to the per-worker submission record when `task.worker` is unset (#201)

```solidity
// Before
address worker = LibTaskMarket._effectiveSender(s);
ITMPCore.Task storage task = s.tasks[taskId];
if (worker != task.worker) revert ITMPCore.NotWorker();

// After
address worker = LibTaskMarket._effectiveSender(s);
ITMPCore.Task storage task = s.tasks[taskId];
// Empty-awards verdicts leave task.worker unset even though real submitters exist in
// taskSubmissionHashes. Gated on task.worker == address(0) so this only applies when no
// worker was ever recorded -- once a verdict has awarded someone, only that worker may
// appeal (otherwise an unrelated past submitter could stall a legitimately-awarded
// worker's payout by appealing a verdict they were never part of).
bool authorized = worker == task.worker;
if (!authorized && task.worker == address(0) && (task.mode == BOUNTY || task.mode == BENCHMARK)) {
    authorized = s.taskSubmissionHashes[taskId][worker].length > 0;
}
if (!authorized) revert ITMPCore.NotWorker();
```

### 5. `EpochBudget.checkAndConsume`/`release` — thread the consumed epoch through (#202)

```solidity
// Before
function checkAndConsume(address requester, address worker, uint256 amount) external onlyHook {
    uint64 epoch = _rollEpochIfStale();
    // ...
}
function release(address requester, address worker, uint256 amount) external onlyHook {
    uint64 epoch = _rollEpochIfStale();
    // decrements whatever epoch is current *now*, not the one consumption happened in
}

// After
function checkAndConsume(address requester, address worker, uint256 amount)
    external
    onlyHook
    returns (uint64 epoch)
{
    epoch = _rollEpochIfStale();
    // ...
}
function release(address requester, address worker, uint256 amount, uint64 consumedEpoch) external onlyHook {
    uint64 epoch = _rollEpochIfStale();
    if (epoch != consumedEpoch) return; // epoch rolled past -- its usage already reset, no-op
    // ...
}
```

`TaskTokenRewardHook` was updated to store `consumedEpoch` on `RewardState` (and on the
pitch/auction reservation path) and pass it back into every `release()` call. This is a *separate*
deployment from items 1-4: `TaskTokenRewardHook`/`EpochBudget` are not Diamond facets, so this
ships by deploying a fresh hook + `EpochBudget` pair and cutting the Diamond's default hooks over
to them (`script/SwapRewardHook.s.sol`), reusing the existing `RewardVault`, per ADR-0028 -- not
by a `diamondCut` on `CoreFacet`/`EvaluatorFacet`.

### 6. `CoreFacet.updateTask` — balance-sufficiency check on reward increase (#203)

```solidity
// Before
uint256 refund = 0;
if (newReward != 0 && newReward != task.reward) {
    refund = newReward < task.reward ? task.reward - newReward : 0;
    task.reward = newReward;
    if (task.mode == AUCTION) s.taskAuctionConfigs[taskId].maxPrice = newReward;
}

// After
uint256 refund = 0;
if (newReward != 0 && newReward != task.reward) {
    if (newReward < task.reward) {
        refund = task.reward - newReward;
    } else {
        // Defense-in-depth: catches the acute failure mode where no funding transfer
        // happened at all (e.g. a relayed paymentAmount of 0 from a backend bug) instead
        // of silently promising a reward the Diamond cannot pay. Does not prove this
        // specific increase was funded -- escrow is one pooled balance across every task.
        if (s.usdcToken.balanceOf(address(this)) < newReward) {
            revert ITMPCore.RewardIncreaseNotFunded();
        }
    }
    task.reward = newReward;
    if (task.mode == AUCTION) s.taskAuctionConfigs[taskId].maxPrice = newReward;
}
```

### 7. `ITMPCore` — new `RewardIncreaseNotFunded` error

```solidity
error RewardIncreaseNotFunded();
```

### 8. `script/upgrades/Rev013Upgrade.s.sol` — diamond-cut upgrade step

Selector set for both `CoreFacet` and `EvaluatorFacet` is unchanged (none of items 1, 2, 3, 4, 6
add, remove, or rename an external/public function) -- a pure `Replace` on both facets.
`EXPECTED_PRE_VERSION = 12; TARGET_VERSION = 13;`.

---

## Rationale

**Why subtract the evaluator fee instead of blocking `refundExpired` from `Appealing`/`Disputed`
entirely (#198)?**

Blocking those states outright would strand the task indefinitely if the appeal window closes
with no resolution path. Subtracting the already-paid amount keeps `refundExpired` usable while
making the refund reflect the task's actual remaining liability.

**Why fully skip the decrement for a non-submitter instead of tracking "rejected but never
submitted" separately (#199)?**

A worker with zero recorded submissions has nothing in `taskActiveSubmissionCount` to reverse --
crediting a decrement for them is not fixing a real accounting gap, it is the exploit itself.
Skipping the decrement is the minimal change that removes the phantom-clear path with no new
state to maintain.

**Why forfeit the evaluator's stake in the no-deliverable auction path instead of returning it to
the evaluator, or leaving it in escrow (#200 follow-up)?**

Returning it would reward an evaluator who never issued a verdict. Leaving it in escrow strands
funds with no path back to anyone. Forfeiting to `feeRecipient` mirrors the existing
evaluator-never-acted forfeiture `_refundExpiredNormal` already applies in the equivalent
non-auction case, so this isn't a new policy, just closing a gap where the auction path skipped it.

**Why gate the appeal fallback on `task.worker == address(0)` instead of authorizing any past
submitter unconditionally (#201)?**

An unconditional fallback would let a submitter who was never awarded anything appeal a verdict
that already awarded a *different* worker, stalling that worker's payout in `Disputed` with no
guaranteed resolution path if the task has no dispute resolver. Gating on `task.worker` still
being unset restricts the fallback to exactly the case the issue describes.

**Why require the caller to pass back `consumedEpoch` instead of having `EpochBudget` remember it
internally, keyed by task (#202)?**

`EpochBudget` has no concept of "task" -- it only ever sees `(requester, worker, amount)` from the
hook. Threading the epoch through the caller (`TaskTokenRewardHook`, which already tracks
per-task `RewardState`) avoids adding a second, redundant task-keyed mapping inside `EpochBudget`
itself for data the caller already has a natural place to store.

**Why a balance check instead of an explicit funded-delta transfer for `updateTask`'s reward
increase (#203)?**

An explicit transfer would require a breaking change to `updateTask`'s calling convention (adding
a payment-pulling step mirroring `createTask`), for a path whose only real-world caller already
computes and forwards the correct funding delta. A balance-sufficiency check is non-breaking,
requires no backend change, and still catches the acute failure mode (a relayed call with no
funding at all) -- see ADR-0025 for the full triage.

---

## API Changes

- New error: `ITMPCore.RewardIncreaseNotFunded()` -- `updateTask` now reverts with this if a
  reward increase isn't covered by the Diamond's current USDC balance.
- `EpochBudget.checkAndConsume` now returns `uint64 epoch` (previously `void`); `release` gains a
  required fourth parameter, `uint64 consumedEpoch`. Not Diamond-facing -- this only affects a
  custom `ITMPHook` implementation that calls `EpochBudget` directly (the reference
  `TaskTokenRewardHook` is updated to match).
- No change to any Diamond-facing (`CoreFacet`/`EvaluatorFacet`) function signature or event.
- Off-chain behavior changes worth noting for API consumers: `refundExpired` on an
  `Appealing`/`Disputed` task now refunds `reward - evalFee` instead of the full `reward`;
  `refundExpired` on a `Claimed` auction task with no deliverable now refunds the requester
  instead of paying the worker; `appeal()` is now callable by a Bounty/Benchmark task's real
  submitter even when `task.worker` was left unset by an empty-awards verdict.

## Affected Files

| File | Change |
|------|--------|
| `src/facets/CoreFacet.sol` | `_refundExpiredNormal` (#198), `rejectSubmission` (#199), `_refundAuctionClaimed` (#200 + evaluator-stake-forfeiture follow-up), `updateTask` (#203) |
| `src/facets/EvaluatorFacet.sol` | `appeal` empty-awards fallback, gated on `task.worker == address(0)` (#201) |
| `src/interfaces/ITMPCore.sol` | Add `error RewardIncreaseNotFunded()` |
| `src/hooks/EpochBudget.sol` | `checkAndConsume` returns the consumed epoch; `release` requires it back and no-ops if the epoch has rolled past (#202) |
| `src/hooks/TaskTokenRewardHook.sol` | Track `consumedEpoch` per task/reservation; pass it to every `release()` call; zero-initialize `consumeEpoch` local (slither uninitialized-local fix) |
| `script/upgrades/Rev013Upgrade.s.sol` | New upgrade-step script -- pure `Replace` on `CoreFacet` + `EvaluatorFacet` |
| `script/SwapRewardHook.s.sol` | New script -- separate (non-diamond-cut) redeploy of `EpochBudget`/`TaskTokenRewardHook`, reusing the existing `RewardVault`, per ADR-0028 |
| `test/TaskMarket.t.sol` | Regression coverage for #198, #199, #200 (including the evaluator-forfeiture follow-up), #201 (including the narrowed-gate follow-up), #203 |
| `test/EpochBudget.t.sol`, `test/TaskTokenRewardHook.t.sol` | Regression coverage for #202 |
| `test/SwapRewardHook.t.sol` | New file -- coverage for the reward-hook cutover script |
| `docs/adr/0025-update-task-reward-increase-funding.md` | ADR recording the #203 triage/decision |
| `docs/adr/0028-reward-hook-upgrade-leaves-old-hook-authorized-until-drained.md` | ADR recording the #202 reward-hook cutover decision |

## References

- Issues #198, #199, #200, #201, #202, #203 (all filed from the same public security-review
  bounty; see each issue's Attribution section for the reporting agentId(s)).
- ADR-0025 (`updateTask` reward-increase balance-sufficiency check).
- ADR-0028 (reward-hook upgrade cutover; where #202's fix actually deploys).
