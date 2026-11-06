# Rev029 -- Project grants (re-grant, cap raise, limits), owner transfer and end-date extension

## Status

Implemented; not deployed on any chain. The rollout (chains, order, timing) is not part of this
revision. It follows rev028. It changes `ProjectFacet`, `LibProject`, the funding pool contract, and the
requester checks in the facets that share `LibGuards` (see "Owner transfer"). It appends to `AppStorage`.

## Problem

An operator grant (rev027) moves one way only:

- **A revoke is final.** `revokeOperator` sets `revoked`, and `grantOperator` reverted `GrantRevoked`
  for a revoked grant. The same address could never be granted again on that project. A project
  owner who turned an automation runner off had no way to turn it on again, short of granting a
  different address.
- **A cap can never be raised.** Terms are written by `grantOperator` only while the grant is neither
  accepted nor revoked, and accepting freezes them. No setter exists. An operator that reached its
  cap stayed at it for the life of the grant.

- **Nothing bounds an accepted operator but its cap.** An owner who wants an operator to stop
  drawing after a date, to draw at most so much a week, to create only some kinds of task, or to
  hold at most so much in one task has only revoke.
- **A cap is read as "held at once" in places.** It is lifetime net spend (see below).

Both make a switch that is turned off and on, or turned up, impossible for a fixed operator address
such as a platform runner.

## Changes

### Storage

`Grant`, `GrantTerms` and every earlier `AppStorage` field are unchanged. `GrantTerms` is hashed by
`acceptGrant` and embedded in `Grant`, so the limits below do not live there. Two mappings are appended
at the end of `AppStorage`, in this order:

```
mapping(uint256 projectId => mapping(address operator => GrantLimits)) projectGrantLimits;
mapping(uint256 projectId => address) projectPendingOwner;
```

`projectGrantLimits` reads as no limits for every grant that never had any set, so a diamond cut to
rev029 behaves as before until an owner sets one. `projectPendingOwner` is the address a project's
owner proposed as its next owner (zero when none). The funding pool's namespaced storage gains no field.

### What the cap means

`terms.cap` is the most the operator's tasks may draw from the budget over the life of the grant, net
of what their refunds return: lifetime net spend, measured by `committed`. It is not what is held at
once. A payout counts as spent for good; a refund gives its share back.

### Re-grant after a revoke

`grantOperator(projectId, operator, terms)` accepts a revoked grant. It resets the grant to a fresh
pending grant:

- `terms` are replaced by the new terms.
- `revoked` is cleared and `accepted` is cleared. The operator must accept again, against the hash
  of the new terms, exactly as for a first grant. Until it does, it cannot create tasks
  (`GrantNotAccepted`).
- `exists` stays true. `OperatorGranted(projectId, operator, terms)` is emitted, as for any grant.
- `committed` is kept (next section).

It is still owner only, still reverts `InvalidOperator` for the zero address or the owner, and still
reverts `GrantAlreadyAccepted` for a grant that is accepted and not revoked, so a live grant's terms
stay frozen. A revoked grant that was never accepted may be granted again the same way. A re-granted
and re-accepted grant can be revoked again, and granted again, any number of times.

### How `committed` counts against the new cap

`committed` is the operator's tasks' draw on the budget, net of refunds. It is not reset by a revoke
or a re-grant. It keeps falling as the operator's old tasks refund (a cancel, an expiry refund), and
rising with new draws. So at any time a cap bounds the total the operator's tasks hold, across every
grant the owner has made to that address on the project.

On a grant, a nonzero `terms.cap` below the current `committed` reverts
`GrantCapBelowCommitted(cap, committed)`. A cap equal to `committed` is allowed and leaves no
headroom. A zero cap means no cap beyond the project's available budget, as in every grant, and is
always allowed; choosing it is the owner's explicit act.

Reasoning:

- Resetting `committed` to zero on a re-grant would let an owner (or a bug) restate the same cap and
  have it count from zero while the old tasks still hold budget, so the operator could hold up to
  twice its cap at once. The cap is a bound on what the operator's tasks hold, and money held by old
  tasks is still held.
- Refusing a cap below `committed` stops a grant that is already over its cap before the operator
  spends anything. Without the check the grant would be accepted but could never create a task until
  enough refunds arrived, which looks like a working grant and is not. The error names both numbers
  so the owner can state a cap that works.
- The check applies to every `grantOperator` call, not only to a re-grant. For a first grant
  `committed` is zero, so it never fires there.

### Existing tasks follow the grant's current state

Whether the operator or the owner may act on a task the operator created is decided by the grant's
current flags (`LibProject.mayAct`): the operator acts unless the grant is revoked with
`revokeRemovesControl`; the owner acts when `ownerOverride` is set, and always while a revoke removes
the operator's control. Nothing about that function changes in this revision, so it follows the flags:

- While the grant is revoked, a revoke with `revokeRemovesControl` still removes the operator's
  control and passes it to the owner. Every guarantee of a revoke holds for as long as the revoke
  stands.
- A re-grant clears the revoke, so the operator's existing tasks come back under the new grant's
  terms: the operator acts, and the owner acts when the new terms set `ownerOverride`. This is the
  point of granting the same operator again, and the owner chose the terms.
- A task's `requester` (the requester of record) is written once at creation and is never touched, so
  ratings and reputation stay where they were. A new grant's `requesterOfRecord` applies to tasks
  created after it.
- The owner keeps full control through `ownerOverride` in the new terms, and can revoke again at any
  time.

`mayAct` is inlined into six facets through `LibGuards._requireRequester`. Keeping it unchanged is
why this revision replaces `ProjectFacet` alone. A rule that kept control with the owner after a
re-grant would need a per-task or per-grant record and a redeploy of Core, Worker, Settlement,
Evaluator, Acceptance and Rating, and the owner can already hold control with `ownerOverride`.

### Raise a cap in place

```solidity
function raiseGrantCap(uint256 projectId, address operator, uint256 newCap) external;
event GrantCapRaised(uint256 indexed projectId, address indexed operator, uint256 oldCap, uint256 newCap);
error GrantCapNotRaised(uint256 currentCap, uint256 requestedCap);
```

- Owner only (`NotProjectOwner`). Forwarder-relayed with no payment, not paused, like the other
  grant functions.
- The grant must exist (`GrantNotFound`) and must not be revoked (`GrantRevoked`). It may be pending
  or accepted.
- `newCap` must be strictly above the current cap, else `GrantCapNotRaised(currentCap, newCap)`.
  Lowering and an equal cap are refused. A current cap of zero means no cap, so no number raises it,
  and a `newCap` of zero is below any nonzero cap, so it is refused too. The owner who wants no cap
  after a nonzero one revokes and grants again with a zero cap.
- Only `terms.cap` changes. `committed`, `accepted`, the other terms and the requester of record are
  untouched.

Why this needs no second accept on an accepted grant: a higher cap is the one change to accepted
terms that cannot harm the operator. It widens what the operator may spend and moves no money and no
control. The owner could already do the same by granting a second address.

Why it differs on a pending grant: the terms hash an operator reviewed is `keccak256(abi.encode(terms))`.
Raising the cap of a pending grant changes the stored terms, so an `acceptGrant` that carries the old
hash reverts `GrantTermsMismatch`. The operator can only accept what it now sees, which is the same
protection `grantOperator` gives when the owner edits a pending grant.

### Lowering a cap

`lowerGrantCap(projectId, operator, newCap)` is the mirror of `raiseGrantCap`, so the two together
are the whole cap API, and `setGrantLimits` does not touch the cap. Owner only; the grant must exist
and not be revoked. `newCap` must be nonzero and below the current cap (any nonzero cap lowers a
grant whose cap is zero, "none"), else `GrantCapNotLowered(currentCap, requestedCap)`. A cap may never
go below `committed`: `GrantCapBelowCommitted(cap, committed)`, the error `grantOperator` uses. A cap
equal to `committed` is allowed and leaves no room. An accepted grant stays accepted; emits
`GrantCapLowered(projectId, operator, oldCap, newCap)`.

### Grant limits

The owner sets limits per project and operator with `setGrantLimits(projectId, operator, limits)`,
stated whole: every field is written, and zero in a field means no limit of that kind. Owner only; the
grant must exist (`GrantNotFound`) and not be revoked (`GrantRevoked`). It emits
`GrantLimitsSet(projectId, operator, expiresAt, allowedModesMask, maxRewardPerTask, periodSecs, periodCap)`.
`getGrantLimits` returns the stored limits and the period meter.

| Field              | Type    | Meaning                                                                                                                                                          |
| ------------------ | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `expiresAt`        | uint64  | Unix seconds. From this moment the operator's own draws revert `GrantExpired`. Zero: none. A nonzero value not in the future reverts `InvalidGrantLimits`.       |
| `allowedModesMask` | uint32  | Bit n allows the nth built-in mode: bounty 0, claim 1, pitch 2, benchmark 3, auction 4. Zero: every mode. A bit above 4 reverts `InvalidGrantLimits`.            |
| `maxRewardPerTask` | uint128 | The most one task may hold from the budget: its reward plus any evaluator stake, counting later top-ups. Zero: none.                                             |
| `periodSecs`       | uint64  | The length of the budget period. Zero: no period budget.                                                                                                         |
| `periodCap`        | uint128 | The most the operator may draw in one period, net of refunds. Needs a nonzero `periodSecs`, and the reverse: one without the other reverts `InvalidGrantLimits`. |

The stored form adds the meter: `periodStart` (when the current period began, zero before the first
draw) and `periodSpent` (what was drawn in it, net of refunds). The input struct has no meter, so an
owner cannot set it.

**Who the limits bind.** They bind the operator's own draws: `createProjectTask` by the operator and
`drawTopUp` by the operator on its own task. The owner is never bound by a limit on its operator:
creating a task as the owner, or topping up an operator's task as the owner, ignores expiry, modes,
the per-task ceiling and the period budget. The lifetime cap is the exception only in that it counts
every draw on the operator's tasks, as `committed` always has, and still refuses only the operator's
own.

**Mode.** A task's mode is checked at creation against the mask. A mode that is not one of the five
built in has no bit, so a grant with a nonzero mask refuses it (`GrantModeNotAllowed(mode)`), and a
grant with a zero mask accepts it. Modes are not checked on a top-up: the mode is fixed at creation.

**Per-task ceiling.** `GrantRewardTooHigh(maxReward, needed)` when a new task would hold more than the
ceiling, or when the operator's top-up would take what the task holds past it. "Holds" is
`taskPoolDraws`, which falls as the task pays out, so a task that has paid part of its reward has room
to be topped up again.

**Period rule.** The period is a rolling window anchored at the first draw, not a calendar period.

- No period is running (`periodStart` is zero) or the last one is over (now is at or past
  `periodStart + periodSecs`): the next draw, by anyone, starts a new period at the current block
  time and `periodSpent` restarts at that draw.
- A draw inside a running period adds to `periodSpent`.
- The operator's own draw reverts `GrantPeriodCapExceeded(remaining, needed)` if `periodSpent + needed`
  would pass `periodCap`; when the stored period is over, `periodSpent` counts as zero for this check.
- The meter counts every draw on the operator's tasks, owner top-ups included, as `committed` does,
  but only the operator's own draws are refused.
- A refund inside the running period reduces `periodSpent`, flooring at zero. A refund after the
  period is over changes nothing: what that period spent stays spent, and the next draw starts a
  fresh period. The refund of a task drawn in an earlier period, made inside a later running period,
  reduces that later period's meter (floored at zero); the contract does not remember which period a
  task drew in. This errs toward the operator by at most the refund, which the owner can see and
  can undo by lowering the period budget.
- Changing `periodSecs` through `setGrantLimits` restarts the meter. Setting the same `periodSecs`
  keeps it, so the owner can change `periodCap` without handing the operator a fresh period.

**Re-grant keeps the limits.** `grantOperator` after a revoke does not touch `projectGrantLimits`, as it
does not touch `committed`. An owner who wants different limits states them with `setGrantLimits`
after the re-grant, or lets a backend do both (the Taskmarket API's automations switch restates the
limits it manages on every turn-on).

**Accepted grants.** Limits are not part of the terms hash, so changing them needs no new accept, and
the owner may change them on an accepted grant in either direction. The owner can revoke at any time,
so a tightening takes nothing from the operator that the owner could not already take. A loosening only
widens what the operator may do, as `raiseGrantCap` does. The operator can read the current limits
with `getGrantLimits` and sees every change in `GrantLimitsSet`. A pending grant is edited freely.
A runner that must see the limits it works under reads them before each run; it does not need to
accept again.

### GrantCommitted

`GrantCommitted(projectId, operator, committed)` is emitted after every draw and every refund on one
of an operator's tasks (it is not emitted for an owner's own task), with `committed` as it now stands.
Indexers keep the operator's net draw from it instead of summing `ProjectPoolDrawn` and
`ProjectRefunded`.

### Events, errors and views

| Item                                                                                                        | Change                                                                                                                                         |
| ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `OperatorGranted`                                                                                           | Also emitted by a re-grant after a revoke. Indexers read it as "pending again" and clear a revoke.                                             |
| `GrantCapRaised(projectId, operator, oldCap, newCap)`                                                       | New.                                                                                                                                           |
| `GrantCapBelowCommitted(cap, committed)`                                                                    | New error, from `grantOperator`.                                                                                                               |
| `GrantCapNotRaised(currentCap, requestedCap)`                                                               | New error, from `raiseGrantCap`.                                                                                                               |
| `GrantCapLowered(projectId, operator, oldCap, newCap)`                                                      | New.                                                                                                                                           |
| `GrantCapNotLowered(currentCap, requestedCap)`                                                              | New error, from `lowerGrantCap`.                                                                                                               |
| `GrantLimitsSet(...)`, `GrantCommitted(...)`                                                                | New events, above.                                                                                                                             |
| `GrantExpired`, `GrantModeNotAllowed`, `GrantRewardTooHigh`, `GrantPeriodCapExceeded`, `InvalidGrantLimits` | New errors, from the operator's draws and `setGrantLimits`.                                                                                    |
| `getGrantLimits`                                                                                            | New view.                                                                                                                                      |
| `GrantRevoked`                                                                                              | No longer returned by `grantOperator`. Still returned by `acceptGrant`, `revokeOperator`, `raiseGrantCap` and the operator's task entrypoints. |
| `getGrant`                                                                                                  | Unchanged. It returns the reset grant after a re-grant and the raised cap after a raise.                                                       |

### Upgrade

`Rev029Upgrade` runs from rev028 (`diamondVersion()` 28), paused. Order: upgrade the funding pool
proxy to the rev029 implementation (`upgradeToAndCall`, skipped when `fundingPoolRevision()` already
reports 29), then cut one (`ProjectFacet`: Replace every selector rev028 routes, Add `raiseGrantCap`,
`lowerGrantCap`, `setGrantLimits`, `getGrantLimits` and the owner transfer and extension selectors), then
cut two (Replace Core, Worker, Settlement, Evaluator, Acceptance, Rating and HooksV2 for the shared
requester check; Replace only, so resending it is harmless), then the bump to 29. A rerun after a
failure between the cut and the bump skips the pool upgrade and cut one (their markers are present) and
only resends cut two, bumps the version and unpauses. `LibRevision.CURRENT_REVISION`
is 29 and a fresh deploy routes `raiseGrantCap` directly.

State a rev028 diamond holds is read the same way after the cut: a grant revoked before it can be
granted again straight away.

## Owner transfer

### Problem

`ProjectRecord.owner` was fixed at creation and had no setter. The owner's money sits in the funding
pool under that address, and grants, schedules and every task's authority follow it, so a lost or
compromised wallet stranded the budget and a team could not hand a project to another wallet.

### Two steps

- `proposeProjectOwner(projectId, newOwner)`: the owner names the next owner. Open projects only
  (`ProjectNotOpen`). `newOwner` may not be the zero address, the current owner, the diamond or the
  funding pool (`InvalidProjectOwner`). A second proposal replaces the first. Emits
  `ProjectOwnerProposed`.
- `acceptProjectOwner(projectId)`: only the named address (`NotPendingProjectOwner`), only while the
  project is open (`ProjectNotOpen`), and only with a proposal pending (`NoPendingProjectOwner`).
  Emits `ProjectOwnerChanged(projectId, previousOwner, newOwner, sharesMoved)`.
- `cancelProjectOwner(projectId)`: the owner withdraws the proposal. Allowed at any time, including
  on a closed project, so a stale proposal can be cleared. Emits `ProjectOwnerProposalCancelled`.
- `pendingProjectOwner(projectId)`: the pending address, zero when none.

All three writes come through a trusted forwarder with a reported payment of zero, as the other grant
writes do, and are refused while the diamond is paused.

### What accept moves

- `ProjectRecord.owner` becomes the new owner.
- **The previous owner's own backing in the project's pool moves to the new owner**: its shares and
  the amount it already claimed. This is every share held at the previous owner's address, which
  includes the opening budget and anything else that address funded. No other backer's backing
  moves, and the pool's supply, value, funded total and generation do not change, so nobody's price
  or claim changes. If the new owner already holds a backing, the two are added. A backing of an
  older share generation counts as no shares and stays where it is. The pool function is
  `moveBacking`, callable only by the diamond, only on an open pool. An owner who wants to keep a
  separate stake funds from a different address.
- A grant the new owner held as an operator on this project, live at accept, is revoked
  (`OperatorRevoked`), since it now acts as owner. Its `committed` stays, so the refunds of the tasks
  it created still give back what was counted, and `mayAct` lets the owner keep control of those tasks
  (the owner is tested before the operator).
- Every other grant, accepted or pending, stays as it is. The new owner can revoke any of them.
- `taskOperators`, `taskCreators` and the project's task list do not change.

### Requester of record and who acts for a task

`Task.requester` is written once, when a task is created, and is never rewritten. For a task the
owner created it is the owner at that time; for an operator's task it is the operator or the owner
as the grant said. It is a historical record: ratings, reputation and hook contexts keep naming it.

Authority does not follow the record for a project's own tasks. `LibGuards._requireRequester`
checks, for a project task with no operator, the project's **current** owner, not `Task.requester`.
So after a transfer the new owner cancels, accepts, rejects and evaluates the tasks the previous
owner created, and the previous owner cannot. A task an operator created is decided by `mayAct`
as before: the operator, and the current owner when `ownerOverride` is set or a revoke removed the
operator's control. `HooksV2Facet` reports the requester role for the same address. The previous
owner stays a barred acting party on its own old tasks (the self-dealing checks also test
`Task.requester`), so it cannot take their work. Money owed to a project task's requester goes to the
pool, not to anyone, so a transfer never redirects a payout.

The facets that compile the shared guard (Core, Worker, Settlement, Evaluator, Acceptance, Rating,
HooksV2) are Replaced by the upgrade.

### Attacks and how each is closed

- **Front-running the accept.** The proposal names one address and only it can accept; a bystander,
  a front-runner or the previous owner reverts `NotPendingProjectOwner`. The owner may cancel or
  replace the proposal until the accept lands, which is its right. A proposal does not change
  anything, so there is nothing to grab before accept.
- **Proposing to a wrong or dead address.** Nothing happens until that address accepts, so a typo or a
  contract that cannot accept leaves the owner in place; the owner cancels.
- **Transfer to a contract.** Allowed. The diamond and the funding pool are refused because the pool
  already refuses them as backers. Accepting needs the contract to send the call through the forwarder.
- **The owner changes the project just before accept** (new grants, draws on the budget, tasks).
  The accept takes the project as it is. The new owner should read the project before accepting:
  `getProject`, `getGrant` for each operator, and the tasks. It can revoke every grant afterward, and
  tasks already created keep running.
- **Transfer while tasks are in flight.** Described above: their requester record is fixed, the current
  owner acts for them, refunds go to the pool.
- **A grant held by the new owner.** Revoked at accept as above, with `committed` kept.
- **A closed or expired project.** Propose and accept both revert `ProjectNotOpen`. A project that closes
  or passes its end date between propose and accept cannot be accepted, and moves no shares; the
  backers' pot is then claimed at the previous owner's address as it stood.
- **Moving a backer's money.** `moveBacking` moves only the address passed as the previous owner, and
  the diamond passes only the project's owner. There is no entry that names another source.
- **Replay and double accept.** Accept clears the proposal, so a second accept reverts.

## End-date extension

### Problem

`endsAt` is fixed at creation and at most 365 days away. Automations stop when a project ends, and
continuing meant a new project, a new budget and new grants.

### Change

`extendProject(projectId, newEndsAt)`: owner only, forwarder with zero payment, project open.
`newEndsAt` must be later than the current end date (`ProjectEndNotExtended(current, requested)`) and
at most 365 days after the block's timestamp (`ProjectEndTooFar`). A closed project or one past its
end date reverts `ProjectNotOpen`: an extension cannot revive a settled project. It writes
`ProjectRecord.endsAt`, calls the pool's `extendClosesAt` in the same transaction, so the two dates cannot disagree, and emits `ProjectEndExtended(projectId,
previousEndsAt, newEndsAt)`. The pool refuses a date that is not later and a pool that is not open.

The bound is measured from the extension, not from creation, so an owner can extend again later. It
is the same bound `createProject` applies.

### Where `endsAt` is used, and what an extension does there

- **Pool funding window and spending.** The pool's `closesAt` is the project's `endsAt`. Funding and
  spending stay open until the new date. Shares are priced at the pool's value, so a later backer
  pays the current value and nobody is diluted by the extension.
- **`closeProject`.** Anyone may close after `endsAt`; before it only the owner. The date moves, so a
  stranger cannot close in the extra period. The owner may still close at any time.
- **Claims and refunds to backers.** A pot is claimable once the pool is settled (closed or past
  `closesAt`). Extending moves the point a time-settled pot opens; it changes no share, no value and no
  claimed amount.
- **Task expiry bound.** `latestExpiry` is `endsAt` plus the task grace, so tasks may run until the
  new date plus grace. Tasks already created are not touched.

### What backers keep

A backer who funded under the old end date keeps:

- Its shares, the pool's value and the share price: extension writes only the closing date.
- The owner's standing power to close the project early, which opens the pot at once. The extension
  does not take that away or lock the pot beyond the owner's choice.
- A bound on the delay: each extension ends at most 365 days after it is made, only while the project
  is still open, and is public through `ProjectEndExtended`. A pot that has already opened (the
  project closed or the old date passed) can never be pushed back.
- The task grace period, fixed at creation, so money held for tasks is held at most the new end date
  plus that grace.

What changes for a backer is the date a pot that is still open settles by time. A backer's claim has
always depended on the owner's choice to keep the project running up to its end date; an extension
lets the owner choose a later date, and it is the owner's explicit act on a live project. It is not
possible to extend to take money from a pot that has already settled. Wallets and the web app show the
end date and the extension event so a backer can see it.

### Funding pool changes

`extendClosesAt(poolId, closesAt)` and `moveBacking(poolId, from, to)` are added to the manager
interface, with `fundingPoolRevision()` returning 29 so the upgrade can tell the proxy was upgraded.
The pool is a UUPS proxy; the diamond's owner owns it, and `initFundingPool` is not re-run. The pool's
namespaced storage is unchanged.

## Rationale

### Why not a new grant record per re-grant?

A fresh record under a new key would need a new mapping and a way to find the live one for every
check, and the old record's `committed` would have to be summed with it to keep the cap honest. Reusing
the record and carrying `committed` keeps one number per operator and project and leaves every read
and every other facet alone.

### Why allow a zero cap on a re-grant when committed is nonzero?

A zero cap is how an owner says "no cap beyond the budget" on any grant. The owner states it knowing
the budget is the only remaining bound. Refusing it would make a re-grant a stricter act than a
first grant for no safety gain: the project's available budget still bounds the spend.

### Why allow lowering a cap, when the first draft did not?

Revoking and granting again with a lower cap was the only way down, and it pauses everything the
operator was doing and needs a fresh accept. A bound the owner can tighten in place is easier to rely
on. The harm the first draft saw, an operator partway through a task that needs a top-up it can no
longer draw, is bounded by `committed`: a cap can never go below what the operator already holds, so
only room for new draws shrinks, which the owner could already remove by revoking.

### Why side storage for the limits?

`GrantTerms` is hashed by `acceptGrant` and stored inside `Grant`, and both appear in the ABI. Adding
a field would change the hash an accepted operator signed, and every client's decoding of
`getGrant`. A new mapping at the end of `AppStorage` changes none of that.

### Why lenient on accepted grants?

A rule that let the owner only tighten would force a revoke and a re-grant to give an operator more
room, which is the path this revision removes. Loosening harms nobody the owner has not already
decided to trust, and the operator sees each change as an event.

## Tests

- `test/ProjectGrants.t.sol`: re-grant after a revoke (accepted and pending), the reset to pending,
  the operator accepting the new terms and the hash check, committed carried over and bounding total
  spend, an old task's refund freeing it, `GrantCapBelowCommitted`, refusal for a non-owner and for a
  live accepted grant, revoke again, control and requester of record under the new terms, raising a
  cap (accepted, pending, after a re-grant), and every refusal of `raiseGrantCap` (non-owner, lower,
  equal, zero, no cap, revoked, missing grant, direct call, unknown project).
- `test/ProjectGrantLimits.t.sol`: the limits default to none; `setGrantLimits` (event, storage,
  pending grants edited freely, tightening and loosening an accepted grant, non-owner, missing and
  revoked grants, every malformed input); expiry (operator refused, owner not, extended); the mode
  mask, including a mode with no bit and the owner not bound; the per-task ceiling and a top-up past
  it; the period budget (within a period, rollover after `periodSecs`, a refund inside the period, a
  refund after it ends, an owner top-up counted but never refused, a changed period length restarting
  the meter, and the lifetime cap still applying); `lowerGrantCap` (pending and accepted, down to
  `committed`, below it, not lowered, non-owner, missing and revoked); `GrantCommitted` after a draw,
  a top-up and a refund; limits surviving a re-grant.
- `test/Rev029Upgrade.t.sol`: routing and version, a grant revoked on rev028 granted again after the
  cut, the Tempo gas estimate, pause across the cut, resume after a partial run, `FORGE_KEEP_PAUSED`,
  and the precondition revert.
- `test/ProjectOwner.t.sol`: the two-step transfer and every refusal (non-owner, invalid targets,
  closed and expired project, wrong accepter, replaced and cancelled proposals, direct call and
  payment), what moves in the pool (the owner's backing only, merge into an existing backing, the
  pot claimed by the new owner), who acts for in-flight tasks (owner tasks, operator tasks, hook
  roles), a new owner holding a live grant, and the end-date extension (open window, task grace,
  unchanged shares and value, claim at the new date, early close, the 365 day bound from the
  extension, non-owner, closed and expired project, repeated extension). Pool manager functions are
  manager-only.
- `test/Rev029Upgrade.t.sol` also covers the funding pool upgrade in place with state kept, the owner
  transfer and extension working after the cut, the replaced facets and the Tempo gas estimate of cut
  two.
