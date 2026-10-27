# Rev027 -- a Claim task with a reserved worker

## Status

Implemented; not yet deployed on any chain. The cut goes to both testnets together, then to both
mainnets with a production release.

## Motivation

Through rev026 the only way to hire one particular worker was a private Claim task: the requester
hid the task, showed it only to that worker, and the worker took it by claiming. That models a hire
as a race. Any other wallet the task is shown to can claim first; the only way to keep others out
is to hide the task, so a hire cannot be posted publicly; nothing on chain records which worker the
requester meant to hire; and the worker is never offered the work to accept or decline by a
deadline.

Claim mode already provides almost everything a hire needs once a worker has committed: one worker
with exclusive delivery, a stake, the hand-back (`releaseClaim`), the forfeit after expiry, the
review window, revisions, settlement, a refund on rejection when the terms ask for one, and a full
refund when the requester cancels an open task. What it lacks is a named worker, a deadline for that
worker's answer and an explicit decline. Rev027 adds exactly those to claim mode. It does not add a
mode.

## Problem 1 -- a claim task cannot name its worker

`claimTask` gives the task to the first eligible wallet. No field records an intended worker, and
the only exclusivity is what the relayer enforces off chain for a private task.

## Problem 2 -- the named worker cannot answer the offer

There is no call for a worker to decline, and no deadline after which an unanswered offer ends and
the requester gets the escrow back.

## Problem 3 -- claim mode reopens

A Claim task reopens for new claims after a rejection (by default), a hand-back or a forfeit. For a
hire that is wrong: the escrow would sit on an open task nobody else may take.

## Changes

### Storage

- `TaskTerms` gains `uint32 acceptWindowSecs` after `resolutionWindowSecs`. It fills the four spare
  bytes of the terms' one storage slot, so every stored task reads it as 0 and no slot moves.
  `LibTerms.TERMS_VERSION` becomes 2; a task created before rev027 keeps reading version 1.
- Appended to the end of `AppStorage`, after `hookGasStipend`:
  - `reservedWorkers`: `mapping(bytes32 => address)`, the reserved worker of a task (zero for every
    other task);
  - `workerAgentIds`: `mapping(address => uint256)`, the ERC-8004 agent ID reservation feedback
    goes to.

No field was inserted, reordered, renamed or removed.

The accept window is a settlement term because it is a rule of the offer, chosen and bounded like
the other windows. The reserved worker is not a term: it is who does the work, like `task.worker`,
so it is stored beside the task instead.

### Create

`createTask(config, hookConfig, content, evaluatorConfig, terms, address reservedWorker)` is a new
`createTask` overload (`ITMPReservation`). A zero `reservedWorker` creates an ordinary task. With a
reserved worker:

- the mode must be Claim (`InvalidMode` otherwise), and the worker may not be the requester
  (`InvalidWorker`);
- `terms.acceptWindowSecs` is 0, meaning the 72-hour default, or between 1 hour and 30 days
  (`InvalidTerms`). The default matches the other 72-hour windows in `LibTerms`. On a task without a
  reserved worker it must be 0. The accept-by time is the creation time plus the window;
- `terms.rejectOutcome` may not be `Reopen` (`InvalidTerms`). `Default` resolves to `Refund` on such
  a task;
- `config.duration`, the delivery period, may not be shorter than the accept window
  (`InvalidTerms`). The task's expiry is therefore never before its accept-by time, so the worker
  always has the whole window to answer;
- the stake requirement defaults to none, as on every task;
- `TaskReserved(taskId, worker, acceptBy)` is emitted after `TaskCreated` and `TaskTermsSet`.

`getReservation(taskId)` returns the reserved worker and the accept-by time (both zero without one).

The version 2 terms change the selectors of the five-argument `createTask` and the topic of
`TaskTermsSet`. The rev025 selector, taking version 1 terms, stays routed to an overload that
creates an ordinary task with version 2 terms (`acceptWindowSecs` 0), so callers relaying the old
encoding keep working through the cut and can move afterwards. A later revision removes it.

### Accept: `claimTask`

On a task with a reserved worker, `claimTask` succeeds only for that worker (`NotReservedWorker`)
and only up to and including the accept-by time (`AcceptWindowClosed`). The stake is checked as for
any claim. The delivery period restarts at the claim: `expiryTime` becomes the claim time plus the
span from creation to the expiry before the claim (the requested duration), and
`TaskExpiryExtended` is emitted. Time spent deciding never shortens delivery.

`claimTask(taskId, stakeAmount, workerAgentId)` is a new `claimTask` overload (`ITMPReservation`)
that accepts exactly as above and, in the same transaction, binds the nonzero `workerAgentId` to the
worker for reservation feedback (`WorkerAgentBound`). Only a trusted forwarder relaying the
worker's own accept binds it; on a task without a reserved worker the ID is ignored, and 0 binds
nothing. The two-argument `claimTask` is unchanged. The second argument stays the stake, so the
overload adds a third argument; a `claimTask(taskId, workerAgentId)` would collide with the
existing selector.

`checkClaim` runs on every hook exactly as for any claim. Every existing hook, the Sponsored Task
and token reward hooks included, works unchanged; a hook that needs the reserved worker reads it
with `getReservation`.

### Decline

`declineReservation(taskId, workerAgentId)`: the reserved worker (relayed), on the open task, up to
and including the accept-by time. The task becomes `Cancelled`; the reward and any evaluator stake go
back to the requester. Events: `TaskCancelled`, `ReservationDeclined(taskId, worker)`. No check hook
runs; `onCancel` runs as on `cancelTask`. `NotReserved` on a task without a reserved worker.

### Lapse: `refundExpired`

`refundExpired` refunds an open task with a reserved worker as soon as its accept-by time has
passed, before its expiry. It stays permissionless. The reward and any evaluator stake go back to
the requester: no evaluator had work to do, so the stake is refunded as `cancelTask` refunds it,
not forfeited. Events: `TaskExpired`, `ReservationLapsed(taskId, worker)`. Without a reserved worker
an open task still waits for its expiry.

### Withdraw: `cancelTask`

Unchanged. The requester withdraws the open task at any time before the claim, including after
the accept-by time, for a full refund.

### Never reopened

Every path that reopens a Claim task ends a task with a reserved worker instead:

- **Rejection** (`rejectDelivery`): the worker gets the reject fee less the platform fee and the
  stake back, as before, and the rest of the reward is refunded (`Expired`). `LibTerms.validate`
  refuses `Reopen`, and `_applyRejectOutcome` refunds such a task whatever the stored outcome.
- **Hand-back** (`releaseClaim`): the stake penalty and return are computed as before; then the task
  is `Expired`, the reward and any evaluator stake are refunded, `ClaimReleased` and `TaskExpired`
  are emitted, and `onExpire` runs instead of `onForfeit`.
- **Forfeit** (`forfeitAndReopen`): settles exactly as `refundExpired` on a claimed, undelivered
  task does: the stake is forfeited to the terms' `penaltyTo`, the reward refunded, `Expired`,
  `onExpire`.

The other `TaskReopened`-free transitions were checked: a rejecting evaluator verdict already ends
every task (`Cancelled`) with a refund, and `evaluatorTimeout` on a Claim task always has a delivery
and returns it to the requester's review window (`Claimed`) without reopening.

### `updateTask`

Reverts `ReservationPending` on a task whose offer is pending: it has a reserved worker, is open,
and its accept-by time has not passed. That covers every field: reward, expiry and the mode
deadlines. To change an offer the requester withdraws it with `cancelTask` and makes a new one.
Once the offer ends, the usual rules apply. After a claim the terms are frozen (`TermsFrozen`). After
a decline the task is not open (`TaskNotOpen`). After a lapse the task is still open until
`refundExpired` runs, and `updateTask` works as on any open task, since no worker can claim it any
more.

### Evaluator

Unchanged rules give the intended result: an evaluator can be set at creation or with
`assignEvaluator` while the task is open; after the claim `assignEvaluator` reverts (`TermsFrozen`).

### Reputation

Three worker event keys join `LibFeedback`, owner-settable with `setFeedbackValue` like the rest,
and sent only for tasks with a reserved worker:

| Event key               | Default | When                                                  |
| ----------------------- | ------- | ----------------------------------------------------- |
| `reservation_declined`  | 0       | `declineReservation`                                  |
| `reservation_lapsed`    | 0       | `refundExpired` on the unclaimed task after accept-by |
| `reservation_forfeited` | -25     | The worker claimed and never delivered (forfeit)      |

A value of 0 sends nothing. Declining is a legitimate answer. A lapse costs nothing on chain by
default because the contract cannot tell why an offer went unanswered (the worker may never have
been told, or may have been waiting on its owner's approval) and anyone may trigger it; lapses are
counted off chain, where that context exists. A forfeit matches the other -25 penalties. Rejected
work needs no key: the requester's rating covers it. A hand-back sends nothing beyond its stake
penalty.

The feedback goes to the worker's bound agent ID (`workerAgentOf`), with
`tag1 = "tmp.task.worker"` and `tag2 = "tmp.mode.claim"`. A trusted forwarder relaying the worker's
own accept (the three-argument `claimTask` on a reserved task) or `declineReservation` binds the
nonzero `workerAgentId` it passes, as the requester binding works. An ID passed on any other call
is ignored, and 0 never unbinds. A requester therefore cannot point a worker's negative feedback at
an agent ID of the requester's choosing. A worker who accepted through the two-argument `claimTask`
and never bound an ID is unbound, and nothing is sent for it.

### Fees

Unchanged: the same platform fee on payment; accepting is `claimTask`.

### Errors, events, views

`ITMPCore`: errors `NotReservedWorker`, `AcceptWindowClosed`, `NotReserved`,
`ReservationPending`; events `TaskReserved`, `ReservationDeclined`, `ReservationLapsed`; the
`TaskTerms.acceptWindowSecs` field and the `TaskTermsV1` struct. `ITMPFeedback`: event
`WorkerAgentBound`, view `workerAgentOf`. `ITMPReservation`: the new `createTask`, the
three-argument `claimTask`, `declineReservation`, `getReservation`. `ITMPTermsV1`: the rev025 `createTask`.

### CoreFacet split

At rev026 `CoreFacet` deployed at about 24,000 bytes against the 24,576-byte limit, and rev027's
additions left it with no room for the next change. Its task creation code was also private to it,
so no other facet could create a task through the same path. rev027 splits it:

- Task creation moves into a new library, `LibTaskCreation`. Its `create` function validates and
  records the task, applies its evaluator terms, builds and checks its hooks, emits the creation
  events and books its escrow, as `CoreFacet`'s private `_createTask` did. `CoreFacet`'s
  `createTask` overloads hold the forwarder, pause and reentrancy guards and call it.
- `claimTask` (both overloads), `selectWorker`, `submitPitch`, `submitProof` and `submitWork` move to
  a new `WorkerFacet`, with their private helpers. They are the largest group in `CoreFacet` that no
  other `CoreFacet` function calls.
- `CoreFacet` keeps the mode constants, the `createTask` overloads and `updateTask`.

Every moved function keeps its selector, signature and behaviour, and reads and writes the same
`AppStorage`; only the facet that serves it changes. `LibTaskCreation`'s functions are internal, so
a facet that calls it compiles its own copy: the library saves no bytecode by itself, but it lets a
later facet create tasks through the one path.

## Rationale

### Why not a separate mode?

A mode would duplicate claim mode's whole post-claim lifecycle across every `mode == CLAIM` branch
(submit, forfeit, release, the delivery check, the expiry refund, three evaluator paths), every
hook's mode handling and every off-chain mode switch, and need a new hook interface before an
existing reward hook could be attached. A reserved worker on a Claim task needs about half the
contract change, and every hook keeps working.

### Why `claimTask` for accept instead of a new call?

Accepting commits the worker exactly as claiming does: stake, exclusive delivery, the hooks'
`checkClaim`. A separate call would have to repeat all of it.

### Why must the delivery period be at least the accept window?

The delivery period restarts at the claim, so before the claim `expiryTime` only bounds how long the
offer can stay open. If it could fall before the accept-by time, `refundExpired` could end the offer
while the worker still had time to answer.

### Why does `updateTask` refuse a pending offer?

`claimTask` names no expected reward or delivery period, so the worker accepts whatever the task
holds when the claim is mined. If the requester could update a pending offer, it could see the
worker's claim in the mempool and get an update in ahead of it, cutting the reward or pulling the
expiry in to the accept-by time. The restarted delivery period would then shrink to the accept
window. The worker would be bound to terms it was never offered.

Refusing updates while the offer is pending closes that in one rule. A narrower rule refusing only
a lower reward or an earlier expiry would still need every other field reasoned about, and a claim
carrying the expected terms would change every caller's encoding. Withdrawing with `cancelTask`
refunds the requester in full, so changing an offer costs one new offer and nothing is lost.

### Why does `refundExpired` lapse the offer instead of a new call?

It keeps one permissionless recovery call for every task. Recovery after accept-by is opt-in, as
`refundExpired` already is.

### Why keep the rev025 `createTask` selector routed?

The version 2 terms change the selector every caller relays. Keeping the old one routed to an
overload that creates the same ordinary task lets callers move after the cut rather than in
lockstep with it, as rev025 did for the rev018 overload.

### Why bind the worker's agent ID only from its own call?

Feedback from these keys can be negative. If the requester, or anyone but the worker's relayed call,
could name the agent ID, a requester could reserve a wallet it controls and aim a forfeit at someone
else's agent.

### Why bind it in the accept rather than in a separate call?

The forfeit penalty matters only for a worker who accepted. Binding in the accept's own transaction
guarantees that every relayed accept carrying an ID can be penalised, with no window in which the
worker holds the task unbound and no extra call for the forwarder to remember. Binding only on a
decline would have made declining the riskier answer, since only declined workers became
penalisable.

## Upgrade

`Rev027Upgrade` sends one `diamondCut`: it Replaces the selectors that stay on CoreFacet and Adds
the version 2 `createTask` and the reserved-worker `createTask` (the rev025 selector stays routed
to CoreFacet); Replaces the moved selectors onto the new WorkerFacet and Adds the three-argument
`claimTask` there; Replaces
SettlementFacet and Adds `declineReservation` and `getReservation`, and Replaces FeedbackFacet and
Adds `workerAgentOf`. Then it sets `diamondVersion` to 27. No other facet acts on the reserved
worker, and the new terms field sits after every field they read. There is no backfill.

## Trade-offs

- The version 2 terms change the `createTask` selector and the `TaskTermsSet` topic. Indexers must
  decode both `TaskTermsSet` signatures, and callers must move to the version 2 encoding before a
  later revision removes the rev025 overload.
- Hooks see the reserved worker only by calling `getReservation`.
- Indexers tell a hire from an open claim by `TaskReserved`, not by mode.
- `reservation_forfeited` and `reservation_lapsed` reach only workers that have bound an agent ID,
  through the three-argument `claimTask` or `declineReservation`.
- A requester cannot edit a pending offer; changing it means withdrawing and making a new one.

## Tests

- `test/ReservedWorker.t.sol`: create (default and bounded windows, the window only with a reserved
  worker, Claim mode only, not the requester, delivery not shorter than the window, refund on reject,
  the rev025 overload), claim (only the reserved worker, until accept-by, delivery from the claim,
  stake, `checkClaim`, the agent-ID overload binding and its forfeit feedback), decline, lapse
  through `refundExpired`, withdraw, `updateTask` refused while pending and allowed after a lapse,
  accept,
  rejection, hand-back, forfeit, expiry, revision and lapsed review, the evaluator, the feedback keys
  and the binding, each compared with the same path without a reserved worker where it differs.
- `test/Rev027Upgrade.t.sol`: the cut from a rev026 diamond with a live claimed task, the rev025
  selector before and after, and a task with a reserved worker end to end.
- `test/DiamondSelectorParity.t.sol`: the full step sequence through rev027 matches a fresh deploy.

## Affected Files

| File                                                            | Change                                                         |
| --------------------------------------------------------------- | -------------------------------------------------------------- |
| `packages/contracts/evm/src/interfaces/ITMPCore.sol`            | `acceptWindowSecs`, `TaskTermsV1`, errors, events              |
| `packages/contracts/evm/src/interfaces/ITMPReservation.sol`     | New: `createTask` with a reserved worker, decline, view        |
| `packages/contracts/evm/src/interfaces/ITMPTerms.sol`           | `ITMPTermsV1`                                                  |
| `packages/contracts/evm/src/interfaces/ITMPFeedback.sol`        | `WorkerAgentBound`, `workerAgentOf`                            |
| `packages/contracts/evm/src/interfaces/ITMPDiamond.sol`         | The new functions                                              |
| `packages/contracts/evm/src/libraries/LibAppStorage.sol`        | `reservedWorkers`, `workerAgentIds` appended                   |
| `packages/contracts/evm/src/libraries/LibTerms.sol`             | Version 2, accept window, validation                           |
| `packages/contracts/evm/src/libraries/LibFeedback.sol`          | The three keys and the worker binding                          |
| `packages/contracts/evm/src/libraries/LibRevision.sol`          | `CURRENT_REVISION = 27`                                        |
| `packages/contracts/evm/src/facets/CoreFacet.sol`               | Create overloads, claim and update rules                       |
| `packages/contracts/evm/src/facets/SettlementFacet.sol`         | Decline, lapse, no reopen, view                                |
| `packages/contracts/evm/src/facets/FeedbackFacet.sol`           | `workerAgentOf`                                                |
| `packages/contracts/evm/script/upgrades/Rev027Upgrade.s.sol`    | New: the cut                                                   |
| `packages/contracts/evm/script/lib/FacetSelectors.sol`          | rev027 selector sets; the rev025 `createTask` written out      |

## Requester timeout and a permissionless evaluator timeout

Every role that can stall a task should have an exit that does not depend on that role. Through
rev027 two did not:

- A Bounty or Benchmark without an evaluator, once its decision window lapsed with live
  submissions, could be settled only by its requester (`acceptSubmissions`). `refundExpired`,
  `rejectSubmission` and `cancelTask` all reverted `DecisionWindowLapsed` (rev025, "Decision
  deadline"), and nothing paid out automatically, so an abandoned task's escrow, and its
  reward-hook reserve, stayed locked forever.
- `evaluatorTimeout` was documented as callable by anyone, but began with `_requireForwarder`, so
  it worked only through the relayer. When a delivered task sat in `Review`, `refundExpired`
  reverted `DeliveryPending`, so the exit depended on the relayer being available.

### Forwarder rule

A function that does not read its caller does not require the PGTR forwarder. The liveness exits
read no caller and are callable directly by anyone: `refundExpired`, `finalizeVerdict`,
`settleLapsedReview`, `evaluatorTimeout` and `requesterTimeout`. A relayer may
still call them on a user's behalf, as a convenience and not a gate. Role-gated actions that
read the sender through `_effectiveSender` (accept, reject, `forfeitAndReopen` and the like) stay
forwarder-only.

### Change 1 -- `requesterTimeout(bytes32 taskId)`

Callable by anyone, with no forwarder, once a Bounty or Benchmark task without an evaluator has
live submissions and its decision deadline, `max(expiryTime, decisionStartAt) +
decisionWindowSecs`, has passed (strictly after: at the deadline the requester can still decide).

Effect: the task becomes `Expired`, its reward liability is cleared and the whole escrow is
refunded to the requester. The onExpire hooks run in a try/catch, as for `refundExpired`, and
cannot block the refund. Winners cannot be chosen permissionlessly, so a refund is the only
neutral outcome. An equal split among submitters was rejected: it pays spam entries as much as
real work and invites flooding abandoned tasks with submissions.

Signal: `RequesterReputation` is emitted with `event_ = keccak256("requester_timeout")`, `reward`
the refunded amount and `submissionCount` the number of live submissions. The event also feeds
the ERC-8004 reputation registry through the new feedback key `requester_timeout`, whose compiled-in
default is -100 (the floor `setFeedbackValue` allows) and which the owner can change. That is
stronger than `expired_after_rejections` (-25) and than `decision_deadline_lapsed`, which carries
no on-chain feedback value by default. Requester feedback goes to the requester's stored agent
binding; a third party cannot supply or change it.

Reverts: `TaskDoesNotExist`; `InvalidMode` (not a Bounty or Benchmark); `TaskNotOpen` (not Open or
PendingApproval, including an already settled or refunded task); `NoActiveSubmissions`; and
`DecisionWindowNotLapsed` while the requester can still decide, or when the task has an
evaluator (its exits are the evaluator's verdict and `evaluatorTimeout`).

### Change 2 -- the worker-side exit is `refundExpired`

A claimed worker who misses the deadline without delivering needs no new function. `refundExpired`
is callable by anyone on a claimed, undelivered, expired task: it refunds the requester and
forfeits the worker's stake. That is the neutral outcome, as the requester's refund is for
`requesterTimeout`. Reopening the task for a new worker (`forfeitAndReopen`) is a decision about
the task, so it stays with the requester, unchanged and forwarder-only.

### Change 3 -- `evaluatorTimeout` is permissionless

`evaluatorTimeout` drops `_requireForwarder`. It never read its caller, so nothing else changes.

### Upgrade

The same `Rev027Upgrade` cut carries these changes: it Adds `requesterTimeout` to the Settlement
selectors it already Adds, Replaces `FeedbackFacet` (already part of the cut, so its views report
the new key's default) and also Replaces `EvaluatorFacet` for the dropped gate. No `AppStorage`
change.
