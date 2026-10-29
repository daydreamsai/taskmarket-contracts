# Rev027 -- Projects: one crowdfunded budget spent on ordinary tasks

## Status

Implemented; not deployed on any chain. Projects ship in the rev027 cut, with the reserved worker
(`rev027-reservation-mode.md`). This document covers the project record, funding pools (the
crowdfunded budget every project spends from: backers, the pot of what is left, and claims),
refunds, and operator grants.

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

## Problem 3 -- one wallet pays for a shared goal

A goal that several people want funded, such as a public tool or a community site, has to be paid
for by one wallet, which then carries the whole cost and keeps whatever is left over. Others who
want to chip in have no way to add to the budget and no claim on what is not spent.

## Changes

### Storage

Appended to `AppStorage`:

- `projectCount`: projects created so far. IDs run from 1; zero means no project.
- `projects`: `projectId => ProjectRecord { owner, endsAt }`. The budget is the project's pool.
- `projectTaskIds`: `projectId => bytes32[]`, the project's tasks in creation order.
- `taskProjects`: `taskId => projectId`.
- `taskCreators`: `taskId => address`, who created a project task.
- `projectPrepaid`: nonzero only inside `createProjectTask` (see Create a task).
- `projectGrants`, `taskOperators`: operator grants (see Operator grants).
- `fundingPools`: `poolId => Pool { token, closesAt, closed, module, funded, available,
  outstanding, totalShares, claimed }`.
- `poolBackings`: `poolId => backer => Backing { shares, claimed }`.
- `taskPoolDraws`: `taskId => uint256`, what a project task still holds of what its pool spent on
  it (see Outstanding).

Every field is new in rev027, after the last rev026 field, and rev027 is not deployed anywhere, so
the rev027 fields themselves could still be reshaped: `projects` now holds only the owner and the
end date, and the budget fields live in the pool.

### Funding pools

A funding pool collects money from any number of backers for one purpose, which one module of the
diamond spends while the pool is open. A project is the first module; the pool is generic, and
`LibFundingPool` and `FundingPoolFacet` know nothing about projects.

The pool record:

| Field | Meaning |
| --- | --- |
| `token` | The token held: always the task payment stablecoin, the only token the escrow ledger books. |
| `module` | The module that opened the pool and alone spends from it. Projects use `keccak256("taskmarket.project")`. |
| `closesAt` | When the pool settles on its own. Zero means only an explicit close settles it. |
| `closed` | The module closed the pool explicitly. |
| `funded` | Every amount paid in, the module's opening one included. Fixed once settled. |
| `available` | While open, what the module can spend; once settled, the backers' unclaimed pot. |
| `outstanding` | What the module has spent on work that has not finished. |
| `totalShares` | Every backer's shares. Fixed once settled. |
| `claimed` | Everything paid out of the pot so far. |

A pool is **open** while it is not closed and either `closesAt` is zero or
`block.timestamp < closesAt`. Otherwise it is **settled**, and it never opens again. Settlement at
`closesAt` needs no transaction: every entrypoint reads the date.

Pool IDs are derived, never chosen by a caller: `poolIdOf(module, key) =
keccak256(abi.encode(module, key))`, so two modules can never collide. A project's pool is
`poolIdOf(keccak256("taskmarket.project"), projectId)`, which `projectPoolId(projectId)` returns.

The module side is internal (`LibFundingPool`), reachable only from the module's own code:

- `open(poolId, token, module, closesAt)` creates the record; it reverts `PoolAlreadyExists` for a
  taken ID.
- `credit(poolId, funder, backer, amount)` adds money to an open pool, mints the backer's shares
  (see Shares) and books it; the module uses it for the opening contribution.
- `spend(poolId, amount)` takes money out of an open pool for the module, adds it to
  `outstanding`, releases its booking (the module books it again where it puts it) and emits
  `PoolSpent(poolId, amount)`. It reverts `PoolNotOpen` on a settled pool and
  `PoolBalanceExceeded(available, needed)` when `amount > available`.
- `refund(poolId, amount)` returns money to the pool, books it and emits
  `PoolRefunded(poolId, amount)`: spendable again while the pool is open, part of the backers' pot
  once it is settled. It is one write either way.
- `finish(poolId, amount)` takes `amount` out of `outstanding` once the work no longer holds it.
- `close(poolId)` settles the pool now and emits `PoolClosed(poolId, pot)`; it reverts
  `PoolAlreadyClosed` on a second close. No money moves.

The backers' side is public (`FundingPoolFacet`):

- `fund(poolId, amount, onBehalfOf)`: anyone, while the pool is open. `amount` buys shares for
  `onBehalfOf`, or for the funder when `onBehalfOf` is zero; `onBehalfOf` may not be the diamond
  itself (`PoolInvalidBacker`), whose shares would be claimed into it as unbooked surplus. Relayed through a
  trusted forwarder, the funder is the relayed sender and the forwarder must report a payment of
  exactly `amount`, as for every relayed payment. Called directly, the diamond pulls `amount` from
  the caller with `transferFrom`, so a router or another contract can fund for a user it names. It
  emits `PoolFunded(poolId, funder, onBehalfOf, amount, shares)` and reverts `PoolNotFound`,
  `PoolAmountZero`, `PoolNotOpen`, `PoolInvalidBacker`, `PoolSharesZero`,
  `ForwardedPaymentMismatch`, or the token's own error for a missing allowance.
- `claim(poolId, backer)`: anyone, directly or relayed (the forwarder must report no payment). Pays `backer` its share of a settled pool's
  pot and emits `PoolClaimed(poolId, backer, amount)`; the money always goes to `backer`, so the
  backend can sweep for backers who never send a transaction. It reverts `NothingToClaim` when the
  share is zero: a pool still open, a non-backer, or a backer that has claimed everything so far.
- Views: `getPool(poolId)` returns `PoolInfo { token, module, closesAt, closed, settled, funded,
  available, outstanding, totalShares, potIn, claimed }`; `sharesOf(poolId, backer)`;
  `claimable(poolId, backer)`, zero while the pool is open. Each reverts `PoolNotFound` for an unknown pool.

Both entrypoints respect the pause and the reentrancy guard, book or release the money in
`totalLiabilities`, and end with the solvency check. There is no public way to open, spend from,
refund to or close a pool: only modules do that.

### Outstanding

While a pool is open its value is `available + outstanding`: what it holds plus what it has spent on
work that has not finished. A project task's draw (its reward and evaluator stake at creation, and
any later top-up) is recorded in `taskPoolDraws` and added to `outstanding` by `spend`. After every
payout, `LibEscrow.release` calls `LibProject.finishDraw(taskId, owed)`, which lowers the task's
draw to what the task still owes in escrow and takes the difference out of `outstanding`:

- a refund to the pool has already added the money to `available`, so it moves from `outstanding`
  back to `available` and the value is unchanged;
- money paid to a worker or an evaluator leaves the value;
- a terminal task owes nothing, so whatever is left of its draw leaves `outstanding` then;
- a worker's stake can make the task owe more than its draw; the draw does not grow, so a forfeited
  stake refunded to the pool is a windfall that raises the value.

Hooking the one `release` every payout entrypoint already calls covers every mode's terminal
transition without a write at each one.

### Shares

Funding buys shares at the pool's value at that moment:

```
first credit (the owner's opening budget):  shares = amount * 10^12
every later credit while open:              shares = amount * totalShares / value
                                            value  = available + outstanding
```

Shares round down. A backer that joins after money was spent pays only for what is left, and one
that joins after a windfall pays for it, so neither earlier spending nor an earlier windfall moves
between backers. `PoolFunded` carries the shares minted, so an indexer need not recompute them.

**A pool worth nothing.** When the value is zero while shares exist (everything spent and paid
out), the old shares are worth nothing. The value is then taken as one base unit, so the new backer
receives `amount / (amount + 1)` of the pool: all of its money back but under one base unit.

**Why 10^12 shares per base unit.** Rounding a credit's shares down can cost the backer up to one
share's value. The value is internal bookkeeping, never the token balance, so tokens sent straight
to the diamond are surplus and change no price. A windfall can still raise a share's value: an
owner opening with one base unit and forfeiting a large stake of its own worker into the pool makes
each share worth a great deal, and at one share per base unit a later backer of 1,500 USDC would
lose 250 USDC to rounding (`test_InflationAttack_DoesNotDiluteALaterBacker` fails that way with one
share per base unit). Starting a share at 10^-12 of a base unit keeps that loss under one base unit
for any windfall that can exist. This is the usual share-offset defence against first-depositor
inflation and rounding attacks on share-priced vaults. In the test the owner opens with 1 base unit
and forfeits a 1,000 USDC stake into the pool; a backer then funds 1,500 USDC plus 7 base units. At
one share per base unit it buys a single share and claims back 1,250 USDC; at 10^12 it claims back
all but under one base unit. The developer approved 10^12 over one share per base unit on
2026-10-29, after the security review. Multiplication goes through a 512-bit `mulDiv`, so large share
counts do not overflow; a credit that would buy no share reverts `PoolSharesZero`.

### The pot and claims

Once a pool is settled, nothing can spend from or fund it, so its `available` balance is the
backers' pot. It holds what was unspent at settlement, whether or not anyone closed the pool, plus
every later refund, which lands in `available` exactly as it did while the pool was open. A claim
moves what it pays from `available` to `claimed`. So the cumulative pot is

```
potIn = available + claimed      (once settled; zero while open)
```

and it only grows. `potIn` is reported by `getPool` but not stored: storing it would make every
refund branch on whether the pool is settled, at every payout site (see Where a task's money goes).
Each backer's share is proportional to its shares, and the accounting is cumulative, so money that
reaches the pot after some backers have claimed is shared out the same way:

```
claimable(backer) = potIn * shares / totalShares - backer.claimed
```

The formula is safe because `totalShares` and every backer's shares are fixed before there is a
pot: funding needs an open pool, and a pool never opens again. `potIn` only grows, so each
entitlement `potIn * shares / totalShares` only grows and never falls below what the backer already
claimed.

**Rounding dust.** Each entitlement rounds down, so the entitlements sum to at most `potIn`: claims
can never exceed the pot and `available` can never underflow. What rounding leaves is `potIn` minus
the sum of the entitlements, under one base unit per backer at any time; because the formula is
applied to the cumulative pot, the dust does not grow with each refund. It stays in the escrow, in
`available` and booked in `totalLiabilities`, and is never paid out, so it can only over-cover the
liabilities: the diamond can never become insolvent through it, and the surplus sweep can never take
it. With a 6-decimal stablecoin this is under a millionth of a unit per backer.

### Create and close a project

- `createProject(token, budget, endsAt)`: through a trusted forwarder that reports a payment of
  exactly `budget`. `token` must be the task payment stablecoin, `budget` nonzero and `endsAt` in
  the future. The caller is the owner. It opens the project's pool with `closesAt = endsAt` and
  credits `budget` as the owner's contribution (`PoolOpened`, `PoolFunded`), then emits
  `ProjectCreated`. `endsAt` may be at most 365 days after the block's timestamp
  (`ProjectEndTooFar`), so backers' money cannot be held in an open pool indefinitely; an owner
  that needs longer creates a new project.
- Anyone backs the project by funding its pool with `fund(projectPoolId(projectId), ...)`. An
  operator may back a project like anyone else.
- `closeProject(projectId)`: the owner at any time, anyone once `block.timestamp >= endsAt`. Closes
  the pool: what it holds is from now on the backers' pot. No tokens move and nothing is rebooked.
  Emits `PoolClosed` and `ProjectClosed(projectId, closedBy, leftover)`, where `leftover` is what
  the pool held at closing. It reverts `ProjectAlreadyClosed` on a second close. Relayed, the forwarder must
  report no payment.
- Backers claim their share of the pot with `claim(projectPoolId(projectId), backer)`.

A project is open while its pool is.

### Create a task

`createProjectTask(projectId, config, hookConfig, content, evaluatorConfig, terms, reservedWorker)`
creates a task exactly as `createTask` with a reserved worker does, with the owner as requester,
except for funding. The owner of an open project calls it through a trusted forwarder that reports
no payment. The reward plus any evaluator stake is spent from the pool and its booking moves from
the pool to the task: `totalLiabilities` falls by that amount, and the task's own creation booking
raises it by the same. No tokens move.

`projectPrepaid` carries the amount into task creation, whose funding check (`_requireFunding`)
then expects the creation to cost exactly that amount and the forwarder to report no payment. It is
cleared before the call returns. Every mode, hook, evaluator, settlement term and rating works on a
project task unchanged.

### Top-ups draw from the pool

A reward increase (`updateTask`) or an evaluator stake (`assignEvaluator`) added to a live project
task is spent from the project's pool through `LibProject.topUp`, under the same checks as creating
a task: the project must be open, the pool must hold the amount, and an operator acting on its own
task needs an accepted, unrevoked grant and stays within its cap. The forwarder must report no
payment. The amount counts toward the task's operator's `committed` whoever adds it, so the task's
refunds give back what was counted; the owner acting on an operator's task is not held to the
operator's cap. Paid from the requester's wallet instead, a top-up would be refunded into the pool
when the task ends and become a gift to every backer, and it would get round both the closed pool
and the operator cap.

`updateTask` reaches the pool through `ProjectFacet.drawTopUp(taskId, caller, amount)`, which only
the diamond itself may call (`NotDiamond` otherwise) and which runs inside `updateTask`'s pause and
reentrancy checks. Calling across facets keeps `LibProject.draw` out of `CoreFacet`, which has
little room left under the runtime size limit; `assignEvaluator` calls `LibProject.topUp` directly.

### Where a task's money goes

Every place that paid money to a task's requester now calls `LibProject.payRequester`:

- `cancelTask`, `declineReservation`, the reserved-task lapse and `refundExpired`;
- the evaluator-stake refund on cancel and decline;
- the auction refund of `maxPrice - price` on acceptance and on settlement;
- the split remainder of `acceptSubmissions` and of an evaluator's multi-award verdict;
- the refund on an evaluator's rejection;
- the evaluator fee refunded when a dispute resolution overturns the verdict;
- a worker-stake penalty when `penaltyTo` is the requester;
- the refund when `updateTask` lowers a reward.

For a task in no project it transfers to `task.requester` as before. For a project task it refunds
the amount to the project's pool, booked in `totalLiabilities`, and emits
`ProjectRefunded(projectId, taskId, amount)`; no tokens move. While the project is open that is
budget the next task can draw on; once it is closed or past its end date it is the backers' pot. The
refund happens before the entrypoint's `LibEscrow.release`, which then releases the task's whole
booking, so the money's booking moves from the task to the pool and the solvency check holds
throughout.

`payRequester` is called at every requester payout site, and `SettlementFacet` sits close to the
24,576-byte contract size limit, so the refund has one path with no branch on whether the pool is
settled, and lives in its own private function so the optimizer does not inline it at every site.
Versions that credited a separate pot field once the pool was settled measured 300 to 1,000 bytes
more in `SettlementFacet`, and one went over the limit.

`test/ProjectPayRequesterScan.t.sol` scans the facets and libraries and fails on any token
transfer to a task's requester outside `payRequester`, and `test/ProjectRequesterPayouts.t.sol`
checks each payout above lands in the project, not in an operator's wallet.

### End date

The end date stops new tasks and funding. A task already funded runs to its own end, and anything
it pays its requester after the end date goes into the backers' pot. Applications warn when a
task's deadline falls after the project's end date; the contract does not cap it.

### Errors, events, views

Projects. Events: `ProjectCreated(projectId, owner, budget, endsAt)`, `ProjectTaskCreated`,
`ProjectRefunded(projectId, taskId, amount)`, `ProjectClosed(projectId, closedBy, leftover)`.
Errors: `ProjectNotFound`, `NotProjectOwner`, `ProjectNotOpen`, `ProjectAlreadyClosed`,
`ProjectBudgetZero`, `ProjectEndNotInFuture`, `ProjectEndTooFar`, `ProjectTokenNotAllowed`, `NotProjectOperator`,
`InvalidOperator`, `GrantNotAccepted`, `GrantAlreadyAccepted`, `GrantRevoked`, `GrantNotFound`,
`OperatorCapExceeded(remaining, needed)`. Grant events: `OperatorGranted`, `GrantAccepted`,
`OperatorRevoked`. Views: `getProject` (owner and end date, with `closed`, `funded` and `available`
read from the pool), `projectPoolId`, `projectOf`, `taskCreatedBy`, `taskOperator`, `getGrant`,
`projectTaskCount`, `projectTasks(projectId, offset, limit)`, `projectCount`.

Funding pools. Events: `PoolOpened(poolId, module, token, closesAt)`, `PoolFunded(poolId, funder,
onBehalfOf, amount, shares)`, `PoolSpent(poolId, amount)`, `PoolRefunded(poolId, amount)`,
`PoolClosed(poolId, pot)`, `PoolClaimed(poolId, backer, amount)`. Errors: `PoolNotFound`,
`PoolAlreadyExists`, `PoolNotOpen`, `PoolAlreadyClosed`, `PoolAmountZero`,
`PoolBalanceExceeded(available, needed)`, `PoolTransferFailed`, `PoolSharesZero`,
`PoolInvalidBacker`, `NothingToClaim`. Views: `getPool`, `sharesOf`, `claimable`.

What a pool has spent on unfinished work is stored (`outstanding`), because pricing shares needs
it. A task finishing emits no pool event of its own: `outstanding` falls inside the task's payout,
and an indexer that needs it reads `getPool` or follows the task's own terminal events.

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
For an operator it also checks `committed + amount <= cap` (as does a top-up, see Top-ups draw from
the pool), where `committed` is the operator's
draw on the budget net of refunds: a refund that returns money to the project lowers `committed`
by the same amount, floored at zero because a worker's forfeited stake is not part of the draw. The
task records its operator in `taskOperators`; a task the owner creates has none.

An operator can never close a project, grant, accept for another or revoke. Those stay owner-only,
and the one case where a non-owner can close a project is the public close after its end date. An
operator may fund a project's pool, as anyone may, and is then a backer like any other.

### Who may act as the requester

Every requester entrypoint checks through `LibGuards._requireRequester(s, taskId, caller)`. For a
task with no operator it accepts `task.requester` alone, as before. For an operator's task the
grant decides, whoever `task.requester` is:

- the operator acts unless its grant was revoked with `revokeRemovesControl`;
- the owner acts when `ownerOverride` is set, and always once a revoke removed the operator's
  control;
- anyone else does not.

Refunds are unaffected: they go to the project's pool whoever cancels.

## Rationale

### Why a record that funds tasks, not a new task mode?

A project has no worker, submission or mode of its own. Funding ordinary tasks keeps every mode,
hook, evaluator, settlement term and rating working on project tasks with no change, and puts all
of the new behaviour in one place: where money is drawn from and where it goes back.

### Why keep refunds inside the diamond?

Crediting the budget instead of transferring keeps the money where the next task can use it, at no
cost, and lets the rev026 liability ledger track it. A transfer to the owner followed by a new
funding would need two transactions and the owner's attention for every refund.

### Why a generic funding pool rather than crowdfunding built into projects?

Pooling money from many backers, spending it on work, and sharing out what is left is not specific
to projects: a crowdfunded single task or a funded workflow needs the same accounting. Keeping it in
one pool primitive, keyed by a module and an ID, means a later crowdfunded kind of work only opens a
pool, spends from it and refunds to it; backers fund and claim through the same `fund` and `claim`,
with the same events, so wallets, the indexer and the CLI need no new contract surface for it. It
also keeps the money rules (who may fund, when the pot forms, how it is shared, dust) in one library
with one set of tests, and puts the backers' entrypoints in their own facet, leaving room in
`ProjectFacet` under the size limit.

### Why `onBehalfOf`, and why may a caller fund directly?

A backer does not always send its own transaction. A router that swaps or bridges into the
stablecoin, a sponsor paying for a community, or another contract acting for a user has to be able
to pay and name the user whose contribution it is. Relayed calls keep the forwarder's payment check
that every gasless payment uses; direct calls pull the money with `transferFrom` from the caller, so
a contract can fund without a forwarder. Either way the contribution, and so the claim, belongs to
`onBehalfOf`.

### Why may anyone fund?

A shared goal is paid for by the people who want it. Letting any wallet back a project lets them
pool money without trusting the owner with it off chain. Spending stays with the owner and the
operators the owner grants: backing a project gives no say in how the budget is spent.

### Why do leftovers go to the backers pro rata, not to the owner?

The money that is not spent belongs to whoever paid it in. Returning everything to the owner would
make every backer's unspent money a gift to the owner, which no backer agreed to and which would
reward an owner for spending little. Pro rata to shares bought at the pool's value is the only
split that treats each unit of money paid in the same way, and it reduces to the owner taking
everything back when the owner is the only backer.

### Why a pot backers claim, not a payout to every backer on close?

The number of backers is unbounded, so paying each one at close could exceed the block gas limit
and make the pool impossible to close. Refunds also keep arriving after the close as the project's
tasks settle, each in someone else's transaction. A pull-based pot with cumulative accounting costs
one storage write per refund, lets each claim run in constant gas, lets anyone (the backend
included) claim for a backer, and keeps a backer whose transfer fails (a token blocklist, say) from
blocking the others.

### Why does the end date stop spending but not work?

A task's own deadline, review window and terms were agreed when it was funded. Cutting them short
because the project ended would break those terms for the worker.

## Upgrade

Part of the one rev027 diamond cut, `script/upgrades/Rev027Upgrade.s.sol` (see
`rev027-reservation-mode.md` for the rest of it). For projects the cut Adds `ProjectFacet` and
`FundingPoolFacet`, and Replaces `CoreFacet`, `AcceptanceFacet`, `EvaluatorFacet` and
`SettlementFacet`, which now pay a requester through `payRequester`, check task funding through
`_requireFunding` and check the requester through `_requireRequester`, and `RatingFacet` and
`WorkerFacet`, which check the requester through it. The whole cut is nine facets and 73
selectors in one transaction. `LibRevision` is 27. No initialisation: every new field reads as
zero, and no existing task belongs to a project.

## Trade-offs

- A backer buys shares at the pool's value, which counts money in live tasks at what was spent on
  them. A backer that joins while a task holds budget shares that task's outcome: if the task pays
  its worker, the value falls for every backer alike. Valuing only `available` instead would let a
  backer buy into a pool whose money sits in tasks about to be refunded and take part of the refund.
- Shares start at 10^12 per base unit, not one per unit, so share counts are large numbers; clients
  show a backer's fraction of `totalShares` rather than the raw count.
- A pool that reaches zero value gives a new backer all but one base unit of it; the old shares
  keep that dust's worth.
- A project lasts at most 365 days.
- Every payout entrypoint reads `taskPoolDraws` in `LibEscrow.release`, one storage read for a task
  in no project.

- Committed and spent are derived off chain, so a contract cannot read them.
- Up to one base unit per backer of each pool's pot stays in the diamond as rounding dust, booked
  and unclaimable.
- A pool's `available` means budget or pot depending on whether it is settled; `getPool` reports
  `settled` and `potIn` so readers need not work it out.
- A backer is not paid until someone claims for it.
- A pool only holds the task payment stablecoin, the one token the escrow ledger books.
- Pool and project budgets are booked like tasks, so an accounting fault in pool code is caught by
  the same solvency check rather than by a separate one.

## Tests

`test/Project.t.sol`: create, fund and close, with their rejections (non-allowlisted token, payment
mismatch, zero budget, past end date, not the owner, closed); anyone funding; close leaving the
unspent budget as the pot; project tasks drawing the reward and an evaluator stake; refunds to the
project on cancel, expiry and an auction's unspent remainder; refunds to the pot after the end date
and after close; a refunded budget funding the next task; the surplus sweep leaving the budget; an
ordinary task still refunding its requester; and the diamond's balance equalling its liabilities
after every step. `test/ProjectCrowdfunding.t.sol`: share pricing (a late backer after the budget was spent gets its
money back, also when the spend front-runs it and when part was spent; a late backer does not take
an earlier windfall; an inflation attack through a forfeited stake and a donation does not dilute
a later backer; `outstanding` following spends, payouts and refunds); top-ups drawn from the pool
(a reward increase and an evaluator stake, refused with a forwarded payment, when the project is
not open or over budget); the 365-day lifetime cap; claim and close refusing a relayed payment;
funding on behalf of the diamond refused; a many-backers fuzz test interleaving funding, spends,
payouts, refunds and claims; the project's pool and its ID derivation;
several backers with different amounts and their recorded contributions; funding on behalf of
someone else, relayed and directly through `transferFrom`, and without an allowance; the owner as a
backer; funding refused when closed, past `closesAt`, zero, with a payment mismatch or while paused;
every entrypoint and view refusing an unknown pool; spending over `available` refused; close early by
the owner and by anyone after the end date, with pro-rata claims across three backers; refunds after
close and after the end date landing in the pot and being claimable, interleaved with claims; a
third party's claim, direct and relayed, paying the backer; double claims, claims while open, by a
non-backer and while paused refused; the surplus sweep leaving the pot; rounding dust staying booked
and under one base unit per backer; and a fuzz test that claims never exceed the pot. Every step
checks the diamond's balance equals its liabilities. `test/ProjectGrants.t.sol`: grant, accept and
revoke with their rejections; an operator spending only after accepting, within its cap, with the
cap released by a refund; top-ups counting toward the cap, the owner's top-up of an
operator's task, and a revoked operator refused a top-up; operators refused at the owner-only functions; and who may act on an
operator's task under every `requesterOfRecord`, `ownerOverride` and `revokeRemovesControl`
setting, before and after a revoke. `test/RequesterGuard.t.sol`: every requester entrypoint refuses
a non-requester. `test/Rev027Upgrade.t.sol`: every rev027 selector routed, the pool selectors on
their own facet.

## Affected Files

- `src/interfaces/ITMPProject.sol`, `src/interfaces/ITMPFundingPool.sol`,
  `src/facets/ProjectFacet.sol`, `src/facets/FundingPoolFacet.sol`, `src/libraries/LibProject.sol`,
  `src/libraries/LibFundingPool.sol` (new)
- `src/facets/RatingFacet.sol`, `WorkerFacet.sol`
- `src/libraries/LibAppStorage.sol`, `LibGuards.sol`, `LibTaskCreation.sol`, `LibTaskMarket.sol`,
  `LibTerms.sol`, `LibRevision.sol`
- `src/facets/CoreFacet.sol`, `AcceptanceFacet.sol`, `EvaluatorFacet.sol`, `SettlementFacet.sol`
- `script/upgrades/Rev027Upgrade.s.sol`, `script/lib/FacetSelectors.sol`,
  `script/DiamondDeploy.s.sol`, `scripts/generate-abi.ts`
- `test/Project.t.sol`, `test/ProjectCrowdfunding.t.sol`, `test/ProjectGrants.t.sol`,
  `test/ProjectRequesterPayouts.t.sol`, `test/RequesterGuard.t.sol`,
  `test/DiamondSelectorParity.t.sol`, `test/Diamond.t.sol`, `test/Rev027Upgrade.t.sol`,
  `test/helpers/DiamondTestHelper.sol`
