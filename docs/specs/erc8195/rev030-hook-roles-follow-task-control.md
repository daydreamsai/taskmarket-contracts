# Rev030 -- Hook call roles follow task control, and security fixes from an external review

## Status

Implemented; not deployed on any chain. It follows rev029. Part 1 (hook call roles) changes
`HooksV2Facet`. Part 2 fixes the findings of an external security review of rev029 that were
accepted: it replaces thirteen facets (`DiamondCutFacet` included), Adds two `AdminFacet` selectors,
Removes three selectors that only V1 hook dispatch used (change 30), appends one `AppStorage` field
(`maxSubmissionWinners`), upgrades the `FundingPool` implementation,
the DREAMS reward hook (`TaskTokenRewardHookV2`) and the two Sponsored Task V2 hooks
(`SponsoredTaskHookV2`, `RemoteSponsoredTaskHookV2`) in place, ships a new `ProofGateHook`, and
refuses some hook and evaluator combinations at task creation. The Solana Sponsored Tasks program
and the `SponsoredTaskSettler` change too (changes 28 and 29); those are redeployed, not cut.

## Motivation

Rev028 gave hooks calls from task participants by role (`callTaskHook`), with the roles computed
from current state by `HooksV2Facet._roles`. Rev027 and rev029 decide who may act for a task an
operator created in a project with `LibProject.mayAct`: the operator, unless its grant was revoked
with `revokeRemovesControl`, and the project's current owner when `ownerOverride` is set or such a
revoke removed the operator's control. Every requester entrypoint follows `mayAct` through
`LibGuards._requireRequester`.

The hook roles did not. A revoke that removed an operator's control of its tasks left it holding
the hook roles on them, so through `callTaskHook` it could still steer hooks that trust those roles
after the owner had taken the task over. The payout gate (`PayoutGateHook`) is one: it accepts
`REQUESTER` and `PROJECT` callers, so a revoked operator could keep extending the gate's deadline,
which holds the owner's accept, and could spend the gate's single re-link. Rev030 makes both roles
follow `mayAct` for the creating operator and the requester of record.

## Problem 1 -- The creating operator keeps `PROJECT` after its control is removed

`_isProject` granted `PROJECT` to `taskOperators[taskId]` unconditionally:

```solidity
if (who == s.projects[projectId].owner || who == s.taskOperators[taskId]) return true;
```

After `revokeOperator` on a grant with `revokeRemovesControl`, `mayAct` refuses the operator and
hands the task to the owner, but the operator still held `PROJECT` on every task it created and
could call `PayoutGateHook.onCall` to extend or re-link the gate.

## Problem 2 -- The requester of record keeps `REQUESTER` after it may no longer act

For a task an operator created, `_roles` reported `REQUESTER` for `task.requester`, the requester of
record, whoever may act. Two holders kept a role they no longer had the authority behind:

- an operator that is the requester of record (`RequesterOfRecord.Operator`) after a revoke that
  removed its control. The payout gate accepts a `REQUESTER` caller that is `ctx.requester`, so the
  fix to Problem 1 alone would have left this path open;
- the previous owner, after an owner transfer (rev029), when it was the requester of record of an
  operator's task (`RequesterOfRecord.Owner`). `mayAct` tests the current owner, so the previous one
  may not act, yet it kept `REQUESTER`.

## Changes

### 1. `_isProject`: the creating operator holds `PROJECT` only while it may act

Before:

```solidity
if (who == s.projects[projectId].owner || who == s.taskOperators[taskId]) return true;
```

After:

```solidity
if (who == s.projects[projectId].owner) return true;
if (who == s.taskOperators[taskId]) return LibProject.mayAct(s, taskId, who);
```

The owner is tested first, as in `mayAct`, so after a transfer to the operator that created a task
the new owner keeps `PROJECT` on it. A revoke without `revokeRemovesControl` leaves the operator in
control of what it started, and with it the role. An operator granted again after a revoke (rev029)
follows `mayAct` too. Any other operator still needs an accepted, unrevoked grant.

### 2. `_roles`: the requester of record holds `REQUESTER` only while it may act

Before:

```solidity
bool isRequester = who == t.requester;
if (projectId != 0 && s.taskOperators[taskId] == address(0)) {
    isRequester = who == s.projects[projectId].owner;
}
```

After:

```solidity
bool isRequester = who == t.requester;
if (projectId != 0) {
    if (s.taskOperators[taskId] == address(0)) isRequester = who == s.projects[projectId].owner;
    else if (isRequester) isRequester = LibProject.mayAct(s, taskId, who);
}
```

A task outside a project and a project owner's own task are unchanged. On an operator's task the
role only narrows: it is never given to an address that is not the requester of record, so a hook
that compares the caller with `ctx.requester` sees the same address as before, or none.

| Holder on an operator's task                         | `REQUESTER` before | after                     | `PROJECT` before | after |
| ---------------------------------------------------- | ------------------ | ------------------------- | ---------------- | ----- |
| Operator, grant live                                 | if of record       | if of record              | yes              | yes   |
| Operator, revoked, `revokeRemovesControl`            | if of record       | no                        | yes              | no    |
| Operator, revoked, control kept                      | if of record       | if of record              | yes              | yes   |
| Current owner                                        | if of record       | if of record and `mayAct` | yes              | yes   |
| Previous owner after a transfer, requester of record | yes                | no                        | no               | no    |

## Part 2 -- Security fixes

Each fix below names the problem, what changed and the rule that now holds.

### 3. A changed hook opens `releaseClaim`

**Problem.** Rev028 let `releaseClaim` ignore `ReleaseAllowed.Disallowed` when a hook on the task can
veto `submitWork`, so a worker who cannot deliver can leave. `_canVetoSubmit` decided this from the
declared capability bits only (V2 hooks declaring bit 9; V1 hooks counted too before change 30). But `submitWork` also runs
the observer callback (bit 25) as part of a vetoable action, and that callback reverts
`HookCodeChanged` when the hook's live codehash differs from the one pinned at attach. A requester
who attached an EIP-7702 delegated account declaring only the observer bit could re-delegate it
after the claim: delivery reverted, `releaseClaim` still reverted `ReleaseNotAllowed`, and at
expiry the stake went to the requester.

**Change.** A V2 hook whose runtime codehash no longer matches the one pinned at attach also counts
as able to veto, whatever bits it declares. The worker can always hand the claim back under the
normal release-penalty schedule, and the changed hook stays blocked from every vetoable callback.

### 4. EIP-7702 delegated accounts are not hooks

Hook attach, at task creation and in `setDefaultHooksV2`, refuses an address whose code is the
23-byte EIP-7702 delegation designator (`0xef0100` followed by an address), reverting
`HookDelegatedAccount(index)`. Its key holder can re-point the delegation at any time, which defeats
the codehash pin taken at attach. Change 3 remains the backstop for any other way a hook's code
could change.

### 5. A Claim stake follows the evaluator's verdict

**Problem.** `finalizeVerdict` settled the Claim stake from the awards after the transforming hook's
result. A requester's transforming hook that zeroed an award the evaluator approved therefore
forfeited the worker's stake to the requester, while `acceptSubmission` with the same hook result
returns the stake.

**Change.** When an evaluator's verdict is finalized or a resolver rules, the Claim worker's stake
goes back to the worker if the evaluator's or resolver's own awards contain any nonzero amount, and
is forfeited otherwise, as before. A transforming hook can still replace the awards and take its
fee, and an unawarded reward still goes back to the requester. Its result no longer decides the
stake.

### 6. A task with a transforming hook keeps a neutral appeal

Transforming hooks keep their rev028 powers, which exist so that workflows can adjust a payout. So
that a worker can always contest an adjustment before a neutral party:

- task creation (`createTask` and `createProjectTask`, protocol default hooks included) refuses a
  task that has a transforming hook together with any hook declaring the beforeAppeal capability
  (bit 12), reverting `TransformingHookWithAppealHook`;
- an evaluator on such a task must name a dispute resolver: at creation and in `assignEvaluator`, an
  evaluator config with no dispute resolver reverts `TransformingHookNeedsDisputeResolver`.

### 7. Forfeited stakes do not hide a project task's pool money

**Problem.** `LibProject.refund` took every refund to a project's pool off the task's draw and the
pool's `outstanding`, including a forfeited worker stake that was never pool money. When a Claim task
reopened after forfeits with its reward still in escrow, `outstanding` read low. Once the owner spent
the recovered stakes, the pool could value itself at nothing while a live task held the backers'
money, and a 1-unit funding then started a new share generation that took that money when it came
back.

**Change.** A project task's draw is the pool money it holds. A refund lowers the draw and the
pool's `outstanding` only by pool money the task no longer holds: at most the draw less what the task
still holds of its reward and evaluator stake, read after the payout's state change. A forfeited
stake on a reopened task only adds to the pool's `available`. Money that does leave the task still
leaves `outstanding` in the same call, so hooks never see a refund counted twice (the rev028 rule).
As a second safeguard, the funding pool never starts a new share generation while anything is
outstanding. The funding pool implementation reports revision 30 and is upgraded in place through
its UUPS proxy by the diamond's owner; it adds no storage.

The same cap decides what the operator gets back. `refund` credits the operator's grant `committed`
and its period meter with `applied`, the amount the task drew from the project and no longer holds,
not the full refund. A forfeited worker stake on a reopened Claim task, or a refunded evaluator
stake, still goes to the project's pool as available money, but it was never counted against the
operator, so it no longer gives the operator's cap or period budget room to spend it again. Every
other refund of project money credits the operator as before, and a task that ends after a forfeit
and reopen releases the operator's whole remaining commitment once. Tasks with no operator are
unchanged.

### 8. The evaluation window has a ceiling

**Problem.** An evaluator's `evaluationWindow` had a floor but no ceiling, so a requester could set
up to about 136 years, and `evaluatorTimeout` would never open on a delivered task.

**Change.** `evaluationWindow` is held to the same ceiling as `appealWindow`, the effective
`termsBounds.maxWindowSecs` (30 days by default). `createTask`, `createProjectTask` and
`assignEvaluator` refuse a longer one with `EvaluationWindowTooLong(window, max)`. `setTermsBounds`
now refuses a `maxWindowSecs` below the effective `minEvaluationWindowSecs` (`InvalidTermsBounds`),
matching `setMinEvaluationWindowSecs`, which refuses a floor above the ceiling. Evaluators assigned
earlier keep their windows.

On a project task, the evaluation deadline `submitWork` sets (including on a revision resubmission)
is `min(now + evaluationWindow, endsAt + taskGraceSecs)`, the same latest expiry `extendExpiry`
already holds the task's expiry to, so `evaluatorTimeout` opens no later than that.

### 9. Evaluator timeout on Bounty and Benchmark

**Problem.** Rev027 says a Bounty or Benchmark with an evaluator exits through the evaluator's
verdict and `evaluatorTimeout` (rev027-reservation-mode, the `requesterTimeout` section). It could
not: `evaluatorTimeout` required `Review`, which these modes never enter, `requesterTimeout` refused
any task with an evaluator, and `refundExpired` and `cancelTask` revert while submissions are live.
Such a task had no exit once the evaluator stopped acting, and the evaluator had no deadline. This
section corrects the rev027 text.

**Change.** Each role has its own window and its own timeout:

- The evaluator's deadline is `max(expiryTime, decisionStartAt) + evaluationWindow`. `evaluate`
  reverts `EvaluationWindowClosed` strictly after it.
- Once it has passed, with live submissions, anyone may call `evaluatorTimeout` on the task while it
  is `Open` or `PendingApproval`. It forfeits the evaluator's stake to the fee recipient, emits
  `EvaluatorTimedOut`, clears the evaluator, moves the task to `PendingApproval` and sets
  `decisionStartAt` to the time of the call. At or before the deadline it reverts
  `EvaluationWindowNotExpired`; with no live submissions, `NoActiveSubmissions`.
- With the evaluator gone, the rule for a task without one applies: the requester may accept or
  reject until `decisionStartAt + decisionWindowSecs` (its settlement-terms decision window), and
  after that `requesterTimeout` refunds the requester and records `requester_timeout` against it.

`decisionStartAt`, which before rev030 was set only by the rev025 normalization, is now also set by
this timeout. Claim, Pitch and Auction timeouts are unchanged. On a project task the evaluation and
decision windows run past the task's expiry, so backers' money can be held at most until
`endsAt + taskGraceSecs + evaluationWindow + decisionWindowSecs` (each window at most the terms
ceiling), after which the refund goes to the project.

### 10. A per-chain winner cap, and award ranks

**Problem.** The 50-winner cap was sized on Base, where a new storage slot costs about 20k gas.
Tempo charges about 250k per new slot and caps a transaction at 30M. A verdict storing 37 to 50
rank-0 awards to recipients with no balance wrote two new slots per award, but paying it writes
three per fresh winner (about 40M gas), so it could be stored and never settled in one transaction.

**Change.**

- The most winners one Bounty or Benchmark settlement may pay is set per chain:
  `AppStorage.maxSubmissionWinners` (appended, `uint16`), set by the owner through
  `AdminFacet.setMaxSubmissionWinners(uint16)` (1 to 50, `InvalidMaxSubmissionWinners` otherwise,
  emits `MaxSubmissionWinnersUpdated`) and read through `maxSubmissionWinners()`. It reads as
  `MAX_SUBMISSION_WINNERS` (50) until set. `evaluate` and `resolveDispute` on Bounty and Benchmark
  tasks, and `acceptSubmissions`, revert `TooManyWinners` above it. `Rev030Upgrade` sets 30 on Tempo;
  Base keeps 50. A verdict already stored keeps its awards.
- A nonzero award on a Bounty or Benchmark verdict must have `rank >= 1`, otherwise
  `InvalidAwardRank`. Zero-amount awards stay inert and are not checked. Claim, Pitch and Auction
  awards are unchanged.

### 11. The DREAMS bonus follows the settled award

**Problem.** On Base the DREAMS reward hook `TaskTokenRewardHookV2` is a protocol default V2 hook,
attached first. It paid the completion bonus in `beforeAccept`, sized from the core verdict, so a
transforming hook that cut the award still received the full bonus from the reward vault.

**Change.** The hook pays the bonus in `afterComplete` from the awards the diamond settled: the
stored verdict, the core awards it kept in transient storage during `beforeAccept` for an accept no
hook changed, or the single-payee award. `beforeAccept` still refuses a task whose bonus is paid.
When a transforming hook replaces the awards on `acceptSubmission` or `acceptSubmissions`,
`AcceptanceFacet` records them as the task's verdict, as `EvaluatorFacet` already does on the
evaluator path, so `getTaskVerdict` reports the awards paid. A task without a transforming hook earns
the same bonus as before. A completion whose `afterComplete` is skipped or fails keeps its
reservation until `recoverReserve` pays it from the recorded awards. The hook is upgraded in place
through its UUPS proxy (`DeployHooksV2.s.sol:UpgradeRewardHookV2`, which requires the diamond at
rev030); its proxy codehash, storage and capabilities do not change.

### 12. Corrections to earlier revision documents

Merged revision documents are append-only, so rev025, rev026 and rev028 carry dated "Correction
(rev030)" notes: the Tempo gas and relay-ceiling figures for the winner cap (rev025, rev026), and
that the DREAMS reward hook is a protocol default on Base (rev028).

### 13. Sponsored Task tokens follow the settled awards

**Problem.** `SponsoredTaskHookV2` and `RemoteSponsoredTaskHookV2` committed the verdict type, the
awards digest, the award count and the native payout pool in `beforeAccept`, from the core verdict
every hook is shown before a transforming hook's result is applied. When a transforming hook
replaced the awards, sponsor tokens followed the replaced awards: a worker cut to zero still had an
entitlement, a raised or added worker had none or too little, and a PARTIAL verdict scaled from the
core total. Because the diamond stores the awards it paid as the task's verdict (`EvaluatorFacet`
since rev028, `AcceptanceFacet` since change 11), `reconcile` and `finalizeSettlement`, which read
that verdict, then reverted `VerdictCommitmentMismatch` for good, and the Base-local reservation and
the remote commitment were never settled.

**Change.** The settled-awards lookup of change 11 is now a shared library,
`hooks/base/LibSettledAwards.sol`, that any V2 hook sizing from the awards uses: the stored verdict,
then the core awards the hook kept in transient storage during `beforeAccept`, then the single-payee
award. `TaskTokenRewardHookV2` uses it with its existing slot base, so its behaviour and storage do
not change. The two sponsored hooks still commit in `beforeAccept`, because their commitment must
survive a skipped or failed `afterComplete` (the diamond swallows an after-callback's failure), but
the commitment is provisional: it plays the part of the transient copy, kept in storage. When the
diamond holds a stored verdict, `afterComplete` recommits from it, keeping the native payout pool,
which depends only on the task's terms; `reconcile` and `finalizeSettlement` do the same before they
check the supplied or stored awards, so a permissionless `finalizeSettlement` racing a missed
`afterComplete` can only settle the awards that were paid. An accept no hook changed stores no
verdict (a fee-only result, bit 27, included), so its commitment stands and settlement is unchanged.
`afterComplete` never reverts on the award count: paid awards above `MAX_AWARDS` release the
Base-local reservation (`AwardCountExceeded`), as an oversized core verdict does in `beforeAccept`;
the remote hook marks the commitment unsettleable. Core awards above `MAX_AWARDS` still release in
`beforeAccept`, and a transform that brings them under the bound does not reopen the sponsorship.
Every other status (settled, released, defaulted by the owner) is left alone. A recommit costs one
`getTaskVerdict` read, the digest and three storage updates, less than the commitment
`afterComplete` already makes for an uncommitted completion. Dispute rulings and settlements after
expiry apply no transforming result, so their stored verdict is the core verdict and nothing
changes. Both hooks are upgraded in place through their UUPS proxies
(`DeployHooksV2.s.sol:UpgradeSponsoredTaskHookV2` and `UpgradeRemoteSponsoredTaskHookV2`, which
require the diamond at rev030); the proxy codehash that task attachments pin, the storage layout,
the capabilities and the ABI do not change.

Known limit, accepted: on `acceptSubmission` and `acceptSubmissions` the task is already `Accepted`
when hooks run, so the requester's own transforming hook could call `finalizeSettlement` during its
`beforeAccept` and settle the sponsorship from the core awards before its own result is applied. Only
requester-chosen code runs at that point and no third party gains, so no guard is added; an
`isSettling()` check would close it at a cost the sponsored hook's size margin does not allow.

### 14. Observers never block an action

An observer callback (capability bit 25) never blocks the action it watches because of gas. When
its budget is not available it is skipped, `HookCallFailedV2` is emitted with the gas failure class
and its sequence number is spent. Before this, several observer hooks on Tempo, where gas is dear,
could make `submitWork` impossible while `releaseClaim` stayed `Disallowed`.

### 15. Forced exits share a gas cap

The best-effort callbacks of one forced exit (a dispute ruling, a finalize after expiry, a lapsed
review and a multi-winner settlement) share `MAX_EXIT_HOOK_GAS` (6M) per dispatch step. The first
callback always runs; later ones that would pass the cap are skipped and reported, and the gas for
that bookkeeping is reserved (`SKIP_RESERVE`). V1 hooks no longer take part in a forced exit at all
(change 30), so the V1 expiry loop and the V1 dispute reserve (`DISPUTE_SETTLEMENT_RESERVE`) that this
change first added for them are gone.

### 16. Project task creation shows the project to its hooks

`beforeCreate` sees `ctx.projectId`, and the create observer fires for project tasks as it does for
ordinary ones.

### 17. Hook limits

`maxHooks` cannot be set below the length of the V2 default hook list, and the V2 default list
cannot be longer than `maxHooks`. (Until change 30 the V1 default list was checked too.)

### 18. Reserved acceptance keeps the delivery period

On a project task, accepting a reservation reverts `ReservedDeliveryPeriodShortened` when the
project's latest expiry would cut the restarted delivery period short.

### 19. The dispute window is not clamped by a project

`appeal` records now plus the resolution window in `phaseDeadline`, unclamped. `refundExpired` on a
`Disputed` task past its expiry reverts `DisputeWindowStillOpen` until `phaseDeadline` has passed,
so a project task's clamped expiry cannot end the resolver's window early.

### 20. The evaluator decides

`rejectSubmission` reverts `EvaluatorDecides` while an evaluator is assigned. The Bounty and
Benchmark evaluator timeout (change 9) clears the evaluator, after which the requester may reject
again.

### 21. Acting parties are checked at use time

`evaluate`, `resolveDispute` and `appeal` refuse a caller who became an acting party after the
assignment, for example through a project ownership transfer. A caller who is the project owner
draws for the operator-created tasks it owns without operator-grant checks. A worker mid-claim who
becomes an acting party may `releaseClaim` with no penalty, whatever `ReleaseAllowed` says.

### 22. Hook-transformed awards

The `SelfAward` event and the requester reputation flag follow the awards actually paid. The winner
cap (change 10) applies to every mode in `evaluate` and `resolveDispute`.

### 23. `DiamondCutFacet` is replaced

The rev030 cut also replaces `DiamondCutFacet`, so the rev028 init-calldata guard
(`InitCalldataWithoutInit`) becomes live on upgraded diamonds.

### 24. Sponsored hooks freeze their terms

`SponsoredTaskHookV2` and `RemoteSponsoredTaskHookV2` declare `beforeAssignEvaluator` and
`beforeUpdate` and refuse both while a sponsorship is active (`SponsorshipTermsFrozen` on the
Base-local hook, `CommitmentTermsFrozen(bytes32)` on the remote one), because the funded terms hash
binds the evaluator and the reward. The diamond snapshots a hook's capabilities at attach, so the
freeze covers tasks created after the hook upgrade.

A remote commitment is keyed by vault, nonce and the manager that created the task, so another task
creator cannot use up a vault's nonce first. `taskByCommitment` takes four arguments
(`remoteChainId`, `vault`, `commitmentNonce`, `manager`); the three-argument form reads commitments
recorded before rev030, whose nonces stay used. `reconcile` rebuilds the single award for an
accepted Claim or Pitch with no stored verdict, in the V2 and V1 hooks.

### 25. DREAMS reward hook

- An `afterForfeit` while the worker is still on the task (an evaluator timeout on a delivered task)
  keeps the bonus reservation.
- `seedWalletHistory` applies bans to wallets never seen and to existing ones, and refuses a future
  `firstSeenAt` (`FutureFirstSeen`); the age ramp clamps.
- `seedRewardStates` pins the vault and the budget a seeded reservation was made on.
- `initialize` checks that the vault pays the hook's token.

On Base the owner then seals both seed functions.

### 26. `ProofGateHook` checks live roles

`ProofGateHook.allow()` checks the caller's live requester or project role through the diamond
(`taskCallerRoles`). It is a new deployment, so only tasks created against it benefit.

### 27. Scripts and tooling

- The Sponsored Task V2 hook deploy and upgrade scripts require the diamond at rev030 and with code.
- `SwapRewardHook` refuses a diamond at rev028 or later.
- `DeployRewardHookV2` hands the hook, vault and budget ownership to an admin contract
  (`FORGE_REWARD_HOOK_V2_ADMIN`).
- The `FacetSelectors` registry lists are fixed (no zero selector), with a test over every list.
- `storage-check` verifies that `AppStorage` is append-only against a committed snapshot
  (`appstorage-layout.snapshot.json`).

### 28. `SponsoredTaskSettler`

Raising the claim delay cancels a pending reduction. This takes a redeploy of the settler, which is
not live on mainnet.

### 29. Solana Sponsored Tasks program

A fresh deploy is required: accounts created before 2026-11-05 cannot be read by the new program.

- Payout binding signatures name the cluster (`Config.cluster_id`; the EIP-712 salt is
  `keccak256(programId || cluster_id)`) and expire at a signed `deadline` (`u64::MAX` for none).
- A payout nonce of `u64::MAX` is refused.
- A payout binding change attested by the settler takes effect only after the claim delay
  (`pending_payout`, `pending_effective_at`, `PayoutBindingPending` event).
- `revoke_settlement` refuses a recycled manager.
- `init_config` refuses a zero admin or a zero cluster id.
- After a reservation's deadline anyone can release it (`release_expired`).
- The default claim delay is 24 hours.
- `claim_fee` is refused while the program is paused, so a fee claim cannot end the
  pause-then-revoke containment of a wrong root.
- A mint with a close authority (Token-2022 `MintCloseAuthority`) is refused at `create_vault`
  with the other rejected extensions: such a mint could be closed at zero supply and recreated at
  the same address with extensions the vault never checked.
- Off chain, the Solana settler refuses to queue or sign a settlement whose leaf amounts, leaf
  count, settled total, fee total and distributed gross disagree, since `settle` trusts the
  posted totals.

### 30. Legacy V1 hooks are retired

**Problem.** Rev028 made every new task a Task Hook V2 task but kept V1 dispatch alive for tasks
created before the cut, so `HookDispatchFacet`, `LibHooks`, the owner's default hook list and every
facet that settles a task carried a second, parallel hook implementation. It made `HookDispatchFacet`
the facet over the EIP-170 limit under Solar and cost every facet bytecode it did not need. Two
rev030 gas guards (the V1 expiry best-effort loop and the V1 dispute `checkComplete` loop) existed
only to keep V1 hooks from blocking a forced exit.

**Change.** V1 hook dispatch is removed. No code path calls a V1 hook any more.

- *Dispatch.* `LibHooks` and `HookDispatchFacet` lose the V1 attach (`_attachV1`, including the path
  a diamond below rev028 took), the V1 `check*` calls for claim, worker selection, auction
  acceptance, submit and evaluate, `checkComplete` (including its Disputed-state variant), and the V1
  `onComplete`, `onCancel`, `onExpire` and `onForfeit` calls with their gas helpers. The settlement
  record still runs for every task.
- *A pre-cut task is a task with no hooks.* A task with `getTaskHookVersion` 0 has no V2
  attachments, so every callback is skipped for it. Its V1 hook list stays in `AppStorage.taskHooks`,
  which nothing reads. It creates no more hook calls than a task created with an empty list: it can
  still be claimed, delivered, accepted, evaluated, appealed, resolved, cancelled, released, rejected,
  forfeited and refunded at expiry, and a lapsed review or an evaluator timeout still settles. The
  settlement record is written when it ends, as before. `getTaskHooks` returns an empty list for it
  (it reads V2 attachments only); `getTaskHooksV2` is empty and `getTaskHookVersion` stays 0.
- *`_canVetoSubmit`.* `releaseClaim` no longer counts a V1 list as a hook that can veto `submitWork`,
  so a pre-cut Claim task follows the plain release rules.
- *Default hooks.* `setDefaultHooks` and `getDefaultHooks` are removed. `setTaskLimits` compares
  `maxHooks` to the V2 default list only. `setDefaultHooksV2` is unchanged. The V1 default list a
  diamond still holds in `AppStorage.defaultHooks` is dead data.
- *Contracts.* `TaskTokenRewardHook`, `SponsoredTaskHook`, `RemoteSponsoredTaskHook`, the V1
  `BaseTMPHook` and the three reference hooks built on it are deleted from the sources, with their
  tests and the deploy and upgrade scripts only they used (`DeployRewardHook`,
  `DeployRewardHookTestnet`, `SwapRewardHook`, `UpgradeRewardHook`, `UpgradeSponsoredTask`,
  `DeployRemoteSponsoredTaskHook` and the two proxy helpers). Hooks already deployed from them stay on
  chain and keep their own state; the diamond no longer calls them. `DeploySponsoredTask` now deploys
  the shared registry and fee policy only. The `ITMPHook` interface stays so the diamond can still
  recognise a V1 hook by its ERC-165 id and refuse it with `HookV1Retired`.
- *Removed selectors.* Three selectors leave the diamond, in the same cut: `setDefaultHooks(address[])`
  (`0x435f2c47`) and `getDefaultHooks()` (`0xe98650f3`) on `AdminFacet`, and the internal
  `hookCheckCompleteV1(bytes32,(bool,uint8,uint16,uint16,bytes32[],bytes32,(address,uint256,uint16)[]),bool)`
  (`0x9685ec9c`) on `HookDispatchFacet`. `getTaskHooks`, `getTaskHookVersion`, `getTaskContext` and
  every other selector stay.
- *Storage.* `AppStorage` is append-only, so `defaultHooks` and `taskHooks` stay in place, unused.
  `taskHookVersion`, `taskHooksV2` and `defaultHooksV2` are unchanged.
- *Unused declarations.* The V1 errors `HookCheck*Rejected` and `InsufficientGasForHook` and the
  events `HookRegistered`, `HookCallFailed` and `DefaultHooksSet` stay declared in `ITMPCore`, because logs and transactions
  from before rev030 carry them. No facet emits or raises them any more, so they leave the diamond's
  generated ABI; `abi/retired/TaskMarketV1Hooks.json` keeps their definitions in the `TaskMarket`
  union. `LibHooksV2.DISPUTE_SETTLEMENT_RESERVE` is deleted.

**What live V1 tasks experience.** Production had no live V1-hook tasks on Tempo. On Base there are
eight test tasks on the V1 `TaskTokenRewardHook`, each with a 0.01 USDC claim. After the cut their V1
hook is not called: the DREAMS bonus reservation on them is neither booked nor released by the
diamond, and the hook's own `RewardVault` and `EpochBudget` state stays as it is. The product owner
accepted this on 2026-11-11. The tasks themselves settle, cancel and expire as any task does,
because hooks never hold escrow.

## Rationale

### Why not only change `_isProject`?

With `RequesterOfRecord.Operator` the operator is `task.requester`, and the payout gate accepts a
`REQUESTER` caller that is `ctx.requester`. Removing `PROJECT` alone would have left the same
extension and re-link open through the requester path.

### Why not report `REQUESTER` for every address `mayAct` accepts?

That would also give the role to a current owner that is not the requester of record (with
`ownerOverride`, or after a removing revoke). Such an owner already holds `PROJECT`, which is the
role hooks use for the project's side, and a hook that compares the caller with `ctx.requester`
would refuse it anyway. Narrowing only takes the role from holders that lost the authority behind
it and adds it to no one, so no hook gains a caller it did not have.

### Why not change `LibProject.mayAct` or the payout gate?

`mayAct` is already the rule every requester entrypoint follows; the roles were what disagreed
with it. The gate trusts the roles the diamond reports, as every V2 hook does, so fixing the roles
fixes it and any other hook that accepts these roles, with no hook redeployed.

### Why a new revision rather than a patch to rev029?

Rev029 is cut on Base Sepolia, Tempo Moderato, Base and Tempo. The fix needs new `HooksV2Facet`
bytecode on those diamonds, which takes a cut and a version bump.

## API Changes

Part 1: no signature, event or error changes. `taskCallerRoles(taskId, who)` and the `roles` passed
to `onCall` and emitted in `TaskHookCalled` change as in the table above: an operator whose revoke
removed its control holds `STRANGER` alone on the tasks it created (unless it is also their worker,
submitter or evaluator), and a requester of record that may no longer act loses `REQUESTER`.
`callTaskHook` refuses such a caller with `HookCallRoleRefused` for a hook that accepts only those
roles.

Part 2:

- Removed functions: `setDefaultHooks(address[])` and `getDefaultHooks()` (`AdminFacet`) and the
  internal `hookCheckCompleteV1` (`HookDispatchFacet`) (change 30). `getTaskHooks` now returns V2
  attachments only: empty for a task created before the rev028 cut.

- New functions (`AdminFacet`): `setMaxSubmissionWinners(uint16)` (owner only) and
  `maxSubmissionWinners() returns (uint256)`.
- New event: `MaxSubmissionWinnersUpdated(uint16)`.
- New errors: `HookDelegatedAccount(uint8)`, `TransformingHookWithAppealHook()`,
  `TransformingHookNeedsDisputeResolver()`, `EvaluationWindowTooLong(uint32, uint32)`,
  `InvalidAwardRank()`, `InvalidMaxSubmissionWinners()`.
- Changed behaviour: `evaluatorTimeout` accepts Bounty and Benchmark tasks with an evaluator (change
  9); `evaluate` refuses a Bounty or Benchmark verdict after the evaluator's deadline; `getTaskVerdict`
  reports a transforming hook's applied awards after a direct accept (change 11); the sponsored
  hooks' committed digest and settlement root follow those awards (change 13);
  `fundingPoolRevision()` returns 30; `rejectSubmission` reverts while an evaluator is assigned
  (change 20); `refundExpired` waits for the dispute window (change 19).
- New errors (core): `ReservedDeliveryPeriodShortened()`, `DisputeWindowStillOpen()`,
  `EvaluatorDecides()`.
- New errors (hooks): `SponsorshipTermsFrozen()` (`SponsoredTaskHookV2`),
  `CommitmentTermsFrozen(bytes32)` (`RemoteSponsoredTaskHookV2`), `FutureFirstSeen()`
  (`TaskTokenRewardHookV2`).
- Changed signature: `RemoteSponsoredTaskHookV2.taskByCommitment(remoteChainId, vault,
commitmentNonce, manager)` takes the creating manager; the three-argument form stays for
  commitments recorded before rev030.
- New internal constants (`LibHooksV2`): `MAX_EXIT_HOOK_GAS` (6M) and `SKIP_RESERVE`.

## Upgrade

`Rev030Upgrade` requires a diamond at revision 29 (at 30 it only skips). Paused across the run, it:

1. upgrades the `FundingPool` proxy to the rev030 implementation, unless it already reports 30;
2. in one cut of 15 entries, replaces `AcceptanceFacet`, `AdminFacet`, `AuctionFacet`, `CoreFacet`,
   `DiamondCutFacet`, `EvaluatorFacet`, `HookDispatchFacet`, `HooksV2Facet`, `ProjectFacet`,
   `RatingFacet`, `RegistryFacet`, `SettlementFacet` and `WorkerFacet` (every facet whose bytecode
   differs from rev029) with the selectors a rev029 diamond routes to each that rev030 keeps, Adds
   `maxSubmissionWinners` and `setMaxSubmissionWinners`, and Removes `setDefaultHooks`,
   `getDefaultHooks` and `hookCheckCompleteV1`, unless the cut already landed;
3. on Tempo (4217, 42431) sets the winner cap to 30;
4. sets the version to 30 and unpauses (`FORGE_KEEP_PAUSED=true` leaves it paused).

A fresh deploy stamps 30 (`LibRevision.CURRENT_REVISION`).

```sh
DRY_RUN=1 make upgrade <84532|42431|8453|4217> rev030
make upgrade <84532|42431|8453|4217> rev030
```

On Base (8453, and 84532 where it is a default) the DREAMS reward hook is then upgraded in place,
after the cut: `DeployHooksV2.s.sol:UpgradeRewardHookV2` with `FORGE_REWARD_HOOK_V2_ADDRESS` set to
the proxy. It refuses a diamond below 30, and when the key does not own the hook it deploys the
implementation and prints the `upgradeToAndCall` calldata for the owner.

Wherever they are deployed, the Sponsored Task V2 hooks are upgraded the same way after the cut:
`DeployHooksV2.s.sol:UpgradeSponsoredTaskHookV2` with `FORGE_SPONSORED_TASK_HOOK_V2_ADDRESS`, and
`UpgradeRemoteSponsoredTaskHookV2` with `FORGE_SPONSORED_TASK_REMOTE_HOOK_V2_ADDRESS`. The Base-local
implementation is built with the `diamond`, `usdc` and `registry` the live proxy reports.

The rest of the rollout, in order, once the cut has landed:

1. Upgrade the DREAMS reward hook (`UpgradeRewardHookV2`) and the two Sponsored Task V2 hooks, as
   above.
2. Deploy a new `ProofGateHook` (`DeployProofGateHook.s.sol`) and point new tasks at it; tasks
   created against the old one keep its role check (change 26).
3. On Base, the owner seals both DREAMS hook seed functions once the seed data is loaded (change 25).
4. Redeploy `SponsoredTaskSettler` where it is live (change 28).
5. Deploy the Solana Sponsored Tasks program fresh, with its cluster id, when that goes live
   (change 29); accounts of the old program are not carried over.

## Affected Files

| File (under `packages/contracts/`)                             | Change                                                            |
| -------------------------------------------------------------- | ----------------------------------------------------------------- |
| `evm/src/facets/HooksV2Facet.sol`                              | `_isProject` and `_roles` follow `LibProject.mayAct` (1, 2)       |
| `evm/src/facets/SettlementFacet.sol`                           | `_canVetoSubmit` counts a changed codehash (3)                    |
| `evm/src/facets/HookDispatchFacet.sol`                         | 7702 refusal (4), neutral-appeal rule at attach (6)               |
| `evm/src/facets/EvaluatorFacet.sol`                            | Stake from the verdict (5), timeout (9), winner cap and rank (10) |
| `evm/src/facets/AcceptanceFacet.sol`                           | Records applied awards (11), winner cap (10)                      |
| `evm/src/facets/AdminFacet.sol`                                | Winner-cap setter and view (10), terms-bounds check (8)           |
| `evm/src/facets/WorkerFacet.sol`                               | Project-bounded evaluation deadline (8)                           |
| `evm/src/libraries/LibTaskMarket.sol`                          | Evaluation window ceiling (8), resolver rule (6)                  |
| `evm/src/libraries/LibProject.sol`                             | Refund cap (7), `boundDeadline` (8)                               |
| `evm/src/libraries/LibAppStorage.sol`                          | `maxSubmissionWinners` appended (10)                              |
| `evm/src/libraries/LibRevision.sol`                            | `CURRENT_REVISION` 30                                             |
| `evm/src/FundingPool.sol`                                      | No new generation while outstanding; revision 30 (7)              |
| `evm/src/hooks/TaskTokenRewardHookV2.sol`                      | Bonus paid in `afterComplete` from settled awards (11, 13)        |
| `evm/src/hooks/base/LibSettledAwards.sol`                      | Shared settled-awards lookup (13)                                 |
| `evm/src/hooks/sponsored-task/SponsoredTaskHookV2.sol`         | Recommit from the stored verdict (13)                             |
| `evm/src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol`   | Recommit from the stored verdict (13)                             |
| `evm/src/facets/DiamondCutFacet.sol`                           | Replaced so the init-calldata guard is live (23)                  |
| `evm/src/libraries/LibHooksV2.sol`, `LibHooks.sol`             | Exit gas cap and reserves (15), observer gas skip (14), V1 dispatch removed (30) |
| `evm/src/hooks/proof-gate/ProofGateHook.sol`                   | Live caller roles through the diamond (26)                        |
| `evm/src/hooks/sponsored-task/SponsoredTaskSettler.sol`        | Raising the claim delay cancels a pending reduction (28)          |
| `evm/script/DeployHooksV2.s.sol`, `SwapRewardHook.s.sol`       | Rev030 preconditions, reward hook admin handoff (27)              |
| `evm/appstorage-layout.snapshot.json`                          | Committed `AppStorage` layout for the append-only check (27)      |
| `solana/programs/sponsored-tasks/src/*`                        | Cluster-bound, expiring payout bindings; pending change (29)      |
| `evm/src/interfaces/*`                                         | New errors, event and functions                                   |
| `evm/script/upgrades/Rev030Upgrade.s.sol`                      | The cut, pool upgrade and Tempo winner cap                        |
| `evm/script/DeployHooksV2.s.sol`                               | `UpgradeRewardHookV2`, the sponsored hook upgrades (13)           |
| `evm/script/lib/FacetSelectors.sol`                            | rev030 AdminFacet selector sets, the three Removed selectors (30) |
| `evm/src/facets/*.sol`, `evm/src/interfaces/*.sol`             | V1 dispatch and default hooks removed (30)                        |
| `evm/src/hooks/` V1 hooks, `evm/script/` V1 deploy scripts     | Deleted (30)                                                      |
| `evm/abi/retired/TaskMarketV1Hooks.json`, `evm/scripts/generate-abi.ts` | V1 events and errors kept in the generated ABI (30)     |
| `evm/test/Rev030*.t.sol`, `evm/test/*.t.sol`                   | Tests for every change; upgrade and full-sequence parity          |
| `docs/specs/erc8195/rev025-*.md`, `rev026-*.md`, `rev028-*.md` | Dated correction notes (12)                                       |
