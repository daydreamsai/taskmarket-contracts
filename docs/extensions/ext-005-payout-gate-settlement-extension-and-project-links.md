# EXT-005: Payout gate: settle-without-payout, deadline extension and project links

This revises `PayoutGateHook` (`evm/src/hooks/payout-gate/PayoutGateHook.sol`), the hook described in
the rev028 spec under "The payout gate hook". The hook stays a standalone, opt-in hook deployed on
its own with `make deploy-payout-gate-hook <chain>`. It is not part of any diamond revision, adds no
facet function and changes no `AppStorage`. A task attaches a gate by address at creation, so a
chain redeploys the hook and points its configuration at the new address; the diamond is untouched.

## Requirement

The task's diamond must dispatch Task Hook V2 (`diamondVersion()` of 28 or later). The deploy script
refuses a diamond below rev028.

## What did not change

- The configuration at creation: `abi.encode(bytes32 gatingTaskId, uint64 deadline, bytes32[] gatesTaskIds)`.
- Capability bits 0, 13 and 30; the interface; `gateOf` and `isOpen`.
- The deadline window at creation: 1 hour to 180 days after creation.
- At most 16 gated tasks per gating task.
- The gate opens when the gating task ended `Accepted`, when the deadline has passed, or when the
  call settles a dispute. The non-vetoable exits are never held.
- The call roles are read and pinned by the diamond at attach.

## 1. A gating task that settles without paying out

If the gating task ends `Cancelled` or `Expired`, it can never pay, so the gate can never open
through it. A rejected submission is not a settlement: the task stays live and can still be paid.

Two rules were weighed:

- **Open the gate.** The gated task could then be paid with no sign-off. The gating task is often a
  review or approval, and whoever can cancel it (the requester, or a project operator under a grant)
  would release the payout the gate was set to hold. It fails open.
- **Re-link once.** The gate stays closed. The caller who linked it may link a replacement gating
  task, once. It fails closed.

The hook uses the second rule, because a gate should not open as a side effect of a cancellation.
The gate never locks funds forever: the deadline still opens it, and a second failed gating task
simply waits for it.

Rules for the re-link (the same call as the first link):

- The current gating task must have ended `Cancelled` or `Expired` (read from the diamond). A live
  or paid one is refused with `PayoutGate__AlreadyLinked`.
- Only one re-link per gate. A second is refused with `PayoutGate__RelinkUsed`. A refused call does
  not use it up.
- The replacement must satisfy every rule of a first link (exists, not the gated task, not settled,
  same owner, see section 3).
- A gate that is already open refuses the call with `PayoutGate__AlreadyOpen`.
- It emits `PayoutGateRelinked(taskId, previousGatingTaskId, gatingTaskId)`.

An `Expired` task stays `Open` or `Claimed` until someone calls `refundExpired`, which is
permissionless; the re-link is available once that has run.

## 2. Extending the deadline

The caller may move the deadline later, through `onCall`:

- Upward only: the new deadline must be greater than the current one.
- Never later than creation + 180 days. The cap is measured from creation, not from the call, so
  repeated extensions cannot push a gate past 180 days. This is the bound that keeps a gate from
  holding a payout forever.
- Only while the gate is closed. A gate already open (deadline passed or gating task paid) refuses
  the call with `PayoutGate__AlreadyOpen`, so an extension never closes a gate that has opened.
- Out of range: `PayoutGate__ExtensionOutOfWindow(deadline, current, latest)`.
- It emits `PayoutGateExtended(taskId, previousDeadline, deadline)`.

The gated task's own expiry is a separate clock. Extending the task's expiry with `updateTask`
changes nothing in the gate, and the hook declares no `beforeUpdate`, so it never blocks that edit.
A gate deadline may pass the task's expiry: the expiry refund is never held, so the requester's
refund is not delayed. To keep a gate in step with a longer task, the caller extends the gate
deadline with this call; it stays inside the 180-day cap whatever the task's expiry becomes.

## 3. Callers and the same-owner rule

`hookCallRoles()` is `ROLE_REQUESTER | ROLE_PROJECT`. A call is accepted from:

- the task's requester (`ROLE_REQUESTER` and `caller == ctx.requester`), or
- a project operator holding `ROLE_PROJECT` on the gated task: the project's owner, the operator
  that created the task, or an operator with an accepted, unrevoked grant. Under a grant that makes
  the owner the requester of record, the runner holds `ROLE_PROJECT` only.

A link or re-link names a gating task that must belong to the same owner as the gated task:

- it has the same requester of record as the gated task; or
- for a caller holding `ROLE_PROJECT`, it sits in the same project as the gated task.

Otherwise it is refused with `PayoutGate__RequesterMismatch`. A forged or mistaken link can only
point at a task the gated task's own requester or project already controls. A caller with only
`ROLE_REQUESTER` gets no project rule. Gating mode at creation (a new task listing the tasks it
gates) still requires the same requester.

## Call data

`onCall` takes `abi.encode(uint8 action, bytes32 value)` and nothing else:

| action | name | value |
| --- | --- | --- |
| 1 | `CALL_LINK` | the gating task id (a first link, or the re-link) |
| 2 | `CALL_EXTEND` | the new deadline, as a `uint256` word |

Any other length or action reverts `PayoutGate__InvalidConfig`.

## Reads

`gateOf` is unchanged. `gateDetailsOf(taskId)` adds the latest allowed deadline (`maxDeadline`),
whether the gating task failed (`gatingFailed`) and whether the re-link is used (`relinked`).

## Errors

Changed or added: `PayoutGate__NotAuthorized` (replaces `PayoutGate__NotRequester`),
`PayoutGate__RelinkUsed`, `PayoutGate__AlreadyOpen`, `PayoutGate__ExtensionOutOfWindow`.

## Testing

- `evm/test/PayoutGateHook.t.sol`: every path above, the original gate behaviour, gating mode, and a
  project operator under a grant.
- `evm/test/DeployHooksV2Scripts.t.sol`: the deploy script and its rev028 check.
- `make smoke payout-gate` (and `make smoke payout-gate local-tempo`) runs it end to end.
