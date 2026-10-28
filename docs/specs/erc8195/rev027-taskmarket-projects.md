# Rev027 -- Projects: one budget spent on ordinary tasks

## Status

Implemented; not deployed on any chain. Projects ship in the rev027 cut, with the reserved worker
(`rev027-reservation-mode.md`). This document covers the project record, its budget and refunds,
and operator grants.

## Motivation

Through rev026 every task is funded on its own from the requester's wallet. Someone with one goal
and one budget, such as a website for 10 USDC, has to guess each piece's price up front and fund
every task separately. Nothing groups the pieces or caps what the whole costs, and a cancelled or
cheaper-than-expected task pays its money back to the wallet rather than to the work it was set
aside for.

## Problem 1 -- no budget that tasks draw from

A requester cannot set money aside once and spend it piece by piece. Each task pulls a new payment.

## Problem 2 -- unspent money leaves the goal

A refund, an auction that settles below its maximum price, a split that rounds down, a returned
evaluator stake and a worker-stake penalty all go to the requester's wallet. A requester working
towards one goal has to put that money back by hand.

## Changes

### Storage

Appended to `AppStorage`:

- `projectCount`: projects created so far. IDs run from 1; zero means no project.
- `projects`: `projectId => Project { owner, endsAt, closed, funded, available }`. `funded` is
  everything paid in; `available` is unspent and uncommitted.
- `projectTaskIds`: `projectId => bytes32[]`, the project's tasks in creation order.
- `taskProjects`: `taskId => projectId`.
- `taskCreators`: `taskId => address`, who created a project task.
- `projectPrepaid`: nonzero only inside `createProjectTask` (see Create a task).

### Create, top up, close

- `createProject(token, budget, endsAt)`: through a trusted forwarder that reports a payment of
  exactly `budget`. `token` must be the task payment stablecoin, `budget` nonzero and `endsAt` in
  the future. The caller is the owner. The budget is booked in `totalLiabilities`.
- `topUpProject(projectId, amount)`: the owner adds to an open project, with the same payment
  check.
- `closeProject(projectId)`: the owner at any time, anyone once `block.timestamp >= endsAt`. Pays
  `available` to the owner, releases its booking and marks the project closed.

A project is open while it is not closed and `block.timestamp < endsAt`.

### Create a task

`createProjectTask(projectId, config, hookConfig, content, evaluatorConfig, terms, reservedWorker)`
creates a task exactly as `createTask` with a reserved worker does, with the owner as requester,
except for funding. The owner of an open project calls it through a trusted forwarder that reports
no payment. The reward plus any evaluator stake leaves `available` and its booking moves from the
project to the task: `totalLiabilities` falls by that amount, and the task's own creation booking
raises it by the same. No tokens move.

`projectPrepaid` carries the amount into task creation, whose funding check (`_requireFunding`)
then expects the creation to cost exactly that amount and the forwarder to report no payment. It is
cleared before the call returns. Every mode, hook, evaluator, settlement term and rating works on a
project task unchanged.

### Where a task's money goes

Every place that paid money to a task's requester now calls `LibProject.payRequester`:

- `cancelTask`, `declineReservation`, the reserved-task lapse and `refundExpired`;
- the evaluator-stake refund on cancel and decline;
- the auction refund of `maxPrice - price` on acceptance and on settlement;
- the split remainder of `acceptSubmissions` and of an evaluator's multi-award verdict;
- the refund on an evaluator's rejection;
- a worker-stake penalty when `penaltyTo` is the requester;
- the refund when `updateTask` lowers a reward.

For a task in no project it transfers to `task.requester` as before. For a project task it credits
the project's `available` and books the amount in `totalLiabilities` while the project is open,
emitting `ProjectRefunded`; once the project is closed or past its end date it transfers to the
project owner. The credit happens before the entrypoint's `LibEscrow.release`, which then releases
the task's whole booking, so the money's booking moves from the task to the project and the
solvency check holds throughout.

### End date

The end date stops new tasks and top-ups. A task already funded runs to its own end, and anything
it pays its requester after the end date goes straight to the owner. Applications warn when a
task's deadline falls after the project's end date; the contract does not cap it.

### Errors, events, views

Events: `ProjectCreated`, `ProjectToppedUp`, `ProjectTaskCreated`, `ProjectRefunded`,
`ProjectClosed`. Errors: `ProjectNotFound`, `NotProjectOwner`, `ProjectNotOpen`,
`ProjectAlreadyClosed`, `ProjectBudgetZero`, `ProjectEndNotInFuture`, `ProjectTokenNotAllowed`,
`ProjectBudgetExceeded(available, needed)`, `NotProjectOperator`, `InvalidOperator`,
`GrantNotAccepted`, `GrantAlreadyAccepted`, `GrantRevoked`, `GrantNotFound`,
`OperatorCapExceeded(remaining, needed)`. Grant events: `OperatorGranted`, `GrantAccepted`,
`OperatorRevoked`. Views: `getProject`, `projectOf`, `taskCreatedBy`, `taskOperator`, `getGrant`,
`projectTaskCount`, `projectTasks(projectId, offset, limit)`, `projectCount`.

What a project has committed and spent is not stored: the indexer derives it from the project's
tasks and events. Keeping it on chain would need a write at every terminal transition of every
mode.

### Operator grants

The owner can let others spend the budget without handing over the money. Each operator has its own
grant, stored per project and operator:

- `grantOperator(projectId, operator, terms)`: owner only. The operator may not be the owner or the
  zero address. The owner may call it again to change the terms until the operator accepts. A
  revoked grant cannot be granted again.
- `acceptGrant(projectId)`: the operator agrees to the terms as recorded, which freezes them. An
  operator can create tasks only after this.
- `revokeOperator(projectId, operator)`: owner only. The operator can no longer create tasks.

The terms are stated in full by the caller; the contract stores no project-level defaults:

| Term | Meaning |
| --- | --- |
| `cap` | The most the operator's tasks may hold from the budget at once, net of what their refunds return. Zero means no cap beyond the project's available budget. |
| `requesterOfRecord` | `Owner` or `Operator`: who is `task.requester` on the operator's tasks, and so who ratings and reputation follow. |
| `ownerOverride` | The owner may act on the operator's tasks. When it is false, only the operator may. |
| `revokeRemovesControl` | After a revoke, control of the operator's existing tasks passes to the owner and the operator loses it. When false, the operator finishes what it started. |

`createProjectTask` is callable by the owner or by an operator with an accepted, unrevoked grant.
For an operator it also checks `committed + amount <= cap`, where `committed` is the operator's
draw on the budget net of refunds: a refund that returns money to the project lowers `committed`
by the same amount, floored at zero because a worker's forfeited stake is not part of the draw. The
task records its operator in `taskOperators`; a task the owner creates has none.

An operator can never top up or close a project, grant, accept for another or revoke. Those stay
owner-only, and the one case where a non-owner can close a project is the public close after its
end date.

### Who may act as the requester

Every requester entrypoint checks through `LibGuards._requireRequester(s, taskId, caller)`. For a
task with no operator it accepts `task.requester` alone, as before. For an operator's task the
grant decides, whoever `task.requester` is:

- the operator acts unless its grant was revoked with `revokeRemovesControl`;
- the owner acts when `ownerOverride` is set, and always once a revoke removed the operator's
  control;
- anyone else does not.

Refunds are unaffected: they go to the project (or the owner after it ends) whoever cancels.

## Rationale

### Why a record that funds tasks, not a new task mode?

A project has no worker, submission or mode of its own. Funding ordinary tasks keeps every mode,
hook, evaluator, settlement term and rating working on project tasks with no change, and puts all
of the new behaviour in one place: where money is drawn from and where it goes back.

### Why keep refunds inside the diamond?

Crediting the budget instead of transferring keeps the money where the next task can use it, at no
cost, and lets the rev026 liability ledger track it. A transfer to the owner followed by a top-up
would need two transactions and the owner's attention for every refund.

### Why does the end date stop spending but not work?

A task's own deadline, review window and terms were agreed when it was funded. Cutting them short
because the project ended would break those terms for the worker.

## Upgrade

Part of the one rev027 diamond cut, `script/upgrades/Rev027Upgrade.s.sol` (see
`rev027-reservation-mode.md` for the rest of it). For projects the cut Adds `ProjectFacet`, and
Replaces `CoreFacet`, `AcceptanceFacet`, `EvaluatorFacet` and `SettlementFacet`, which now pay a
requester through `payRequester`, check task funding through `_requireFunding` and check the
requester through `_requireRequester`, and `RatingFacet` and `WorkerFacet`, which check the
requester through it. `LibRevision` is 27. No initialisation: every new field reads as zero, and no
existing task belongs to a project.

## Trade-offs

- Committed and spent are derived off chain, so a contract cannot read them.
- A project budget is booked like a task, so an accounting fault in project code is caught by the
  same solvency check rather than by a separate one.

## Tests

`test/Project.t.sol`: create, top-up and close, with their rejections (non-allowlisted token,
payment mismatch, zero budget, past end date, not the owner, closed); project tasks drawing the
reward and an evaluator stake; refunds to the project on cancel, expiry and an auction's unspent
remainder; refunds to the owner after the end date and after close; a refunded budget funding the
next task; the surplus sweep leaving the budget; an ordinary task still refunding its requester;
and the diamond's balance equalling its liabilities after every step. `test/ProjectGrants.t.sol`:
grant, accept and revoke with their rejections; an operator spending only after accepting, within
its cap, with the cap released by a refund; operators refused at the owner-only functions; and who
may act on an operator's task under every `requesterOfRecord`, `ownerOverride` and
`revokeRemovesControl` setting, before and after a revoke. `test/RequesterGuard.t.sol`: every
requester entrypoint refuses a non-requester.

## Affected Files

- `src/interfaces/ITMPProject.sol`, `src/facets/ProjectFacet.sol`, `src/libraries/LibProject.sol`
  (new)
- `src/facets/RatingFacet.sol`, `WorkerFacet.sol`
- `src/libraries/LibAppStorage.sol`, `LibGuards.sol`, `LibTaskCreation.sol`, `LibTaskMarket.sol`,
  `LibTerms.sol`, `LibRevision.sol`
- `src/facets/CoreFacet.sol`, `AcceptanceFacet.sol`, `EvaluatorFacet.sol`, `SettlementFacet.sol`
- `script/upgrades/Rev027Upgrade.s.sol`, `script/lib/FacetSelectors.sol`,
  `script/DiamondDeploy.s.sol`, `scripts/generate-abi.ts`
- `test/Project.t.sol`, `test/ProjectGrants.t.sol`, `test/RequesterGuard.t.sol`,
  `test/DiamondSelectorParity.t.sol`, `test/Diamond.t.sol`,
  `test/helpers/DiamondTestHelper.sol`
