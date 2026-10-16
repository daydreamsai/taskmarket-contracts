# Rev025 -- settlement terms, review window, claim release and bounded awards

## Status

Specified. Not yet implemented.

## Problem

- **Terms have no home.** Each settlement term so far has been a one-off field with its own
  storage, event and validation (`stakeRequired` and `stakeBps` on `Task` in rev014, the evaluator
  config in rev017, the auction and pitch configs). rev025 adds eight more.
- **Terms change after commitment.** `updateTask` and `assignEvaluator` work after a worker has
  claimed, been selected or submitted, so a requester can change what a worker agreed to.
- **Delivered work is refunded.** On a Claim or Pitch task without an evaluator, `submitWork`
  leaves the task `Claimed` or `WorkerSelected` with a deliverable. After `expiryTime`,
  `acceptSubmission` reverts `TaskIsExpired` and anyone can call `refundExpired`, which refunds the
  requester in full. A worker who delivered can lose the whole reward to a requester who did
  nothing. A delivered Auction is the opposite: it is paid at expiry with no time to review a
  delivery made just before it.
- **Bounties never have to be decided.** A Bounty or Benchmark requester can reject every
  submission after expiry and then refund: the work is seen and the money returned with no
  decision ever forced.
- **The evaluator is paid before appeal.** `evaluate` pays the evaluator fee on any verdict, before
  the appeal window, so an appeal that overturns a reject cannot recover it.
- **Claim stakes are not enforced.** `claimTask` records any `stakeAmount` from calldata and never
  checks it against `stakeBps`, nor checks that the forwarder actually pulled that amount.
- **Forfeits pay the wrong party and kill the task.** `forfeitAndReopen` sends the stake to the fee
  recipient, not the requester whose task was held up, and reopens the task with its past
  `expiryTime`, so every new claim reverts `TaskIsExpired`.
- **A worker cannot give a claim back.** The only exits are delivering or being forfeited at expiry.
- **Anyone can be rated.** `rateTask` on an Accepted Bounty or Benchmark only checks
  `worker != address(0)`, so one accepted task can rate any number of unrelated addresses.
- **Reward-hook reserve release can orphan capacity.** `TaskTokenRewardHook._releaseReserve`
  clears its own state, calls `RewardVault.release` and `EpochBudget.release` in a swallowing
  `try`/`catch`, and emits `RewardReserveReleased` either way. A failed call leaves vault capacity
  reserved for a task the hook no longer tracks.
- **Rejecting delivered work is free.** Nothing defines what a requester gives up by rejecting a
  delivery the requester has already seen, nor what a pitch or auction does after a rejection.
- **Winner lists are unbounded.** `acceptSubmissions` loops over `workers` with no length bound and
  an O(n^2) duplicate check; an oversized list can exceed the block gas limit and leave the task's
  escrow undecidable.

## Change

### Storage

Appended to `AppStorage` after `minFeedbackGas` (rev024), in this order. No existing field moves.

```solidity
mapping(bytes32 => ITMPCore.TaskTerms) taskTerms;
mapping(bytes32 => ITMPCore.TaskClock) taskClocks;
mapping(bytes32 => mapping(address => bool)) taskAwarded;
```

Any later rev025 mapping comes after these three.

`TaskTerms` occupies one storage slot:

```solidity
enum PenaltyTo { Requester, Protocol }
enum ReleaseAllowed { Default, Allowed, Disallowed }
enum RejectOutcome { Default, Reopen, Refund }

struct TaskTerms {
    uint8 version;              // 0 = not yet normalized; 1 = rev025
    bool stakeRequired;
    uint16 stakeBps;
    PenaltyTo penaltyTo;
    uint32 reviewWindowSecs;    // 0 = protocol default
    uint32 decisionWindowSecs;  // 0 = protocol default
    uint32 reopenExtensionSecs; // 0 = protocol default
    ReleaseAllowed releaseAllowed;
        uint16 releaseGraceBps;     // stored as grace + 1: 0 = default, 1 = no grace, 1001 = 10%
    RejectOutcome rejectOutcome;
        uint16 rejectFeeBps;        // stored as fee + 1: 0 = default, 1 = no fee, 2001 = 20%
    uint8 maxRevisions;         // stored as value + 1: 0 = default, 1 = none, 3 = two
}

struct TaskClock {
    uint64 deliveredAt;         // 0 = no undecided delivery
        uint64 decisionStartAt;     // set only by normalizeTerms; 0 otherwise
    uint8 revisionsUsed;
}
```

The field widths are the implementation's choice so long as the struct stays in one slot; the
field order and encodings above are fixed. Four terms use explicit encodings because zero is a
meaningful value for them: `releaseAllowed` distinguishes "use the default" from "allowed" and
"disallowed", and `releaseGraceBps`, `rejectFeeBps` and `maxRevisions` store the value plus one so that
"no grace", "no fee" and "no revisions" are expressible. The struct uses 24 of its 32 bytes.
`penaltyTo` is an enum rather than an address so the term fits in the same slot and cannot name an
arbitrary third party.

Protocol defaults:

| Term | Default | Bounds |
| --- | --- | --- |
| `reviewWindowSecs` | 72 hours | 24 hours to 30 days |
| `decisionWindowSecs` | 7 days | 24 hours to 30 days |
| `reopenExtensionSecs` | 72 hours | 24 hours to 30 days |
| `releaseAllowed` | Allowed | -- |
| `releaseGraceBps` | 10% (stored 1001) | 0% to 100% (stored 1 to 10001) |
| `penaltyTo` | Requester | -- |
| `rejectOutcome` | Claim: Reopen; Pitch: Reopen (back to selection); Auction: Refund | Auction accepts only Refund |
| `rejectFeeBps` | 20% (stored 2001) | 0% to 50% (stored 1 to 5001) |
| `maxRevisions` | 2 (stored 3) | 0 to 5 (stored 1 to 6) |

The bounds are admin-settable and lazily defaulted the way `minAppealWindowSecs` is: a zero stored
bound reads as the value above. The defaults can move inside the bounds without a revision.

`claimedAt` is not duplicated. rev025 reads the existing `taskMetadata[taskId].claimedAt`. Its
documentation changes from "write-once" to "cleared whenever the task returns to Open":
`forfeitAndReopen` already clears it, and `rejectDelivery` and `releaseClaim` do the same.

`Task.stakeRequired` and `Task.stakeBps` stay in `Task` as dead storage. `getTask` keeps returning
their creation values; after a task is normalized, no settlement code reads them.

### Reading terms

`LibTerms.terms(taskId)` is the only reader of `taskTerms`. On a non-terminal task at version 0 it
first writes a version 1 record: `stakeRequired` and `stakeBps` copied from `Task`, every other term
the protocol default. Terminal pre-rev025 tasks are never normalized. Settlement code passes the
result as one `TaskTerms storage` reference, and each terminal path settles in its own
`LibSettlement` function, so every facet compiles within the coverage build's stack limit. Every
new inline-assembly block is annotated `memory-safe`, as rev024's are.

### Functions

Every function below that a worker or requester calls goes through the trusted forwarder and takes
the actor from `pgtrSender`, as existing task functions do, unless marked permissionless.

#### `createTask(..., TaskTerms terms)` (new overload)

- **Access:** any requester, through the forwarder.
- **Preconditions:** the existing `createTask` checks; `terms` is validated and reverts
  `InvalidTerms` when a nonzero window term is outside its bounds, `releaseGraceBps` exceeds 10001,
  `stakeBps` exceeds 5000, half the reward (`StakeBpsTooHigh`, on both `createTask` overloads), `rejectFeeBps` is
  outside its bounds, or `rejectOutcome` is `Reopen` on an auction.
- **Effects:** stores `terms` with `version = 1`; the Task's legacy `stakeRequired` and `stakeBps`
  are written from the same values.
- **Events:** the existing creation events, then `TaskTermsSet(taskId, terms)`.

#### `createTask(...)` (existing selector)

Becomes a wrapper that passes the protocol defaults (with its own `stakeRequired` and `stakeBps`)
into the same internal function, so it also emits `TaskTermsSet`. It is removed in the revision
after rev025.

#### Freeze rule

`updateTask`, `assignEvaluator` and any terms setter revert `TermsFrozen` once the task has a
claimed or selected worker (including an auction's selected bidder) or an active submission. This
applies to every task. A bid alone does not freeze terms: no worker is committed until selection.
As a result a requester can no longer raise a bounty after submissions arrive.
The check runs before the status check, so a committed task reverts `TermsFrozen` and a terminal
task (Accepted, Expired, Cancelled) still reverts `TaskNotOpen`. A reopened Claim or Pitch task
with no worker is editable again. An Auction's `updateTask` still reverts `BidsExist` once any bid
is placed, as before; `assignEvaluator` is not frozen by bids alone.

#### `getTaskTerms(bytes32 taskId) view returns (TaskTerms)`

Returns the stored terms. Being a view, it cannot normalize; for a non-terminal task still at
version 0 it returns the record normalization would write.

#### `normalizeTerms(bytes32[] taskIds)` (permissionless)

- Runs the `LibTerms.terms` normalization for each id. Idempotent: an id that is already at
  version 1, terminal, or nonexistent is skipped without reverting.
- For a single-payee task (Claim, Pitch or Auction) without an evaluator that already holds an
  undecided deliverable, it also sets `taskClocks[taskId].deliveredAt` to the normalization time.
  The requester of a task delivered before the cut therefore gets a full review window from the
  upgrade, rather than a window that may already have lapsed against a delivery time the chain
  never recorded.
- For a Bounty or Benchmark without an evaluator, it sets `taskClocks[taskId].decisionStartAt` to
  the normalization time, so the decision deadline of a task already past `expiryTime` runs from
  the upgrade and no task locks at the cut.
- Removed, together with the lazy branch in `LibTerms.terms`, in the revision after rev025, once a
  read-only check finds no non-terminal task at version 0.

#### `submitWork` (changed)

On a Claim, Pitch or Auction task without an evaluator, records `deliveredAt = block.timestamp`.
Delivery itself stays closed after `expiryTime`, as today.

#### `reviewDeadline(bytes32 taskId) view returns (uint256)`

Returns `deliveredAt + reviewWindowSecs`, or zero when there is no undecided delivery. A
pre-rev025 delivery that normalization has not reached yet reads as `now + reviewWindowSecs`,
because normalization starts its window at that moment.

#### `acceptSubmission` (changed)

On a single-payee task with an undecided delivery, the requester may accept until
`reviewDeadline`, whether that falls before or after `expiryTime`; `TaskIsExpired` no longer blocks
it inside the window. It clears `deliveredAt`, and sets `taskAwarded` for the paid worker.

#### `rejectDelivery(bytes32 taskId)` (new)

- **Access:** the task's requester, through the forwarder (`NotRequester`).
- **Preconditions:** Claim, Pitch or Auction mode without an evaluator; an undecided deliverable
  exists (`DeliverableRequired`); `block.timestamp <= reviewDeadline` (`ReviewWindowClosed`).
  Terms are not required to be unfrozen.
- **Reject fee:** `rejectFee = base * rejectFeeBps / 10000`, where `base` is the reward on Claim
  and Pitch and the settled (accepted-bid) price on Auction. The worker receives `rejectFee` less
  the platform fee `task.feeBps`, which is booked as protocol fees exactly as on an accept, since
  every worker payment carries it. The rest of the escrow goes per `rejectOutcome`.
- **Worker stake (Claim):** returned to the worker when `rejectFee > 0`, because the worker
  delivered; sent to the `penaltyTo` destination when `rejectFee == 0`. Pitch and Auction workers
  post no stake.
- **Common effects:** clears the deliverable, `deliveredAt` and `claimedAt`; adds the worker to
  `taskRejectedWorkers`, so they cannot take the task again; dispatches `onForfeit`.
- **`Reopen` on Claim:** the task's reward becomes the remaining escrow (reward less `rejectFee`);
  status `Open` with no worker and `expiryTime = max(expiryTime, now + reopenExtensionSecs)`.
- **`Reopen` on Pitch (back to selection):** the reward becomes the remaining escrow; the selected
  worker is cleared and the task returns to selection with the same extension. Every other existing
  pitch stays valid; the rejected worker's cannot be selected.
- **`Refund` (Auction always; Claim or Pitch when chosen):** the remaining escrow, including on an
  auction the unused part of the price cap, returns to the requester and the task ends with the
  status `refundExpired` sets. An auction is never re-bid: its prices are time-bound, so the
  requester creates a new auction.
- **Events:** `DeliveryRejected(taskId, worker, rejectFee, stakeForfeited)`.
- A reopened task that no one takes before the new expiry is refunded through `refundExpired`.
  There is no resubmission with a restarted window: a requester and worker could loop it
  indefinitely.

#### `requestRevision(bytes32 taskId)` (new)

- **Access:** the task's requester, through the forwarder (`NotRequester`).
- **Preconditions:** Claim, Pitch or Auction mode without an evaluator; an undecided deliverable;
  `block.timestamp <= reviewDeadline` (`ReviewWindowClosed`); `revisionsUsed < maxRevisions`
  (`RevisionsExhausted`).
- **Effects:** marks the deliverable superseded (it stays recorded), clears `deliveredAt`,
  increments `revisionsUsed`, and sets `expiryTime = max(expiryTime, now + reviewWindowSecs)`. The
  worker may submit a new deliverable until `now + reviewWindowSecs`; `submitWork` then records a
  new `deliveredAt` and the review window restarts. No hooks are dispatched.
- **No resubmission:** once that time passes, the previous delivery returns to review with a fresh
  review window from that point; the requester may accept or reject it, or it settles through
  `settleLapsedReview`.
- **Release and forfeit:** both apply only before delivery. Under revision the task has a delivery,
  so `releaseClaim` reverts `DeliverableAlreadySet` and `forfeitAndReopen` reverts
  `DeliveryPending`.
- **Events:** `RevisionRequested(taskId, worker, revisionsUsed)`.
- Relayed through the forwarder with its own per-chain gas profile; no per-hook addition.
- Bounty and Benchmark are out of scope: the requester rejects individual submissions.

#### `settleLapsedReview(bytes32 taskId)` (new, permissionless)

- **Preconditions:** an undecided delivery on a single-payee task without an evaluator, and
  `block.timestamp > reviewDeadline` (`ReviewWindowOpen` otherwise).
- **Effects:** pays the worker exactly as `acceptSubmission` would: platform fee, reward, stake
  return, `taskAwarded`, `onComplete` hooks; clears `deliveredAt`; status `Accepted`.
- **Events:** the acceptance events, then `ReviewLapsed(taskId, worker)`.
- Called by a keeper or the backend wallet directly, not through the forwarder, with a hook-aware
  gas limit like `cancelTask`.
- `checkComplete` hooks are deliberately not called. The review window has already decided the
  payout, and no hook may block it; `onComplete` hooks still run.

#### `refundExpired` (changed)

- Reverts `DeliveryPending` while a single-payee task holds an undecided deliverable.
- The pay-at-expiry branch of `_refundAuctionClaimed` is removed: a delivered auction goes through
  the review window like any single-payee task. The undelivered-auction refund is unchanged.
- Reverts `DecisionWindowLapsed` on a Bounty or Benchmark per the decision deadline below.
- Never refunds over a recorded verdict. On a task in `Appealing` it reverts
  `AppealWindowStillOpen` until the appeal window has passed, then settles the verdict exactly as
  `finalizeVerdict` would: the outcome is applied and the evaluator fee is paid to the evaluator.
- On a task in `Disputed` past `expiryTime`, the appeal lapses and the original verdict stands:
  it settles exactly as `finalizeVerdict` would. A resolution before expiry still decides it.
- Past `expiryTime`, `finalizeVerdict` (and so this settlement) skips the `check*` hooks; the
  `on*` hooks still run and cannot revert. `refundExpired` has always bypassed hooks so that a
  reverting hook cannot lock a task's escrow, and routing it through `finalizeVerdict` keeps that
  guarantee. Before expiry, `finalizeVerdict` still runs the check hooks.

#### `forfeitAndReopen` (changed)

- Reverts `DeliveryPending` while an undecided deliverable exists. Forfeit is only for a worker who
  never delivered; a delivered task ends in accept, `rejectDelivery` or `settleLapsedReview`.
- The forfeited stake goes to the `penaltyTo` destination instead of the fee recipient.
- Sets `expiryTime = max(expiryTime, now + reopenExtensionSecs)`, so the reopened task can be
  claimed again.
- Access is unchanged: the requester, on a Claim task in `Claimed`, after `expiryTime`.

#### `claimTask(bytes32 taskId, uint256 stakeAmount)` (changed)

- When `stakeRequired`, reverts `StakePaymentMismatch` unless
  `stakeAmount >= ceil(reward * stakeBps / 10000)`.
- When `stakeAmount > 0`, reverts `StakePaymentMismatch` unless the calling forwarder's
  `pgtrPaymentAmount()` equals `stakeAmount`. A stake-required claim relayed by a forwarder that
  cannot report an amount reverts. `claimTask` therefore never records a stake it did not receive.
- Records `claimedAt` as today.

#### `releaseClaim(bytes32 taskId)` (new)

- **Access:** the claimed worker, through the forwarder (`NotWorker`).
- **Preconditions:** Claim mode (`NotAClaimTask`); status `Claimed` (`TaskNotClaimed`);
  `block.timestamp < expiryTime` (`TaskIsExpired`); no deliverable (`DeliverableAlreadySet`);
  release allowed by the terms (`ReleaseNotAllowed`).
- **Penalty:** with `span = expiryTime - claimedAt` and `graceEnd = claimedAt + span * grace /
  10000`, the penalty is zero until `graceEnd`, then rises linearly to the full stake at
  `expiryTime`:
  `penalty = stake * (now - graceEnd) / (expiryTime - graceEnd)` for `now > graceEnd`.
- **Effects:** penalty to the `penaltyTo` destination, remainder to the worker; clears worker,
  stake and `claimedAt`; adds the worker to `taskRejectedWorkers`; status `Open` with
  `expiryTime = max(expiryTime, now + reopenExtensionSecs)`; dispatches `onForfeit` (deployed hooks
  already handle the same Claimed-to-Open change; no new callback is added).
- **Events:** `ClaimReleased(taskId, worker, penalty, returned)`.
- Pitch and auction selection have no release: the selected worker posts no stake, and the
  requester already has reject and forfeit paths.

#### Decision deadline (Bounty and Benchmark without an evaluator)

A Bounty or Benchmark with live (unrejected) submissions after `expiryTime` stays decidable until
`max(expiryTime, decisionStartAt) + decisionWindowSecs`, where `decisionStartAt` is zero except on
a task normalized from before rev025: the requester may accept winners or reject submissions, and
having rejected all of them may cancel or refund, on the record through the existing
`RequesterReputation` event. Once the window lapses with live submissions, `rejectSubmission`,
`cancelTask` and `refundExpired` revert `DecisionWindowLapsed`. There is no automatic payout and no
refund; the requester settles only through `acceptSubmissions`. The task's reward-hook reserve stays
reserved until then.

#### `acceptSubmissions` and evaluator award loops (changed)

- `MAX_SUBMISSION_WINNERS = 50` is a public constant with a getter. `acceptSubmissions` and the
  evaluator award loops that settle Bounty and Benchmark tasks revert `TooManyWinners` above it.
  It does not apply to auctions, which have one winner and bids bounded by `MAX_BIDS_PER_TASK`.
- Sizing: 50 winners measured 3.6M gas on Base (about 60k to 70k per winner) and about 9M on
  Tempo, under the 16M relay ceiling; 100 winners would exceed it on Tempo.
- Every award with a nonzero amount sets `taskAwarded[taskId][worker]`, in `acceptSubmission`,
  `acceptSubmissions`, `_payAwards` and `settleLapsedReview`.

#### `rateTask` (changed)

Reverts `NotAwarded` unless `taskAwarded[taskId][worker]`, in every mode; `taskWorkerRated` still
limits it to once per pair. A submitter whose award was zero cannot be rated. For a task accepted
before rev025, which has no record, it falls back to `worker == task.worker` for Claim, Pitch and
Auction, and to a non-empty `taskSubmissionHashes[taskId][worker]` for Bounty and Benchmark.
`workerAgentId` is not checked on chain; the backend and CLI resolve it from the rated worker's
registered agent and refuse a mismatch before relaying.

#### Evaluator fee (changed, every task)

`evaluate` records the verdict and keeps the fee in escrow. `finalizeVerdict` pays it after the
appeal window, whatever the verdict. `resolveDispute` pays it when the resolution upholds the
verdict, and sends it to the requester when an appeal overturns the verdict, approve or reject: a
wrong verdict earns no fee. `_evaluatorFee` (rev024)
remains the single computation.

#### `penaltyTo` destination

`penaltyTo` governs worker stakes only: `forfeitAndReopen`, the `releaseClaim` penalty, and rev024's forfeits when a REJECT verdict is finalized or a dispute resolution upholds a
reject. `Requester` pays the task's requester; `Protocol` books it as protocol fees as
`forfeitAndReopen` does today. Evaluator stakes keep their rev024 destinations.

#### A rejected delivery returns the stake

Once a Claim worker has delivered, `rejectDelivery` returns the full claim stake on every outcome,
whatever the reject fee. A stake is forfeited only for never delivering: `forfeitAndReopen` after
expiry, the `releaseClaim` penalty, or a finalized REJECT verdict under the existing rules. Tying
the stake to the reject fee let a requester set a zero reject fee and `penaltyTo = Requester`, then
reject honest work and keep each successive worker's stake. Returning the stake removes that
incentive; the reject fee stays the only payment a rejection makes to the worker.

#### Hooks and forced exits

Hooks follow two rules. `check*` hooks are gates: they run before a voluntary action (fund, claim,
select, submit, evaluate, accept) and a rejection reverts it. `on*` hooks are notifications: they
run after the state change and a failure only emits `HookCallFailed`.

A hook may veto a voluntary action but never a forced exit. Any path that settles a task because
time ran out or a party lapsed runs no `check*` hook, so a broken or malicious hook cannot lock
escrow:

| Path | Hooks run |
| --- | --- |
| `refundExpired` (no verdict) | `onExpire` only |
| `refundExpired` on an expired `Appealing` or `Disputed` task, via `finalizeVerdict` | `onComplete` (or `onCancel` for a REJECT verdict); no `checkComplete` |
| `finalizeVerdict` after `expiryTime` | as above; before expiry `checkComplete` still gates |
| `settleLapsedReview` | `onComplete` only |
| `forfeitAndReopen`, `releaseClaim`, `rejectDelivery` | `onForfeit` only |
| `evaluatorTimeout` | none |

A reward-hook bonus that cannot be paid never blocks the USDC settlement, and any reservation it
leaves is recoverable through `recoverReserve`.

#### Pause

Pause blocks state-changing calls and nothing else. While paused, every exit reverts:
accept, `rejectDelivery`, `requestRevision`, `settleLapsedReview`, `refundExpired`, `cancelTask`,
forfeits, `releaseClaim`, `finalizeVerdict`, `resolveDispute` and `normalizeTerms`. Reads continue.
Pause does not stop or extend any window and changes no state, so a review window or decision
deadline can lapse while paused and a settlement may be due the moment the protocol unpauses. Pause
exists only for a severe exploit.

#### Reputation signals

`WorkerStats` is unchanged. Exit reputation is computed off chain from events: `DeliveryRejected`
and the forfeit events count against the worker; `ClaimReleased` is neutral when `penalty == 0`
(within the grace period) and negative otherwise. `acceptSubmissions` settling a Bounty or
Benchmark after its decision deadline emits `RequesterReputation` with
`event_ = "decision_deadline_lapsed"`, which counts against the requester.

### Errors, events, views

- **Errors:** `TermsFrozen`, `InvalidTerms`, `DeliveryPending`, `ReviewWindowOpen`,
  `ReviewWindowClosed`, `DecisionWindowLapsed`, `ReleaseNotAllowed`, `StakePaymentMismatch`,
  `NotAwarded`, `TooManyWinners`, `RevisionsExhausted`, `ForwardedPaymentMismatch`.
- **Events:** `TaskTermsSet`, `ReviewLapsed`, `DeliveryRejected`, `ClaimReleased`,
  `RevisionRequested`, `TaskExpiryExtended(taskId, newExpiry)`. `TaskExpiryExtended` is emitted
  whenever a reopen (`forfeitAndReopen`, `rejectDelivery` with `Reopen`, `releaseClaim`) or
  `requestRevision` moves `expiryTime` later, and not when the existing expiry already covers the
  extension, so an indexer can track `expiryTime` from events alone.
- **Views:** `getTaskTerms`, `reviewDeadline`, `MAX_SUBMISSION_WINNERS`.

### Forwarder

`TaskMarketForwarder` gains `pgtrPaymentAmount()`, set alongside `pgtrSender` for the duration of
`relay()` and reset after it. The forwarder is not upgradeable (no proxy, immutable `usdc`), so each
chain deploys a new one; both are trusted between `addForwarder` and `removeForwarder`.

#### Funding checks against the reported payment

When the calling forwarder reports its payment (`pgtrPaymentAmount()`), the market checks that the
payment equals exactly what the call escrows and reverts `ForwardedPaymentMismatch` otherwise:

- `createTask` (both overloads): `reward + evaluatorStake`. The evaluator stake arrives with the
  forwarded payment and is no longer pulled from the requester with `transferFrom`.
- `assignEvaluator`: `evaluatorStake`, likewise forwarded rather than pulled.
- `updateTask`: the reward increase (zero when the reward does not increase).

A forwarder that cannot report an amount keeps the earlier behaviour: the evaluator stake is pulled
from the requester and `updateTask` checks the escrow balance (`RewardIncreaseNotFunded`). Checking
the exact amount means the market never records escrow it did not receive and never keeps an
overpayment the requester did not intend.

### TaskTokenRewardHook reserve release

A hook implementation upgrade through `UpgradeRewardHook.s.sol`, with no diamond cut:

- Appended per-task state records `vaultReleased` and `budgetReleased` separately.
- `_releaseReserve` attempts each dependency call only if its flag is unset, sets the flag only on
  success, and emits `RewardVaultReleased` or `RewardBudgetReleased` for that step. A failure emits
  `RewardReleaseFailed(taskId, dependency)` and leaves the flag unset. `RewardReserveReleased` is
  emitted only once both steps are done.
- `recoverReserve(taskId)`, permissionless, retries the unset steps. It is allowed only when the
  diamond's task state shows the release was due: a reopened Claim or Pitch task (Open with no
  worker, after `onForfeit`, `rejectDelivery` or `releaseClaim`), a Cancelled or Expired task, or
  an Accepted task whose reservation `checkComplete` never paid (`settleLapsedReview`). It never
  releases a task that is still claimed or selected, or that paid out.
- `onComplete` releases an unpaid reservation through the same progress-tracked path, so a
  `settleLapsedReview` completion, which skips `checkComplete`, leaves a retryable record rather
  than a one-shot release.
- `checkComplete` does the same when it cannot pay the reserved bonus from the vault: it releases
  the reservation through the progress record rather than with one-shot calls whose failures were
  discarded, so a failed release stays pending for `recoverReserve` instead of stranding the
  reservation. The USDC settlement is never blocked by the bonus.
- `RewardVault` and `EpochBudget` are unchanged: the proxy address, and so their `hook`, stays the
  same; `RewardVault.release` reverts on over-release, so a retry cannot double-release;
  `EpochBudget.release` is a no-op once the epoch has rolled, which the hook records as done because
  the budget has already reset.

## Settlement by mode

"Review window" means the single-payee rule above; "decision deadline" the Bounty and Benchmark
rule. Stakes follow `penaltyTo` where marked.

| Mode | Evaluator | Terminal path | Reward | Worker stake |
| --- | --- | --- | --- | --- |
| Claim | none | accept within window, or `settleLapsedReview` | worker (less fee) | returned |
| Claim, Pitch, Auction | none | `requestRevision` (up to `maxRevisions`), then resubmit and a new review window | unchanged until accept, reject or lapse | held (Claim) |
| Claim | none | `rejectDelivery`, `Reopen` (default), then reclaim or `refundExpired` | reject fee to worker (less platform fee); rest to next worker, or requester | returned |
| Claim | none | `rejectDelivery`, `Refund` | reject fee to worker (less platform fee); rest to requester | returned |
| Claim | none | `releaseClaim` then reclaim or `refundExpired` | next worker, or requester | penalty to `penaltyTo`, rest to worker |
| Claim | none | `forfeitAndReopen` (never delivered) | stays in escrow, task reopened | `penaltyTo` |
| Claim | none | `refundExpired` (undelivered, or Open) | requester | returned (if any) |
| Claim | none | `cancelTask` (Open) | requester | none held |
| Claim | yes | `finalizeVerdict` / `resolveDispute` award | awarded worker | returned |
| Claim | yes | REJECT finalized or upheld, or zero award | requester | `penaltyTo` |
| Claim | yes | `evaluatorTimeout` then accept or expiry | as the no-evaluator rows | as those rows |
| Pitch | none | accept within window, or `settleLapsedReview` | worker | none held |
| Pitch | none | `rejectDelivery`, `Reopen` (default): back to selection among remaining pitches, or `refundExpired` | reject fee to worker (less platform fee); rest to next worker, or requester | none held |
| Pitch | none | `rejectDelivery`, `Refund` | reject fee to worker (less platform fee); rest to requester | none held |
| Pitch | none | `refundExpired` (undelivered) | requester | none held |
| Pitch | yes | verdict / dispute paths | awarded worker or requester | none held |
| Auction | none | accept within window, or `settleLapsedReview` | worker at accepted price, remainder of cap to requester | none (price is not a stake) |
| Auction | none | `rejectDelivery` (always `Refund`; task ends) | reject fee on settled price to worker (less platform fee); rest of escrow to requester | none |
| Auction | none | `refundExpired` (undelivered) | requester | none |
| Auction | yes | verdict / dispute paths, fee on accepted price | awarded worker or requester | none |
| Bounty, Benchmark | none | `acceptSubmissions` (at most 50 winners), any time with live submissions | winners; rounding remainder to requester | none |
| Bounty, Benchmark | none | all rejected, then `cancelTask` / `refundExpired` before decision deadline | requester | none |
| Bounty, Benchmark | none | decision deadline lapsed with live submissions | locked until the requester accepts winners | none |
| Bounty, Benchmark | none | no submissions, `refundExpired` / `cancelTask` | requester | none |
| Bounty, Benchmark | yes | verdict / dispute award loops (at most 50) | awarded workers or requester | none |

In every evaluator row the evaluator fee is paid at `finalizeVerdict`, or at `resolveDispute` when
the verdict is upheld, and goes to the requester when an appeal overturns the verdict, approve or
reject.

## Upgrade

One pass per chain, in this order:

1. **Evaluator-fee check.** Confirm on chain that no task has a recorded verdict awaiting
   `finalizeVerdict` or `resolveDispute`. Such a verdict's fee was already paid by the pre-rev025
   `evaluate`, and there is no contract guard against paying it again at finalization. If any
   exist, let their appeal windows run and finalize them first.
2. **Reward-hook implementation upgrade.** May go first; it does not depend on the cut.
3. **Backend funds claim stakes through the relayer.** Without this every stake-required claim
   reverts once stakes are enforced.
4. **Forwarder v2.** Deploy the new forwarder, authorise the relayer on it, `addForwarder` on the
   diamond, switch the backend to it.
5. **Diamond cut.**
6. **`normalizeTerms`** over the live task ids (about 565 on mainnet, a few batches). This seeds
   `deliveredAt` for tasks already delivered and `decisionStartAt` for live bounties and benchmarks,
   so no task locks at the upgrade. Any other post-upgrade pass over live task ids runs
   after this one.
7. **`removeForwarder`** for the old forwarder.

## Known limits

- **Push payments can stall on a party that cannot receive.** `settleLapsedReview`, every forfeit
  under `penaltyTo`, `releaseClaim` and the deferred evaluator fee pay by token transfer. A
  recipient blacklisted by the payment token, or refused by its receive policy, after being bound
  to the task makes that path revert and stalls the task; a requester blocked after binding stalls
  `releaseClaim` whenever the penalty is nonzero. The contracts contain no blacklist or
  transfer-failure handling; parties who cannot be paid are refused off chain before binding.
- **Lapsed bounties can lock escrow.** If a requester never settles after the decision deadline,
  the escrow stays locked and the submitters stay unpaid. The locked money is the requester's own,
  and the work cannot be taken for free through a refund.
- **Self-dealing.** A requester can submit from a wallet they control and accept that submission to
  recover most of the reward. The deadline rule cannot prevent this; only the platform fee and
  reputation price it.
- A silent requester pays for delivered work after the review window (72 hours by default).
- A release in the grace period is free, so a worker can hold a task for up to the grace share of
  its span at no cost.
- Legacy accepted Bounty and Benchmark tasks keep the weaker submitter check in `rateTask`, and a
  direct call can pair a real winner with the wrong `workerAgentId`.
- A Bounty or Benchmark with more than 50 winners cannot settle in one call.
- Live tasks move to the new defaults at normalization, mid-task, including the 20% reject fee.
- A worker who delivers junk still earns the reject-fee share, and a reopened task carries a
  smaller reward.
- A rejected auction ends; new work needs a new auction.
- Revisions can extend a task by up to `maxRevisions` review windows past its expiry.
- A review window or decision deadline can lapse during a pause; settlement may be due at unpause.

## Verification

- Each terminal path in the settlement table runs on a fresh diamond with exact payouts asserted
  for every party and a zero diamond balance afterwards.
- The escrow-conservation invariant from rev024 is extended to the review lapse, `rejectDelivery`,
  `releaseClaim`, every `penaltyTo` destination, the blocked post-deadline exits and the deferred
  evaluator fee.
- Upgrade test: a pre-rev025 delivered Claim task normalizes with `deliveredAt` equal to the
  normalization time; a pre-rev025 Bounty past `expiryTime + decisionWindowSecs` normalizes with
  `decisionStartAt` set and stays decidable for a full window; a terminal task stays at version 0; `normalizeTerms` is idempotent.
- `claimTask` reverts `StakePaymentMismatch` through a forwarder whose payment differs, and through
  a forwarder without `pgtrPaymentAmount()`.
- `rejectDelivery` in each mode and outcome, at zero, default and maximum reject fee, asserting the
  worker's net fee, the platform fee, the stake destination and the remaining escrow; `InvalidTerms`
  for `Reopen` on an auction and a fee above the bound.
- `requestRevision` up to the limit then `RevisionsExhausted`; window restart and expiry extension;
  missed resubmission returns the superseded deliverable to review; release and forfeit revert
  during a revision; every exit reverts while paused.
- An overturned approve and an overturned reject each send the evaluator fee to the requester.
- `TooManyWinners` at 51 winners in `acceptSubmissions`, `evaluate` and `resolveDispute`; 50 winners
  settle. In the Foundry suite a 50-winner Bounty `acceptSubmissions` used 3,602,207 gas end to end.
- Reward hook: vault-only failure, budget-only failure, both, a diamond after-callback failure and
  repeated recovery, asserting partial-progress state, no double release, truthful events and
  restored `RewardVault.available()`.
