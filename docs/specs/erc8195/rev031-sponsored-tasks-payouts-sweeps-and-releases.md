# Rev031 -- Sponsored Tasks: payout bindings, exited vaults, the award count, two release gaps, a reserve deadline and per-chain manager allowances

## Status

Implemented; not deployed on any chain. It follows rev030. Changes 1 to 12 live in the Sponsored
Tasks contracts around the diamond; changes 13 to 41 fix findings from two further reviews (Cyclops
and Cantina), most of them in the diamond. `Rev031Upgrade` replaces the eleven facets whose code
changed (`AcceptanceFacet`, `AdminFacet`, `AuctionFacet`, `CoreFacet`, `EvaluatorFacet`,
`HookDispatchFacet`, `HooksV2Facet`, `ProjectFacet`, `RatingFacet`, `SettlementFacet`,
`WorkerFacet`), swaps `grantOperator` for the form that takes limits (change 26), removes the zero
selector on a chain that routes it, and moves the version from 30 to 31. `AppStorage` is unchanged.
The two Sponsored Task V2 hooks (`SponsoredTaskHookV2`, `RemoteSponsoredTaskHookV2`) are upgraded
in place. A new `SponsoredTasksVaultV2` implementation ships behind a new factory, so only vaults
created after the rollout get it. On each remote EVM chain a new `SponsoredTaskSettler` ships with
a new settler-mode factory; the settler it replaces keeps running for the vaults it controls.
`PayoutGateHook` is redeployed. The Solana Sponsored Tasks program is redeployed, not upgraded in
place. The fixed `TaskTokenRewardHookV2` (changes 10, 12, 31) and `EpochBudget` (change 25) are
built and tested but not deployed in this rollout; they ship in a later release.

## Motivation

A code review of the Sponsored Tasks contracts (2026-11-15) found gaps on EVM and in the Solana
program. Rev031 fixes the ones whose fix is settled:

- a settler-attested Solana payout binding could fall back to a superseded address (change 1);
- tokens left in, or sent to, an exited vault were locked for good, and the exit recorded the
  amount before a token's fee rather than what arrived (change 2);
- a verdict padded with zero-amount awards released the whole sponsorship (change 3);
- a requester that padded its own accepted award list past the ceiling released the sponsorship
  with nothing recording who caused it (change 9);
- fresh wallet pairs, which the wallet-age ramp credits nothing, could reserve the whole DREAMS
  epoch budget at claim (change 10);
- a Bounty or Benchmark payout to such wallets spent epoch budget it credited nothing from
  (change 12);
- a rejected delivery that ended the task left the reservation and the manager's cap held until a
  keeper acted (change 4);
- a Solana reservation could be released while its task was still live, and never reserved again
  (change 5);
- an EVM settler's signed `Reserve` never expired, so a reserve that failed to relay could land
  long afterwards for a task that had been cancelled (change 8);
- a remote EVM vault keyed each manager's allowance by address alone, so whoever controls that
  address on another task chain could spend it (change 11).

## Changes

### 1. A second attested payout keeps paying the effective one (Solana)

**Problem.** `bind_payout_attested` stores the settler-attested payout in `pending_payout` until one
claim delay has passed, and `effective_payout` pays it from then on. It was never promoted into
`payout`. A second attestation overwrote the pending one, so a payout that had already taken effect
was dropped. Claims, which anyone may relay, then paid the older `payout` for a whole claim delay,
or failed with `PayoutNotBound` for an agent that had never signed a binding.

**Change.** `write_pending_binding` first promotes an attested payout that is already effective
into `payout`, and only then stores the new one as pending. A first attestation that is still
pending when the second arrives was never paid, and is simply replaced. Details are in
[`../sponsored-tasks/payout-binding.md`](../sponsored-tasks/payout-binding.md) ("Attested binding
for contract-wallet agents").

### 2. Exited vaults can be swept, and the exit records what arrived (EVM and Solana)

**Problem.** The emergency exit is one-shot and accepts a short delivery: since rev026 a token that
charges a transfer fee can still be moved out. After the exit every other path is closed
(`withdrawAvailable` and `fund` need an active vault), so tokens left behind, or tokens sent to the
vault afterwards, were locked for good. `totalWithdrawn` and `VaultEmergencyExited.amountWithdrawn`
recorded the vault's balance before the fee, not what the recipient received.

**Change.**

- `SponsoredTasksVaultV2.sweepExited(recipient)`, owner only (`msg.sender`), sends the whole balance
  of an exited vault to `recipient` with the exit's transfer check. It emits
  `ExitedVaultSwept(vaultId, owner, recipient, amount)`, adds what arrived to `totalWithdrawn`, and
  returns it. It reverts with `VaultNotExited` on an active vault and with `ZeroAddress` for a zero
  recipient. It has no signed variant.
- `emergencyExitVault` (and its signed form) now records what the recipient received in
  `totalWithdrawn`, in its return value and in `VaultEmergencyExited.amountWithdrawn`.
- Solana: `sweep_exited`, sponsor only and open while paused, moves the vault token account's
  balance to the sponsor's token account, adds it to `total_withdrawn` and emits
  `ExitedVaultSwept { vault, sponsor, recipient, amount }` (`VaultNotExited` before the exit). A
  Solana mint cannot charge a transfer fee (`create_vault` refuses the extension), so the Solana
  exit already recorded what arrived.

An exited vault owes nothing: every reservation and unclaimed award defaulted when its epoch
advanced. So its whole balance is the owner's. Details are in
[`../sponsored-tasks/signed-vault-actions-and-signed-funding.md`](../sponsored-tasks/signed-vault-actions-and-signed-funding.md)
("Exited vaults: sweep and the recorded exit amount").

### 3. Zero-amount awards do not void a sponsorship (EVM hooks and settler service)

**Problem.** Both V2 hooks release the sponsorship when a verdict carries more than
`MAX_AWARDS` (8) awards, a bound on the gas the commitment spends under the hook stipend. They
counted every entry. The diamond lets an evaluator verdict carry up to 50 entries, zero-amount ones
included and naming any worker. So a padded verdict released the whole sponsorship: the workers kept
their USDC but got no project tokens.

**Change.** `SponsoredTaskSettlement.payingAwardCount` counts the awards that pay something.
`SponsoredTaskHookV2._commit`, `RemoteSponsoredTaskHookV2._commitCompletion`, `_adoptStoredVerdict`
and `_commitAwards` compare it, not the array length, with `MAX_AWARDS`. A zero-amount entry gets no
leaf and costs the settlement nothing. The awards digest and the stored `awardCount` still cover
every entry, so `finalizeSettlement` must be given the same array. The settler service
(`apps/backend/src/services/sponsored-task-settler.ts`) applies the same count when it plans a
remote settlement. A 50-entry verdict with eight paying awards commits well inside the stipend.
More than eight paying awards still release the sponsorship, including dust awards a requester or
evaluator spreads over extra addresses of its own. See
[`../../extensions/ext-003-sponsored-task-hook.md`](../../extensions/ext-003-sponsored-task-hook.md)
("Award-count overflow").

### 4. A forfeit that ends the task releases the reservation (`SponsoredTaskHookV2`)

**Problem.** `rejectDelivery` with a refund outcome (or on a task whose outcome cannot reopen) sets
the task to `Expired`, but the diamond dispatches only `afterForfeit` for it. The hook answered
with `ForfeitReservationRetained`, so the Base-local reservation and the manager's cap stayed held
until someone called `finalizeRelease` or `reconcile`.

**Change.** `_onForfeit` releases the reservation, as `afterExpire` does, when the reported task
status is `Expired`. A forfeit that reopens the task keeps the reservation for the next worker.
`RemoteSponsoredTaskHookV2` records nothing on that path; the settler service releases the remote
reservation from the task's `Expired` status, as before.

### 5. Settlers can extend a Solana reservation's deadline

**Problem.** A reservation's `deadline` is fixed at `reserve`, but the task chain can push the task's
expiry out afterwards (a reopen, a review window, an appeal). Once the old deadline passed anyone
could call `release_expired` while the task was live, and the task could never be reserved again:
the reservation account already exists, so a second `reserve` fails.

**Change.** `extend_deadline(new_deadline)`, settler threshold, blocked while paused like `reserve`,
moves a `Reserved` reservation's deadline later. It needs a deadline later than both the current
one and the clock (`DeadlineInPast`), and refuses a settled or released reservation
(`ReservationWrongState`), an exited vault (`VaultNotActive`) and an old epoch (`EpochMismatch`). It
emits `ReservationDeadlineExtended { vault, reservation, task_chain_id, task_id, old_deadline, new_deadline }`. The new deadline may be at most `MAX_RESERVATION_SECS` (400 days) after the clock
(`DeadlineTooFar`, change 23), so a settler threshold can postpone `release_expired` only by acting
again before each deadline passes. That is accepted: the settlers can already release or settle at
will, and the sponsor keeps `emergency_exit`. The backend settler does not call it yet; that is a follow-up. See
[`../sponsored-tasks/settlement.md`](../sponsored-tasks/settlement.md) ("Expired reservations").

### 6. `SponsoredTaskHookV2` stays under the contract size limit

`SponsoredTaskHookV2` was 24,571 bytes of runtime code at rev030, 5 under EIP-170's 24,576.
Changes 3 and 4 add about 100 bytes. The check "the vault exited after this allocation was
reserved, so mark it `DefaultedByOwner` and emit `SponsoredTaskDefaultedByOwner`" was inlined three
times (in settlement, the award-overflow release and the terminal release). It is now one private
function, `_defaultIfOwnerExited`, with the same calls in the same order. At rev031 the hook is
24,200 bytes.

### 7. A payout gate's creator needs a role on each gated task (`PayoutGateHook`, redeployed)

A new task in gating mode links itself to each listed gated task inside `beforeCreate`, so the
diamond's role check on the gated task never ran. An operator granted in one project could list
another of the owner's gated tasks, take its one link slot and, if its own task was accepted, open
the gate early. `beforeCreate` now reads the creator's roles on each listed task with
`taskCallerRoles(gatedTaskId, actor)` and accepts them as `onCall` does (`ROLE_REQUESTER` as the
gated task's requester, or `ROLE_PROJECT`); otherwise it reverts `PayoutGate__NotAuthorized`. The
full rule, the options weighed and the gas cost are in
`packages/contracts/docs/extensions/ext-005-payout-gate-settlement-extension-and-project-links.md`,
section 4.

`PayoutGateHook` has no proxy, so the fix takes effect only where the hook is redeployed and the
backend's `PAYOUT_GATE_HOOK_ADDRESS_<chainId>` and a new hook registry manifest, with a bumped
identity version, point at the new address. The payout gate docs and the CLI's `--gates`
pre-payment check describe the role rule from then on. Tasks that already carry the previous deployment keep its rules.

### 8. An EVM settler's `Reserve` carries a deadline (`SponsoredTaskSettler`)

**Problem.** The settlers sign a `Reserve` only while the task is open, but nothing bounded when it
could be submitted, and anyone may relay it. The signatures of a reserve whose relay failed sit in
its reverted calldata and in the signer's store. Submitted later for a task that had since been
cancelled, `reserve` (which cannot read the task chain) locked `grossAmount` in the vault and the
same amount of the manager's cap until the settlers signed a release. No funds moved to anyone; it
was griefing only. The Solana program's `reserve` already takes a signed deadline.

**Change.**

- `Reserve` gains a final field `uint64 deadline` (unix seconds). `RESERVE_TYPEHASH` is now
  `Reserve(address vault,bytes32 vaultId,bytes32 allocationId,uint256 taskChainId,bytes32 taskId,uint64 commitmentNonce,address manager,uint256 grossAmount,uint64 epoch,uint16 feeBps,address feeRecipient,bytes32 termsHash,uint64 deadline)`,
  and `ReserveRequest` gains the field in the same position.
- `reserve` reverts with `ReserveExpired(deadline)` when `block.timestamp > deadline`, before any
  other check or state change. `release` and `settle` are unchanged: a late release only returns
  funds, and a settle is bound to the reserved allocation's commitment and can be revoked during
  the claim delay.
- The EIP-712 domain name and version are unchanged. The new settler has a new address, so no
  signature made for the old one verifies on it.
- The backend signer sets `deadline` to the earlier of the signing time plus a reserve lifetime
  (`EVM_SETTLER_RESERVE_LIFETIME_SECONDS`, default one hour) and the hook's release deadline less
  ten minutes, and does not sign one whose deadline would be under five minutes away. A reserve
  job still unlanded past its deadline is marked `expired` and its
  commitment returns to the reserve queue, which re-signs it with a fresh deadline if the task is
  still open and skips it if the task ended. The attempts count carries over, so a relay that
  keeps failing still ends as failed and alerts.

`SponsoredTaskSettler` is not upgradeable and a vault's controller is fixed at creation, so the
change ships as a new settler and a new settler-mode `SponsoredTaskFactoryV2` whose controller is
the new settler (`RedeploySponsoredTaskSettler` in `DeploySponsoredTaskSettler.s.sol`). Vaults
created on the old factory keep the old settler, and with it the `Reserve` without a deadline, for
their lifetime. The backend keeps a settler context for the old settler on each chain
(`SPONSORED_TASK_SETTLER_PREVIOUS_ADDRESS_<chainId>`, or the chain registry's
`settlerMode.previous`), which signs the old `Reserve` for those vaults
only, and keeps indexing the old factory's vaults and the old settler's events. Once the new
factory is authorized, the registry owner deauthorizes the old settler-mode factory so no new vault
gets the old settler; deauthorizing a factory does not unregister its vaults. Owners of old-factory
vaults can withdraw their available balance and create a new vault; nothing moves their funds for
them. For those vaults the remedy for a stray late reservation stays a settler-signed release.

### 9. A requester's padded award list records a default against the requester (EVM hooks)

**Problem.** Change 3 stops zero-amount awards counting toward `MAX_AWARDS`, but a requester can
still accept nine or more non-zero dust awards with `acceptSubmissions`, eight of them to addresses
it controls. Both V2 hooks then release the whole sponsorship (`AwardCountExceeded`): the workers
keep their USDC but get no project tokens. Nothing on chain recorded that the requester, not an
evaluator, caused the release.

**Change.** When the overflow release happens in `beforeAccept` on a task with no evaluator,
`SponsoredTaskHookV2` and `RemoteSponsoredTaskHookV2` also emit
`SponsoredTaskDefaultedByRequester(taskId, allocationId, requester)`, naming the requester of
record. A task with no evaluator reaches `beforeAccept` only through the requester's
`acceptSubmission` or `acceptSubmissions`: an evaluator verdict, and so an appeal and a dispute
resolution, needs an evaluator (`acceptSubmissions` refuses a task that has one). The event fires
only when the call moves the allocation from `Reserved` (`Committed` on the remote hook) to
`AwardCountExceeded`, so an owner default (`DefaultedByOwner`) or a repeated call records nothing.
An overflow found later from a stored verdict (`afterComplete`, `reconcile`) holds awards a
transforming hook chose, not the requester, and records nothing either. The event changes no
balance and no status: the release is the one change 3 describes. The backend keeps the event in
`protocol_events` and counts it in the requester's stats (`sponsoredTaskDefaultCount` from
`GET /requester/{address}/stats` and `taskmarket requester stats`). It costs `SponsoredTaskHookV2`
142 bytes of runtime code (24,342 of 24,576).

### 10. Zero-multiplier reservations hold at most a share of the DREAMS epoch budget (`TaskTokenRewardHookV2`)

**Problem.** `TaskTokenRewardHookV2` consumes the bonus from `EpochBudget` when a worker claims
(or is selected), whatever the wallets' age. The wallet-age ramp is applied at payout, so a pair
whose requester and worker are both younger than the first ramp threshold (multiplier 0) holds
budget it may never earn. Fresh wallet pairs could reserve the whole global epoch budget, hold the
claims across the epoch roll and then release them, leaving nothing for wallets that earn.

**Change.** Crediting at payout age is unchanged (`test_ageRamp_quarterXBetweenTwoAndFourWeeks`
still pins it). A reservation whose requester and worker both have a zero age multiplier when it is
made is taken only while the epoch's global usage, with it added, stays within
`zeroAgeReserveShareBps()` of `EpochBudget.globalCapUsd`. Past that point it reserves nothing and
consumes no budget, the same outcome as an exhausted budget, and the USDC flow is never blocked.
Because each such reservation is made only while the whole epoch's usage is within the share, all
of them together never hold more than the share; a release lowers the usage and lets the next one
in. The gate is measured against all usage, so once reservations by any wallets pass the share, a
fresh pair reserves nothing until usage falls or the epoch rolls; this keeps the hook free of
per-epoch counters. A reservation where either wallet has a non-zero multiplier is not gated.

The share is a parameter. The owner sets it with `setZeroAgeReserveShareBps(uint16)`: at most
10000, where 10000 lifts the gate and 0 refuses every zero-multiplier reservation. Until it is set,
`DEFAULT_ZERO_AGE_RESERVE_SHARE_BPS` applies: 1000 (10%). A zero-multiplier reservation credits
nothing unless its task pays after the first ramp step (two weeks by default), and then only a
quarter, so 10% keeps room for those long tasks while the other 90% of each epoch stays for
wallets that earn.

The hook was 58 bytes under EIP-170 before this change. To fit it, three refactors with the same
behaviour: the `onlyDiamond` check is one private function instead of inline modifier code in every
callback, the two `EpochBudget.release` calls that hand back an unused bonus share one private
function, and `_reserveForWorker` emits `RewardReserved` once instead of on two paths. The setter
emits no event, as `setRamp` and `setWorkerSplitBps` emit none; the current value is read with
`zeroAgeReserveShareBps()`. After this change the hook is 24,505 bytes (24,549 after change 12). See
[`../../extensions/ext-001-token-reward-hook.md`](../../extensions/ext-001-token-reward-hook.md)
("Zero-age reservation share").

### 11. A remote vault's manager allowance is bound to a task chain (`SponsoredTasksVaultV2`, `SponsoredTaskSettler`)

**Problem.** A settler-mode vault on a remote chain funds tasks from every task chain with a
`RemoteSponsoredTaskHookV2` (Base and Tempo). It kept one allowance per manager address, and the
manager is whoever created the task on its task chain. An EOA is the same key on every EVM chain,
but a contract wallet's controllers live in per-chain storage: a Safe whose owners changed on one
chain only, a counterfactual wallet whose factory salt does not commit to the owner (anyone may
deploy it first on another chain), a factory that is a different contract there, or an address from
a shared deployer's nonce. In those cases another party could create tasks on the other chain that
reserved up to the manager's remaining cap and awarded the sponsor's tokens to accounts it controls.
The Solana program keys managers by `(chain_id, evm_address)` and requires
`manager.chain_id == task_chain_id`.

**Change.**

- The vault keys manager accounts by `(taskChainId, manager)`. Each allocation records its task
  chain, so release and settlement refund and spend the account the reservation charged.
- Every v2 entry point keeps its signature and acts on `block.chainid`, the vault's own chain, the
  only task chain a hook-mode vault serves: `configureManager`, `configureManagerBySig` (typehash
  unchanged), `reserveTask`, `managerAccount`, `managerRemaining`. For a hook-mode vault nothing
  changes.
- New: `configureManagerForChain(taskChainId, manager, cap, active)`,
  `configureManagerForChainBySig(..., deadline, signature)` with
  `ConfigureManagerForChain(bytes32 vaultId,uint256 taskChainId,address manager,uint256 cap,bool active,uint256 nonce,uint256 deadline)`
  (the owner nonce, deadline and ERC-1271 rules of the other signed actions), the controller's
  `reserveTaskForChain(allocationId, taskChainId, taskId, manager, ...)`, the views
  `managerAccountForChain` and `managerRemainingForChain`, the event
  `ManagerConfiguredForChain(taskChainId, manager, cap, reserved, spent, active)` and the error
  `TaskChainRequired` for a zero task chain.
- `SponsoredTaskSettler.reserve` calls `reserveTaskForChain` with the signed `Reserve`'s
  `taskChainId`. The task chain was already signed, so the message gains no field for this.
- `VAULT_VERSION` is 3 and the factory's `IMPLEMENTATION_VERSION` is 3, so a client tells a rev031
  vault from an earlier one by version, not only by factory address. Every v2 signed action works
  on both, so a client gates them on a version of 2 or more.

It ships in the same new implementation and factories as change 2: the new hook-mode factories and
the new settler-mode factory (change 8) all clone it, so there stays one vault model and remote
chains are redeployed once. Vaults created earlier keep the address-only key for life; for them a
remote vault serving more than one task chain should only have managers that are EOAs or contract
wallets with the same owners on every task chain, and an owner can withdraw and create a new vault.
The backend relays the two new owner actions, previews a remote funding against
`managerRemainingForChain` for a version-3 vault, records each vault's implementation version and
keys a version-3 vault's manager rows by task chain; the CLI's `sponsored-task managers` takes
`--manager-chain-id` for such a vault on Robinhood Chain.

### 12. A zero-age Bounty or Benchmark payout spends no epoch budget (`TaskTokenRewardHookV2`)

**Problem.** Change 10 gates reservations only. A Bounty or Benchmark task has no reservation: its
bonus is paid in `_payBounty` at completion, which consumed the winner's bonus from `EpochBudget`
and moved the tokens from the vault to the hook whatever the wallets' age. For a winner and
requester whose age multipliers are both zero, `_creditWithSplit` then credited nothing (the tokens
became sweepable), but the budget stayed spent for the epoch. Wallets that earn nothing could still
use up the epoch budget this way, at the cost of the platform fee on real USDC tasks.

**Change.** `_payBounty` skips such a winner before it reads or consumes the budget: it spends no
epoch budget, moves no vault tokens and emits no `RewardPaid`, and its bonus does not count toward
the task's per-task cap. Since the credit would have been zero, it consumes exactly what it
credits. The rule is change 10's, both multipliers zero, through the same private check
(`_bothZeroAge`). Any other winner is paid exactly as before, at its age at payout, and a skipped
winner still counts toward `MAX_BONUS_AWARDS`, so the loop's gas bound is unchanged. It costs the
hook 44 bytes: 24,505 to 24,549 of 24,576.

### 13. One award validation for verdicts, rulings and hook results (`EvaluatorFacet`, `HookDispatchFacet`)

**Problem.** An evaluator verdict and a dispute ruling were checked by
`EvaluatorFacet._validateAwardRecipients`, a transforming hook's result by
`HookDispatchFacet._decodeResult`, and the two sets of rules had drifted apart:

- A hook result was bounded by the constant `MAX_SUBMISSION_WINNERS` (50), not the chain's winner
  cap (`maxSubmissionWinners`, 30 on Tempo). Acceptance and `finalizeVerdict` store every returned
  award, so a 50-entry result on Tempo could need more gas than the 30M transaction cap (Cyclops
  7634, 7620; Cantina TASK-69).
- A hook result could pay a Bounty or Benchmark award with rank 0, which rev030 refuses from an
  evaluator (Cyclops 7633).
- Neither path refused two paid awards with the same contest rank, so a settlement could name
  several first places (Cantina TASK-329, TASK-236).
- A verdict could pay one worker twice. Each paid award emits its own `TaskCompleted`, so one task
  could be indexed as several completed tasks for that worker (Cantina TASK-338). Hook results
  already refused this.

**Change.** A new internal library, `LibAwards`, holds the rules, and both facets call its
`check`: at most the chain's winner cap of entries (zero-amount entries count, since each is stored
with the verdict); the paid total within the award budget; every paid award to an eligible worker
(one who submitted on a Bounty or Benchmark, the locked worker on Claim, Pitch and Auction); no
worker paid twice; and on a Bounty or Benchmark every paid award ranked from 1 with no two paid
awards sharing a rank. Zero-amount entries pay nothing and name no place, so only the cap applies to
them, as in rev030. Ranks need not be contiguous. `evaluate` and `resolveDispute` revert with the
rule's existing error (`TooManyWinners`, `AwardsExceedEscrow`, `InvalidAwardRecipient`,
`SubmissionNotFound`, `WorkerMismatch`, `DuplicateAwardWorker`, `InvalidAwardRank`); a hook result
that breaks one is invalid (`HookResultInvalid` on the vetoable accept path). `_decodeResult` keeps
the 50-entry bound only as a decoding limit. No error or selector is added. Two paid awards to one
worker were previously accepted from an evaluator on any mode; they are now refused on every mode,
matching hook results.

### 14. The primary worker is the lowest-ranked paid award (`EvaluatorFacet`)

**Problem.** On a Bounty or Benchmark, `evaluate` and `_payAwards` set `task.worker` to the first
paid entry in array order, whatever its rank. A verdict listing rank 2 before rank 1 made the
rank-2 worker the task's worker and the only awarded worker who may appeal, while clients treat rank
1 as the winner (Cantina TASK-414).

**Change.** `LibAwards.primary` returns the lowest-ranked paid award, the earliest on a tie (a tie is
possible only in a verdict stored before rev031). `evaluate` and `_payAwards` set `task.worker` from
it, so the order of the award list no longer matters; a verdict that pays no one still clears the
worker on a Bounty or Benchmark. On Claim, Pitch and Auction only the locked worker can be paid, so
nothing changes there.

### 15. A hook reallocation on acceptance moves the worker and deliverable (`AcceptanceFacet`)

**Problem.** `acceptSubmission` and `acceptSubmissions` set `task.worker` and `task.deliverable`
from the requester's choice before the transforming hook runs. When the hook's result paid a
different worker first, the task kept the original worker and deliverable, so `getTask` and the
`afterComplete` context (`ctx.worker`) disagreed with the awards paid (Cantina TASK-237). The
evaluator path already moved `task.worker` after a hook result.

**Change.** When a transforming hook replaces the awards on a Bounty or Benchmark acceptance,
`AcceptanceFacet` sets `task.worker` to the lowest-ranked paid award of the result (change 14's
rule) before the after-callbacks run. If that is a different worker, `task.deliverable` becomes that
worker's latest submission; if it is the accepted worker, the deliverable the requester accepted is
kept. A result that pays no one clears both. A result that only takes a hook fee (no award list)
changes neither.

### 16. A ruling that changes only ranks does not uphold the verdict (`EvaluatorFacet`)

**Problem.** `_sameVerdict` decides whether a dispute ruling upholds the evaluator, which pays the
evaluator its fee. It compared each award's worker and amount but not its rank, so a ruling that
reordered the places counted as upholding (Cyclops 7623).

**Change.** `_sameVerdict` also compares rank. A ruling upholds only when it repeats the verdict's
type and every award's worker, amount and rank in the same order; otherwise the evaluator fee goes
back to the requester, as for any changed ruling.

**Cut and tests (changes 13 to 16).** `EvaluatorFacet`, `HookDispatchFacet` and `AcceptanceFacet`
change bytecode and are cut with replaced routing; no selector is added, removed or changed, and
`AppStorage` is unchanged. `evm/test/Rev031AwardValidation.t.sol` covers each finding: duplicate
paid ranks and workers on `evaluate` and `resolveDispute`, the lowest-ranked primary worker and who
may appeal, a rank-only ruling paying no evaluator fee, a hook result over a cap of 3, a hook result
paying rank 0 or sharing a rank, and the worker and deliverable after a reallocation on
`acceptSubmission` and `acceptSubmissions`. `make smoke rev030` (local Anvil) asserts the two new
`evaluate` refusals.

### 17. A task's evaluator and dispute resolver cannot work on it (`WorkerFacet`, `AuctionFacet`, `EvaluatorFacet`)

**Problem.** Nothing compared a worker with the task's evaluator or dispute resolver
(Cantina TASK-9, TASK-27). A configured evaluator could claim an open Claim task or submit to a
Bounty or Benchmark, then judge its own work and award itself the reward, and its fee on top. A
resolver that had also submitted could appeal a zero-award verdict on its own entry and resolve the
dispute in its own favour. Either role can also be appointed with `assignEvaluator` after the
address has bid on an auction, or after its contest entry was rejected (the call needs no live
entry), and a task in flight at the upgrade may already have a judge among its submitters.

**Change.** A new `LibProject.requireNotJudge`, beside `requireNotActingParty`, reverts
`InvalidWorker` when an address is the task's evaluator or dispute resolver. It applies on every
task, project or not, at each place a worker takes a role: `claimTask`, `selectWorker`,
`submitWork`, `submitBid`, `acceptAuction`, `selectLowestBidder` (the lowest bidder may have been
named a judge since it bid) and `appeal`; and to each paying award in a verdict or a dispute
resolution, in `_validateAwardRecipients`, which covers a judge that submitted before it was
appointed. The zero address is never a judge, so a task without an evaluator is unchanged. An
English auction whose lowest bidder is refused cannot select another bidder, so it lapses to a
refund at expiry.

Changes 17 to 22 cut four facets: `WorkerFacet` 9,324 to 9,441 bytes, `AuctionFacet` 3,942 to
4,103, `EvaluatorFacet` 23,614 to 24,021 and `AcceptanceFacet` 17,890 to 17,839, all under 24,576.
No selector is added, removed or changed, and no `AppStorage` field is added.

### 18. A rejected Bounty or Benchmark entry stays rejected under a verdict (`EvaluatorFacet`)

**Problem.** `rejectSubmission` keeps a worker's submission hashes and sets
`taskRejectedWorkers`. Rev030 stops a requester rejecting while an evaluator is assigned, but a
requester could still reject entries and then assign an evaluator, whose recipient check looked
only for a submission hash and so could award the rejected worker (Cantina TASK-18).

**Change.** `_validateAwardRecipients` refuses a paying contest award to a worker with
`taskRejectedWorkers` set (`SubmissionAlreadyRejected`), in `evaluate` and in `resolveDispute`. The
same rejection already stops that worker submitting again.

### 19. A contest with no live submission cannot be judged (`EvaluatorFacet`)

**Problem.** `evaluate` accepted a verdict on an Open Bounty or Benchmark with no active submission
(Cantina TASK-100). The verdict moved the task to Appealing, which closed it to submissions and left
no worker who could appeal, and finalizing it paid the evaluator's fee, up to the whole reward at
10000 bps. `evaluatorTimeout` already required a live submission.

**Change.** `evaluate` on a Bounty or Benchmark outside Review reverts `NoActiveSubmissions` when
`taskActiveSubmissionCount` is zero, the same test `evaluatorTimeout` applies. With no entry left
the requester cancels or the task expires to a refund.

### 20. A single-payee acceptance names delivered work (`AcceptanceFacet`)

**Problem.** For Claim, Pitch and Auction, `_validateAcceptSubmission` checked that the deliverable
matched `task.deliverable`, which is zero until the worker delivers (Cantina TASK-107). An
acceptance with a zero deliverable therefore paid a claimed or selected worker that had delivered
nothing, counted a completed task and returned its stake, past the no-delivery refund and forfeit
outcomes.

**Change.** `acceptSubmission` reverts `DeliverableRequired` for a zero deliverable on Claim, Pitch
and Auction too, after each mode's status and worker checks, so those keep their errors; Bounty and
Benchmark already required it. An undelivered
single-payee task still ends by refund, forfeit or release as before.

### 21. The acting-party rule holds for the self-award signal and the lowest bidder (`AcceptanceFacet`, `AuctionFacet`)

**Problem.** Two places read a narrower rule than the one the rest of the contract uses. A
single-winner Bounty or Benchmark acceptance emitted `SelfAward` when the worker was an acting
party (the requester of record, or a project task's operator or owner), but set the
`RequesterReputation` event's `selfAward` flag only when the worker was the requester of record, so
an owner or operator paying itself read as an arm's-length payout (Cyclops 7650). And
`selectLowestBidder` did not re-check the lowest bidder, which `submitBid` checks only when the bid
is placed, so a bidder that became the project's owner was assigned as the worker (Cyclops 7616).

**Change.** The flag is set exactly when `SelfAward` is emitted, from `isActingParty`, on both the
unchanged and the hook-changed branch. `selectLowestBidder` calls `requireNotActingParty` on the
lowest bidder (and `requireNotJudge`, change 17); a refused bidder leaves the auction to lapse to a
refund at expiry.

### 22. A co-winner can appeal a verdict that awards it (`EvaluatorFacet`)

**Problem.** On a Bounty or Benchmark, `evaluate` sets `task.worker` to the first paying award, and
only that worker could appeal (Cyclops 7666). A transforming hook's cut applies at `finalizeVerdict`,
after the appeal window, and the appeal is the one remedy rev030 keeps open against it. Co-winners
whose awards a hook cuts had no standing, and the first winner has no reason to appeal for them.

**Change.** `appeal` also admits any worker the stored verdict pays a nonzero amount, at most the
winner cap of entries to scan. It applies to every Bounty and Benchmark verdict, with or without a
transforming hook: a co-winner disputing its own share is the case the appeal exists for. A
submitter with no award still cannot appeal a verdict that awards someone, so the rev013 rule that
stops an unawarded entrant stalling a winner's payout holds. The empty-award case is unchanged: any
submitter may appeal it. Change 17 still refuses an appeal from the evaluator or resolver.

`evm/test/Rev031RoleConflicts.t.sol` covers changes 17 to 22, one test or more per change, each
failing on rev030 code; `evm/test/TaskMarket.t.sol` delivers work before its single-payee
acceptances (change 20). The local smoke `make smoke rev031-roles` checks changes 17, 19, 20 and
22 on a running diamond.

### 23. Solana reservation deadlines, claim destinations and settler keys (Cyclops 7612, 7661, 7652, 7645)

Four fixes to the Solana program. It is not deployed anywhere, so nothing migrates.

**A revoke after the deadline (Cyclops 7612).** `revoke_settlement` returned the reservation to
`Reserved` with the deadline it was reserved with. When that deadline had passed while the root
was installed, anyone could call `release_expired` before the settlers signed the corrected root,
and the task could never be reserved again: the reservation account already exists. The revoke
now sets the deadline to the later of its own and the clock plus one claim delay
(`Config::claim_delay`), the same window the root watcher already works in. A deadline still
further out is kept. The revoke emits the same `SettlementRevoked` event; the reservation account
carries the new deadline.

**A cap on reservation length (Cyclops 7661).** `reserve` only required the deadline to be in the
future, so one settler signature with `i64::MAX` disabled `release_expired` for that reservation
for good. `reserve` and `extend_deadline` now refuse a deadline more than `MAX_RESERVATION_SECS`
(400 days) after the clock with the new error `DeadlineTooFar`. 400 days covers the task chain's
longest task (365 days) plus `RemoteSponsoredTaskHookV2.RESERVATION_RELEASE_GRACE` (7 days). The
bound runs from the clock, so the settlers can still extend a live task's reservation again, which
keeps change 5's accepted behaviour: a settler threshold can postpone `release_expired` by acting,
but no single signature can remove it. The revoke window above is not capped; it is one claim
delay, which the admin sets.

**The payout's associated token account (Cyclops 7652).** `claim` checked only that the
destination was a token account of the vault's mint owned by the bound payout. Anyone may relay a
claim, so a relayer could pay the award into any other token account that owner holds, including
one the relayer created for it. Nothing is stolen, but a payout that is a program-derived address
(a multisig vault, another program) may only be able to move tokens from its associated account,
and the award would be stuck. `claim` now requires the payout's associated token account for the
vault's mint and token program and fails with the new error `PayoutAccountNotAssociated`. The
backend relayer already pays that account and creates it idempotently in the same transaction, so
no relayer change is needed. `claim_fee` is unchanged: the fee recipient signs it and picks its own
account.

**No zero settler key (Cyclops 7645).** `validate_settlers`, run by `init_config` and
`set_settlers`, accepted `Pubkey::default()`. No one holds that key, so it could only lower the
real threshold silently. It now fails with `InvalidSettlers`.

API: new errors `DeadlineTooFar` (6043) and `PayoutAccountNotAssociated` (6044), appended so
earlier codes do not shift; the `InvalidSettlers` message names the zero key; new constant
`MAX_RESERVATION_SECS`. No instruction, account or event changes; the IDL and
`packages/solana-sponsored-client` are regenerated for the errors.

Tests: `solana/programs/sponsored-tasks/tests/vault.rs` (a revoke after the deadline leaves a
claim delay to settle again; a later deadline is kept and still expires; `reserve` and
`extend_deadline` at and one second past the cap, and `i64::MAX`; the zero settler key in
`init_config` and `set_settlers`) and `tests/claim.rs` (a claim to a non-associated token account
of a program-derived payout is refused, the associated one is paid). Smoke: `make smoke
sponsored-solana` asserts `InvalidSettlers`, `DeadlineTooFar` on `reserve` and `extend_deadline`,
`PayoutAccountNotAssociated`, and a T8 reservation revoked after its deadline that stays reserved
for a claim delay.

### 24. Deploy scripts set the Tempo winner cap and check what they build on (scripts only)

**Problem.** Four deploy-script gaps (Cyclops 7630, 7628, 7662, 4405; Cantina TASK-110):

- Only `Rev030Upgrade` set the Tempo submission winner cap (30). `DiamondDeploy` never called
  `setMaxSubmissionWinners`, and a fresh diamond stamps the current revision, so no upgrade step
  runs on it: a fresh Tempo diamond kept the 50-winner fallback, whose payout does not fit Tempo's
  30M transaction cap.
- `DeployRewardHookV2` and `DeployPayoutGateHook` required only rev028, though the reward hook pays
  its bonus in `afterComplete` from the awards a rev030 diamond records, and the payout gate reads
  `taskCallerRoles`, whose project role follows task control from rev030 on. `UpgradeRewardHookV2`
  already required rev030.
- `DeploySponsoredTaskHookV2` took the registry and fee policy addresses on trust: no check that
  either has code, that the admin owns the fee policy, or that the registry is the admin's.
  `DeploySponsoredTask`, which creates both, checks the same things.
- `script/tempo.sh deploy` left `FORGE_PGTR_FORWARDER` in the environment, so a Base forwarder in
  `.env` was trusted by a fresh Tempo diamond.

**Change.** `DiamondDeploy` sets the winner cap on chains 4217 and 42431, from
`script/lib/WinnerCap.sol`, which `Rev030Upgrade.winnerCapFor` now reads too, so a new diamond and
an upgraded one get the same cap. `DeployRewardHookV2` and `DeployPayoutGateHook` refuse a diamond
below rev030. Neither depends on a rev031 facet change, so requiring 31 would block a hook deploy
on a rev030 chain for no reason.
`DeploySponsoredTaskHookV2` refuses a registry or fee policy with no code, a fee policy the admin
does not own, and a registry that is neither owned by the admin nor pending to it (the state
`DeploySponsoredTask` leaves). `tempo.sh deploy` unsets `FORGE_PGTR_FORWARDER`: a Tempo diamond
trusts only the forwarder `deploy-forwarder` builds and checks for it. No contract, selector or
storage changes; nothing to cut.

**Tests.** `evm/test/DiamondDeployScript.t.sol`: a fresh diamond on 4217 and 42431 reports a winner
cap of 30, and on 8453 and 84532 the default 50. `evm/test/DeployHooksV2Scripts.t.sol`: the payout
gate and reward hook deploys refuse a rev029 diamond; the sponsored hook deploy refuses a registry
or fee policy with no code, a fee policy owned by someone else and a registry with no path to the
admin, and once the admin owns the registry it leaves `setFactory` to it.
`evm/script/test/tempo-sh.test.mjs`: `deploy` hands forge no `FORGE_PGTR_FORWARDER`.

### 25. Changing the epoch duration rolls a lapsed epoch first (`EpochBudget`, built, deployment deferred)

**Problem.** `EpochBudget.setEpochDuration` wrote the new duration without rolling the epoch
(Cyclops 7627). Only the hook rolls it, on its next consume or release, so an epoch can lapse
unrolled. A longer duration set then put `block.timestamp` back inside the lapsed epoch, and the
global, worker and requester usage recorded in it counted again until the new, longer epoch ended:
earners were refused bonuses the caps should have allowed. A shorter duration did no harm. Only the
owner can call it.

**Change.** `setEpochDuration` calls `_rollEpochIfStale()` under the old duration before it writes
the new one, so a lapsed epoch's usage stays in the past. Inside a live epoch nothing rolls and its
usage still counts. `EpochBudget` is not upgradeable, so the fix ships as a new budget:
`DeployHooksV2.s.sol:RedeployEpochBudget` (with `FORGE_REWARD_HOOK_V2_ADDRESS`) deploys one with the
live budget's duration, caps, owner and hook, and switches the hook to it with `setEpochBudget`, or
prints that call for the hook's owner. The old budget keeps the hook, so a reservation pinned to it
is still released there. The new budget starts with no usage: what the current epoch already
consumed on the old budget does not count against the new caps, which the script prints so the
switch can be timed just after an epoch boundary. No ABI change; `EpochBudget` grows 9 bytes,
3,850 to 3,859.

**Deployment.** The new budget is built and tested but is not deployed as part of the rev031
rollout: the live budgets stay in place and `RedeployEpochBudget` runs in a later release. Until
it does, the live budget keeps the old behaviour, so the owner must not raise the epoch duration
after an epoch has lapsed unrolled; lowering it, or raising it inside a live epoch, stays safe.
When the switch is made, two things do not carry over. The new budget starts with no usage, so
what the current epoch consumed on the old budget is not counted again (switch just after an epoch
boundary). The per-task cap (`taskUsage`) is kept per budget, so a task that consumed on the old
budget is measured from zero on the new one.

**Tests.** `evm/test/EpochBudget.t.sol`: a duration raised after a lapse starts global, worker and
requester usage from zero, and a full per-task amount can be consumed again; a duration raised
inside the epoch keeps its usage. `evm/test/DeployHooksV2Scripts.t.sol`: the redeploy copies the
live budget, keeps the old one serving the hook, and leaves the switch to the hook's owner.

### 26. A grant carries its limits, and the operator accepts them (`ProjectFacet`, cut)

**Problem.** `grantOperator`, `acceptGrant` and `setGrantLimits` were separate transactions, and the
limits were not in the hash the operator accepts (Cyclops 7663). An operator could accept as soon as
it saw `OperatorGranted` and draw before the owner's `setGrantLimits` landed: the cap in the terms
bound it, but the expiry, the mode mask, the per-task maximum and the period budget did not.

**Change.** `grantOperator(uint256 projectId, address operator, GrantTerms terms, GrantLimitsInput
limits)` stores the limits in the same call, with the same checks as `setGrantLimits`
(`InvalidGrantLimits`) and the same `GrantLimitsSet` event, so a grant is never live without the
owner's limits. Zero limits still mean none. A regrant after a revoke states its limits too; the
period meter carries over only when the period length is unchanged, as with `setGrantLimits`.
`acceptGrant(projectId, termsHash)` takes `keccak256(abi.encode(terms, limits))`, the limits being
the `GrantLimitsInput` fields of `getGrantLimits`, so limits the owner changed on a pending grant
after the operator read it cannot be accepted by mistake, as terms already could not. After
acceptance the owner may still tighten or loosen the limits with `setGrantLimits`. The three-argument
`grantOperator` is removed, so no client can grant without stating limits. A grant that is pending
when the cut lands must be accepted with the new hash. `ProjectFacet` grows 536 bytes, 22,894 to
23,430 of 24,576.

**Tests.** `evm/test/ProjectGrantLimits.t.sol`: limits granted with the terms bind the operator's
first draw (`GrantRewardTooHigh`), and the terms-only hash and a hash with other limits are refused;
limits changed on a pending grant must be accepted again; a regrant sets its limits and keeps the
meter for the same period. Every other grant test sends the limits and accepts the new hash.

### 27. A reputation registry without code, or one that burns gas, cannot stop settlement (`AdminFacet`, `LibFeedback`, cut)

**Problem.** Two gaps on the call every feedback path makes to the ERC-8004 reputation registry:

- `AdminFacet.setReputationRegistry` took any address (Cyclops 7631). `LibFeedback._send` calls
  `giveFeedback` inside `try`/`catch`, but Solidity checks that the target has code before the call
  and reverts in the caller's frame, outside the `catch`. With a registry address that has no code,
  every path that sends feedback reverted: acceptance, cancellation, `refundExpired` and the
  timeouts. The owner could recover by setting another registry.
- `giveFeedback` was given all but 1/64 of the remaining gas (Cyclops 7643), so a registry that
  burns gas could take almost the whole transaction. The `catch` then ran on what was left, which
  on Tempo, where a settlement already needs most of the 30M cap, may not finish it.

**Change.** `setReputationRegistry` refuses a nonzero address with no code
(`ReputationRegistryHasNoCode`); zero still turns feedback off. `LibFeedback._send` skips a registry
that has no code when feedback is sent (one set before this check, or whose code is gone) and emits
`ReputationFeedbackFailed`, as for a reverting registry. `giveFeedback` is given at most
`FEEDBACK_CALL_GAS`, 3,000,000, above the worst measured registry cost (about 1.8M on Tempo). The
feedback gas floor (`minFeedbackGas`) is unchanged; it is still checked before the call, and its
upper bound `MAX_FEEDBACK_GAS` (5M) still caps what the owner may set it to. Sizes (of 24,576):
`AcceptanceFacet` 16,553 to 16,607, `AdminFacet` 7,234 to 7,274, `RatingFacet` 3,966 to 4,021,
`SettlementFacet` 22,579 to 22,683.

**Tests.** `evm/test/TaskMarket.t.sol`: the setter refuses an address with no code and takes zero;
with the registry's code removed, acceptance and cancellation settle and acceptance emits
`ReputationFeedbackFailed`; with a registry that burns all its gas, a 25M acceptance settles using
less than the cap plus 2M. Smoke: `make smoke min-feedback-gas` section D checks on any chain at
rev031 that `reputationRegistry()` is zero or has code and that the setter refuses an address with
no code.

### 28. An auction cannot be bid or accepted at a price of zero (`AuctionFacet`, cut)

**Problem.** `submitBid` and `acceptAuction` took a price of zero (Cyclops 7646), so a task could
be won with `stakeAmount` zero. `SponsoredTaskHookV2` weighs a worker's award by that amount: a
zero total weight made `SponsoredTaskSettlement.calculate` release the whole gross back, and the
worker got no sponsor tokens. The worker chooses the price, so it only hurt the worker who chose
it, but nothing stopped it.

**Change.** `submitBid` and `acceptAuction` revert `PriceZero` when the price is zero, before the
`maxPrice` check. A price of one base unit is still accepted. `selectLowestBidder` needs no check:
the winning price is the lowest bid, and no bid can be zero. Size (of 24,576): `AuctionFacet` 3,942
to 3,985.

**Tests.** `evm/test/TaskMarket.t.sol`: `submitBid` on an English auction and `acceptAuction` on a
Dutch auction revert `PriceZero` at zero and succeed at one. Smoke: `make smoke auction-types`
checks on a rev031 diamond that the API refuses a zero bid and that `submitBid` and `acceptAuction`
at zero, simulated through the trusted forwarder, revert `PriceZero`.

### 29. A strict after-callback runs or the action reverts (`HookDispatchFacet`, Cyclops 7615, Cantina TASK-246)

**Problem.** An accept, a cancel and a rejected delivery dispatch their after-callbacks
(`afterComplete`, `afterCancel`, `afterForfeit`) strictly: `_requireGasForAll` demands each
callback's budget (`budget * 64 / 63 + GAS_MARGIN`) once, before the first call. `_after` then
wrote the hook's sequence number and ran the best-effort skip check, which asks for the same amount
plus `SKIP_RESERVE` for every hook still to come. At the lowest gas limit that passed the up-front
demand, which is what `eth_estimateGas` finds, the sequence write had used the margin, so the first
strict callback (the DREAMS bonus `afterComplete`, for one) was skipped with `FAIL_GAS` and the
transaction succeeded. Strict dispatches also counted their spend against `MAX_EXIT_HOOK_GAS`, the
6M cap meant for forced exits, so a second strict callback was skipped once the first had spent
enough. Separately, `SKIP_RESERVE` (40k) was sized for Base, where a hook's first sequence write
costs about 20k; on Tempo that write is a new storage slot at about 250k, so a forced exit that ran
one callback and then skipped the rest could run out of gas.

**Change.** `_requireGasForAll` returns how many callbacks its demand covers (all of them, up to
`MAX_STRICT_HOOK_GAS`, and always the first). `_after` never skips those: after the sequence write
it requires the callback's gas (`_requireGas`) and reverts `InsufficientGasForHooks` if it is not
there, so a gas estimate always includes every covered callback. Callbacks past the cap stay best
effort, and no strict dispatch applies `MAX_EXIT_HOOK_GAS`. Observers and forced exits are
unchanged apart from `SKIP_RESERVE`, which is now 300k, sized for Tempo; on Base a forced exit skips
a callback when it has less than 300k per remaining hook in hand, rather than 40k. No selector,
storage field or event changes; only `HookDispatchFacet`'s bytecode does (a facet replace).

Tests: `evm/test/StrictHookGas.t.sol` finds the lowest gas limit at which an accept succeeds and
checks `afterComplete` ran at it, and runs two strict callbacks whose spend passes 6M.

### 30. An observer whose code changed is skipped, not a veto (`HookDispatchFacet`, Cyclops 7611, 7625)

**Problem.** `HookDispatchFacet._after` compared a hook's live codehash with the one pinned at
attach and reverted `HookCodeChanged` for every vetoable action, before it reached the observer's
best-effort handling. An observer (`BIT_OBSERVER`) only watches: it cannot veto the action. Yet one
whose code changed blocked every action it watched: `appeal` (a Claim worker could not appeal a
REJECT, and its stake was forfeited, Cyclops 7611), `evaluate` (the evaluator missed its window and
its stake was forfeited, Cyclops 7625) and `submitWork`. Rev030 opened `releaseClaim` for a changed
hook and refuses EIP-7702 delegated accounts at attach, so this reaches only tasks created before
rev030 with a delegated observer. It is also the rest of Cyclops 6876: an observer must never block
delivery.

**Change.** In `_after`, an observer whose codehash changed is not called. It spends its sequence
number and emits `HookCallFailedV2` with phase after and the new failure class
`FAIL_CODE_CHANGED` (6), as the gas skip does (rev030 change 14), so the hook can see the gap and
reconcile. The action goes on. Before-callbacks are unchanged: a changed hook that declares the
action's before bit still reverts `HookCodeChanged`, so a hook that can veto keeps blocking while
its code is not the code that was attached. Non-vetoable exits still do not compare codehashes. No
selector, storage field or event signature changes; only `HookDispatchFacet`'s bytecode does (a
facet replace). Indexers that read `failureClass` see a new value, 6.

Tests: `evm/test/ObserverHookCodeChange.t.sol`: a changed observer does not block `appeal`,
`evaluate` or `submitWork`, and is reported with `FAIL_CODE_CHANGED` at its sequence number; a
changed hook with the appeal before bit still blocks `appeal`. `Rev030HookSafety.t.sol` no longer
expects a changed observer to block delivery.

### 31. A requester-accepted Bounty's bonus can be recovered after a missed `afterComplete` (`TaskTokenRewardHookV2`, Cyclops 7613, Cantina TASK-99)

**Problem.** An unreserved Bounty or Benchmark task pays its bonus in `afterComplete`, from the
awards `beforeAccept` keeps in transient storage. `afterComplete` is a best-effort callback: if it
reverts or runs out of gas, the diamond swallows the failure and the task is still Accepted, with
`paid` unset. `recoverReserve` pays such a task from the diamond's stored verdict. A requester
acceptance stores no verdict for the shares it pays, so for a requester-accepted Bounty
`getTaskVerdict` returned `issued == false` and `recoverReserve` reverted `NothingToRecover`. The
winners' bonus could not be paid by anyone.

**Change.** For a Bounty or Benchmark task with no reservation, `beforeAccept` also stores the
paying awards (nonzero amounts, at most `MAX_BONUS_AWARDS`) in a new `keptAwards` mapping, one word
per award: the worker in the low 160 bits and the amount above. When the diamond has no issued
verdict, `recoverReserve` pays those stored awards through `_payBounty`, the path `afterComplete`
uses. `paid` is set first, so the bonus is paid at most once. A task with an issued verdict is
paid from that verdict as before. One case changes: an issued verdict with no awards used to set
`paid` and pay nothing. It now reverts `NothingToRecover`, and nothing is paid either way. Claim,
Pitch and Auction tasks store nothing.

Storing the awards costs `beforeAccept` new storage slots on an unreserved Bounty or Benchmark: the
array length plus one per paying award, 2 for one winner and 9 for eight. Before, it wrote only
transient storage.

**Size.** The stored awards took the hook from 24,549 to 25,034 bytes, over the 24,576 limit. To
make room, the wallet signature check of `withdrawFor` (the message text, ECDSA recovery and the
ERC-1271 fallback) moves into a new external library, `LibWithdrawAuthorization.isAuthorized`. The
hook calls it by DELEGATECALL, so `address(this)` and `block.chainid` in the signed message are
still the hook's. The library reads and writes no storage, and the hook keeps its relayer,
expiry and nonce checks. The signed message, the accepted signatures and the hook's ABI are
unchanged. The hook is now 24,045 bytes (531 left), and the library is 1,852.

**Storage.** One field appended to the end of `HookStorage`: `keptAwards`
(`mapping(bytes32 => uint256[])`). It starts empty, so tasks accepted before an upgrade have no
stored awards and recover as before.

**Deployment deferred.** The fixed hook is built and tested, but it is not deployed in this
cut. The upgrade steps include no reward-hook redeploy for this change. When it is deployed, the
implementation must be linked to a deployed `LibWithdrawAuthorization`: `forge script` deploys and
links the library in its own transaction, and verifying the implementation needs the library
address (`--libraries`).

Tests: `evm/test/TaskTokenRewardHookV2.t.sol` accepts a Bounty as its requester with a
transforming hook while `afterComplete` reverts, then checks that `recoverReserve` pays each winner
its bonus, sets `paid` and refuses a second call. The existing `withdrawFor` tests cover the moved
signature check.

### 32. A forfeited worker stake never credits the operator's cap (`LibProject`, Cyclops 7619, Cantina TASK-108)

**Problem.** A project task's forfeited worker stake goes to the project's pool through
`payWorkerPenalty`, `payRequester` and `LibProject.refund`. `refund` credits the operator's cap and
period meter with `applied = min(amount, drawn - held)`, where `held` is what the task still holds
of the pool's money (`LibEscrow.owedParts`). Rev030 made that rule keep a stake forfeited on a task
that reopens out of the credit, because the reward is still held. On a terminal settlement (an
evaluator REJECT on a Claim task, an expiry, a reserved worker's hand-back) `owedParts` returns
zero, so the stake read as returned pool money: the operator's committed amount and period meter
went down by up to the stake, bounded by the part of the draw that was paid out (the evaluator fee
or the awards). The operator could then draw that much more than its cap allows.

**Change.** `payWorkerPenalty` pays a project task's stake through `LibProject.payWindfall`, which
marks the refund as a windfall in transient storage; `refund` reads and clears the mark and applies
nothing for it. The stake still reaches the pool's available balance, as before. It lowers no draw
and gives nothing back to the operator's cap or period meter, whether the task reopens or has
ended. The rest of the draw leaves at `LibEscrow.release` as before. The mark is set only for a
project task, whose `payRequester` always reaches `refund` in the same call, so it never outlives
the payment. No selector, storage field, event or error changes; the bytecode of the facets that
inline `payWorkerPenalty` or `refund` changes.

Tests: `evm/test/ProjectRequesterPayouts.t.sol` settles two evaluator-rejected Claim tasks for an
operator, one with a forfeited stake and one without, and checks the operator's committed amount
moves the same for both while the stake still reaches the pool.

### 33. A sponsorship commits a task's reserved worker (`SponsoredTaskHookV2`, `RemoteSponsoredTaskHookV2`, Cyclops 4445)

**Problem.** The terms hash a funding request carries, and the vault records at reservation, covers
the task's terms and its settlement policy (the accept window included) but not the reserved worker
of a task created with one (rev027). A manager could create a sponsored task offered to a worker of
its choosing under a commitment that never named one: the hash matched an open task's, so the
sponsor's tokens could fund a reservation to someone the commitment did not cover.

**Change.** Both V2 hooks read the task's reserved worker (`getReservation`) when they compute the
terms hash. A task with one is committed as the rev030 commitment wrapped with the worker,
`keccak256(abi.encode(RESERVED_TERMS_HASH_TYPEHASH, termsHash, reservedWorker))`, with the new type
string `SponsoredTaskReservedTermsHash(bytes32 termsHash,address reservedWorker)`. A task without one
keeps the rev030 commitment, so every funding request for an ordinary task, and every client that
computes it, is unchanged; only a reserved-worker task needs the new form, and one funded with the
old form now reverts `TaskTermsMismatch`. Wrapping rather than adding a field keeps
`SponsoredTaskHookV2` under the size limit: 24,342 to 24,557 bytes of 24,576. A reservation recorded
before the upgrade keeps the hash it was recorded with: the hash is computed and checked only at
funding. No storage, capability or proxy codehash change; the two hooks are upgraded in place.

Tests: `evm/test/SponsoredTaskHookV2.t.sol` and `evm/test/RemoteSponsoredReservedTerms.t.sol`: on
the diamond, a reserved-worker task funded with a hash that leaves the worker out is refused, and
one that names it is funded and reports that hash from `currentTaskTermsHash`.

### 34. A remote reservation is not released while the task has live work (`RemoteSponsoredTaskHookV2`, Cyclops 4403)

**Problem.** The keeper releases a remote reservation that has no settlement once the hook's
`reservationReleaseAfter` has passed: the task's expiry plus `RESERVATION_RELEASE_GRACE` (7 days).
A Bounty or Benchmark stays acceptable after expiry while it has live submissions. Its decision
deadline (`max(expiryTime, decisionStartAt) + decisionWindowSecs`) is configurable and can fall
after that time, and a requester's acceptance is open-ended even past the deadline. A single-payee
delivery under review can likewise be accepted until its review window ends, which can be up to 30
days after delivery. So a reservation could be released on the remote chain and the task then
accepted on the task chain, leaving a completion committed with nothing reserved to pay it.

**Change.** `reservationReleaseAfter` reverts `ReleaseHeldForLiveSubmissions(taskId)` while the
task is not Accepted, Cancelled or Expired and still has live work. For a Bounty or Benchmark, live
work is a submission not rejected (`taskActiveSubmissionCount` is nonzero). For any other mode, it
is a delivery not yet decided (`deliverable` is set). In every other case the time is unchanged:
expiry plus 7 days. Acceptance on the diamond is unchanged. The hold always ends: once the decision
deadline has passed, anyone can call `requesterTimeout`, which expires a Bounty or Benchmark and
commits its release through `afterExpire`. A single-payee delivery ends with an acceptance, a
rejection or `settleLapsedReview`. Until then the sponsor's tokens stay reserved. The rule needs
`taskActiveSubmissionCount`, an existing diamond view, which `ITMPDiamond` now declares.
`RemoteSponsoredTaskHookV2` goes from 23,895 to 24,224 bytes of 24,576. No storage, capability or
selector change; the hook is upgraded in place.

**Rollout.** The backend reads this view in three places, and a revert reaches all three. The
keeper treats a failed read as "not due", so it holds the release with no backend change. The EVM
and Solana reserve jobs read it to bound a reservation's deadline. A task that already has a
submission when its reserve job runs would fail that job. Deploy a backend that handles
`ReleaseHeldForLiveSubmissions` in the reserve jobs before the hook upgrade. On Solana, a
reservation's stored deadline still opens the permissionless `release_expired` once it passes.
Until the backend extends a held reservation's deadline with `extend_deadline` (change 5), a
Solana reservation is not covered by this change.

Tests: `evm/test/RemoteSponsoredReleaseHold.t.sol`, on the diamond. A Bounty with no submissions
reports expiry plus 7 days. One with a live submission refuses 30 days past expiry, and reports
expiry plus 7 days again once accepted. A Bounty whose decision lapses refuses until
`requesterTimeout` expires it and commits the release. A delivered Claim task refuses while its
delivery is undecided.

### 36. A late delivery cannot shorten an evaluator's review window (`WorkerFacet`)

**Problem.** Cyclops 7618. On a Claim, Pitch or Auction task with an evaluator, `submitWork` opens
the evaluation window: `phaseDeadline` is the delivery time plus `evaluationWindow`. Since rev030 a
project task's deadline is held to the project's latest expiry (its end date plus `taskGraceSecs`).
A worker delivering within the last `evaluationWindow` before that point left the evaluator less
than its window, possibly seconds. `evaluate` reverts past the deadline and `evaluatorTimeout` is
permissionless, so anyone could then time the evaluator out and send its stake to the fee
recipient, though the evaluator did nothing wrong. The clamp also undercut the minimum evaluation
window checked when the evaluator was assigned.

**Change.** `submitWork` reverts with `ReviewWindowShortened()` when the project's latest expiry
would end the evaluation window early, so a delivery that goes through always gives the evaluator
its whole window. This is the rule rev030 applied to a reserved worker's delivery period
(`ReservedDeliveryPeriodShortened`): a step is refused rather than run with a window shorter than
the one promised. A worker that cannot deliver in time is in the same position as one that misses
the task's expiry. A task in no project, and a delivery with the whole window left, behave as
before. Only `WorkerFacet` changes; the new error is declared in `ITMPCore`.

### 37. The hook context's actor survives a self-call and a forwarder with no sender (`LibGuards`, `SettlementFacet`, `HookDispatchFacet`)

**Problem.** Cyclops 7635 and 7638. `TaskContextV2.actor` is the caller of the outermost action,
recorded when the action takes the reentrancy lock. `refundExpired` settles a recorded verdict by
calling `finalizeVerdict` on the diamond itself, and that call took the lock with the diamond as its
`msg.sender`, so every hook it dispatched saw the diamond as the actor. Separately, `_actor`
resolves a trusted forwarder to the sender it relays for through `pgtrSender()`, and
`TaskMarketForwarderV2.pgtrSender()` reverts when it relays for the zero address. A permissionless
action (`refundExpired`, `finalizeVerdict`, `evaluatorTimeout`) relayed that way worked on a task
without hooks but reverted on any task whose hooks were dispatched.

**Change.** The lock records the actor only when `msg.sender` is not the diamond, so a self-call
keeps the outer caller. `refundExpired` records its own caller before the self-call, because that
path takes no lock of its own first, and an actor left from an earlier action in the same
transaction must not stand in for it. `_actor` reads `pgtrSender()` with `try`, and a forwarder
that reports no sender gives the zero address. No other self-call into the diamond takes the
lock: `hookCall`, `hookReadManifest`, `drawTopUp` and `refundProjectTask` run inside an action
that already holds it. `LibGuards` is inlined into every facet that takes the lock, so all of them
have new bytecode and are cut again.

### 38. `onCall` is budgeted under its own capability bit (`HookDispatchFacet`)

**Problem.** Cyclops 7636 and Cantina TASK-302. A before-callback's gas budget is
`hookCapabilityGas[bit]` for the callback's capability bit, and for the vetoable actions that bit
equals the action id. `hookCall` passed `onCall`'s action id, 22, which is `BIT_AFTER_CANCEL`, so
`onCall` ran on the `afterCancel` budget. `BIT_HOOK_CALL` (30), the bit that authorizes `onCall`
and that relays price `callTaskHook` by, was never read. An owner who set the two budgets
differently would see `callTaskHook` priced on one and run on the other.

**Change.** `_callBefore` takes the budget bit separately from the action id. `hookCall` passes
`BIT_HOOK_CALL`; every before-callback passes its action id, as before. `HookRejected` still reports
action 22. A chain that never set `hookCapabilityGas[22]` or `[30]` sees no change: both read as the
stipend default. A chain that set `[22]` for `afterCancel` stops giving that budget to `onCall`,
which gets `[30]` (or the default) instead.

### 39. The appeal window floor stays under the terms ceiling (`AdminFacet`)

**Problem.** Cyclops 7641. `setMinAppealWindowSecs` refused only zero. Every evaluator's appeal
window must be at least that floor and at most the terms bounds' `maxWindowSecs`, so a floor above
the ceiling refused every evaluator configuration until the owner noticed. `setTermsBounds` could
make the same state from the other side by lowering the ceiling under the floor.

**Change.** `setMinAppealWindowSecs` also refuses a value above the effective `maxWindowSecs`
(`InvalidMinAppealWindow`), and `setTermsBounds` refuses a `maxWindowSecs` below the effective
appeal window floor (`InvalidTermsBounds`). This is the rule the evaluation window floor already
follows on both setters. No error or selector is added.

### 40. A default hook is checked for a delegation at attach (`HookDispatchFacet`)

**Problem.** Cyclops 7664. Since rev030, an address whose code is an EIP-7702 delegation designator
(`0xef0100 || address`) is never a hook: its key holder can re-point it at will. The check runs
when a hook is inspected, which is when a requester attaches one and when the owner sets the
defaults. At task creation `hookAttach` copies each default and compares only its pinned codehash.
A default set before rev030 was never inspected for a designator, so its pinned codehash can be a
designator's, and the comparison then passes.

**Change.** `hookAttach` refuses such a default with `HookDelegatedAccount(index)`, through the same
private check `inspect` uses. While a delegated default stays set, no task can be created on that
chain, so the rollout reads each chain's defaults before the cut.

### 41. Default hooks cannot make every task creation revert (`HooksV2Facet`)

**Problem.** Cyclops 7649. `setDefaultHooksV2` inspects each default (code, no delegation
designator, the V2 interface and manifest, the diamond version) and refuses duplicates and a second
transforming hook. Since rev030, `hookAttach` keeps any task with a transforming hook free of appeal
vetoes: it reverts `TransformingHookWithAppealHook` when a hook on the task declares the appeal bit
(12). Defaults are attached to every task, so a transforming default next to a default declaring
bit 12, or a transforming default that declares it itself, made every task creation on the chain
revert until the owner changed the defaults.

**Change.** `setDefaultHooksV2` refuses that list with `TransformingHookWithAppealHook`, the error
task creation would have raised. A transforming default is still allowed. Its consequences are the
ones a requester-attached transformer already has: an evaluator task on that chain must name a
dispute resolver (`TransformingHookNeedsDisputeResolver`), and a requester cannot attach a second
transformer or a hook declaring bit 12. Those refuse only the tasks that ask for them, not every
task, so they stay checks at creation. A default with code or a manifest that no longer passes
inspection was already refused when the defaults were set. One that changes its code later fails
with `HookCodeChanged` at creation, and the owner then replaces it. No error or selector is added.

## What is cut, upgraded in place and redeployed

| Component                                          | Rev031                                                                 |
| -------------------------------------------------- | ---------------------------------------------------------------------- |
| Diamond facets                                     | Eleven Replaced by `Rev031Upgrade` (changes 13 to 41); version 31      |
| `ProjectFacet.grantOperator`                       | Terms-only selector Removed, the form with limits Added (change 26)    |
| `SponsoredTaskHookV2`, `RemoteSponsoredTaskHookV2` | Upgraded in place through their UUPS proxies (3, 4, 6, 9, 33, 34)      |
| `SponsoredTasksVaultV2`                            | New implementation, cloned by a new `SponsoredTaskFactoryV2` (2, 11)   |
| `TaskTokenRewardHookV2`                            | Built; deployment deferred to a later release (changes 10, 12, 31)     |
| `EpochBudget`                                      | Built; redeploy deferred to a later release (change 25)                |
| `SponsoredTaskSettler`                             | New settler per remote chain (8, 11); the old one keeps its vaults     |
| Settler-mode `SponsoredTaskFactoryV2`              | New factory per remote chain, controlled by the new settler (change 8) |
| Registry, fee policy                               | Unchanged; the old settler-mode factory is deauthorized (change 8)     |
| Solana Sponsored Tasks program                     | Redeployed (changes 1, 2, 5)                                           |
| `PayoutGateHook`                                   | Redeployed at a new address (change 7)                                 |
| Settler service, indexer decoders, relay, CLI      | Changed off chain (changes 3, 5, 8, 9, 11)                             |

Vaults are clones of a fixed implementation that no one can upgrade. A vault created before the
rollout keeps its code for its lifetime: it has no `sweepExited`, and its exit records the amount
before a fee. Only vaults cloned by the new factory get change 2. A hook-mode chain's old factory
stays authorized in the registry. A remote chain's old settler-mode factory is deauthorized
(change 8), which stops it creating vaults but leaves its vaults registered, so they keep working
with the old settler. The new implementation reports `VAULT_VERSION` 3 and its factory
`IMPLEMENTATION_VERSION` 3 (change 11), so clients tell rev031 vaults from earlier ones by version.

## Storage and layout

- `AppStorage`: unchanged.
- `PayoutGateHook`: no new state; the new deployment starts empty.
- `SponsoredTaskHookV2` and `RemoteSponsoredTaskHookV2`: no storage, capability or proxy codehash
  change. The new private function and library helper add no state. The only ABI change is the
  event `SponsoredTaskDefaultedByRequester` (change 9).
- `TaskTokenRewardHookV2`: one field appended to the end of its fixed-slot `HookStorage`,
  `zeroAgeShareBpsPlusOne` (the share plus one); nothing is inserted or reordered. It starts at
  zero, which reads as the default share, so the upgrade needs no initializer (change 10).
- `SponsoredTasksVaultV2`: appended state only. Change 2 adds none (new function `sweepExited`,
  event `ExitedVaultSwept`, error `VaultNotExited`). Change 11 appends two mappings after
  `ownerNonce`: the manager accounts keyed by task chain and each allocation's task chain. The
  address-keyed manager mapping stays in place, unused, so no slot moves. Only new clones use this
  implementation, so no deployed vault's storage is reinterpreted.
- `SponsoredTaskSettler`: a new deployment, so no layout carries over. Its storage is unchanged;
  `deadline` lives only in the calldata struct and is not stored.
- Solana: no account layout change. New instructions `sweep_exited` and `extend_deadline`, events
  `ExitedVaultSwept` and `ReservationDeadlineExtended`, error `VaultNotExited`. The program is not
  deployed on any cluster yet, so it is deployed fresh as in rev030.

## API changes

- Changed (diamond, change 26): `grantOperator(uint256,address,(uint256,uint8,bool,bool))`
  (`0xd2249c39`) is Removed and
  `grantOperator(uint256,address,(uint256,uint8,bool,bool),(uint64,uint32,uint128,uint64,uint128))`
  (`0x301cd8aa`) Added; `acceptGrant` takes the hash of the terms and the limits. No other diamond
  selector is added, removed or changed.
- New errors (diamond): `ReviewWindowShortened()` (change 36), `ReputationRegistryHasNoCode()`
  (change 27), `PriceZero()` (change 28). New hook failure class 6, code changed (change 30).
- New error (`RemoteSponsoredTaskHookV2`): `ReleaseHeldForLiveSubmissions(bytes32)` (change 34).
- New (EVM vault): `sweepExited(address) returns (uint256)`, `ExitedVaultSwept(bytes32 indexed, address indexed, address indexed, uint256)`, `VaultNotExited()`.
- Changed behaviour (EVM vault): `emergencyExitVault` and `emergencyExitVaultBySig` return, record
  and emit the amount the recipient received.
- Changed behaviour (EVM hooks): `MAX_AWARDS` counts paying awards; `SponsoredTaskUnsettleableAwardCount`
  reports that count. `SponsoredTaskHookV2.afterForfeit` releases when the task is `Expired`.
- Changed (EVM settler, new deployment): `ReserveRequest` and `RESERVE_TYPEHASH` gain
  `uint64 deadline`, so `reserve`'s selector changes; new error `ReserveExpired(uint64)`. Events,
  `release`, `settle` and `finalize` are unchanged.
- New (EVM hooks): `SponsoredTaskDefaultedByRequester(bytes32 indexed taskId, bytes32 indexed allocationId, address indexed requester)` on both V2 hooks (change 9).
- New (`TaskTokenRewardHookV2`): `setZeroAgeReserveShareBps(uint16)`,
  `zeroAgeReserveShareBps() returns (uint16)`, `DEFAULT_ZERO_AGE_RESERVE_SHARE_BPS()`. Changed
  behaviour: a zero-multiplier reservation past the share reserves nothing (change 10); a
  Bounty or Benchmark winner whose multiplier and the requester's are both zero is paid nothing and
  spends no budget (change 12).
- New (EVM vault, change 11): `configureManagerForChain`, `configureManagerForChainBySig`,
  `reserveTaskForChain` (also on `ISponsoredTasksVault`), `managerAccountForChain`,
  `managerRemainingForChain`, `CONFIGURE_MANAGER_FOR_CHAIN_TYPEHASH`, `ManagerConfiguredForChain`,
  `TaskChainRequired`. Changed behaviour: the unscoped manager functions act on `block.chainid`;
  `VAULT_VERSION` and `IMPLEMENTATION_VERSION` are 3. Changed (EVM settler): `reserve` calls
  `reserveTaskForChain`.
- New (Solana): `sweep_exited`, `extend_deadline(new_deadline: i64)`, events `ExitedVaultSwept`,
  `ReservationDeadlineExtended`, error `VaultNotExited`.
- Changed behaviour (Solana): `bind_payout_attested` promotes an effective pending payout first.

## Upgrade

`Rev031Upgrade` requires a diamond at revision 30 (at 31 it sends no cut). It pauses the diamond,
sends the cut, sets the version to 31 and unpauses (`FORGE_KEEP_PAUSED=true` leaves it paused). A
fresh deploy stamps 31 (`LibRevision.CURRENT_REVISION`).

The cut Replaces `AcceptanceFacet`, `AdminFacet`, `AuctionFacet`, `CoreFacet`, `EvaluatorFacet`,
`HookDispatchFacet`, `HooksV2Facet`, `ProjectFacet`, `RatingFacet`, `SettlementFacet` and
`WorkerFacet` with the selectors a rev030 diamond routes to them; `RegistryFacet`, `FeedbackFacet`,
`DiamondCutFacet` and `DiamondLoupeFacet` are unchanged. It Adds the `grantOperator` that takes
limits to the new `ProjectFacet` and Removes the terms-only one (change 26). When the diamond routes
the zero selector (`facetAddress(0x00000000)` is nonzero, from an Add of a list with an unset
entry), the cut also Removes it, so a call with no selector no longer reaches a facet; the script
reads this from the loupe (`cut(removeZero)`). On Tempo (4217, 42431) each entry goes out as its
own transaction, as in rev030. A rerun skips what landed.

```sh
DRY_RUN=1 make upgrade <84532|42431|8453|4217> rev031
make upgrade <84532|42431|8453|4217> rev031
```

Before the cut, on each chain: the backend release that carries the rev031 grant changes is live
(change 26); `hookCapabilityGas(22)` and `hookCapabilityGas(30)` are read, and slot 30 is set to
slot 22's value where 22 was raised (change 38); `getDefaultHooksV2()` holds no EIP-7702
designator and no list change 41 refuses (changes 40, 41); `reputationRegistry()` is zero or has
code (change 27); on Tempo `maxSubmissionWinners()` is 30 (change 24).

The rest of the rollout, in order, once the diamond is at 31:

1. Deploy the backend whose EVM and Solana reserve jobs handle `ReleaseHeldForLiveSubmissions`
   (change 34) and whose terms hash wraps a reserved worker (change 33), then upgrade the Sponsored
   Task V2 hooks in place, wherever they are deployed:
   `DeployHooksV2.s.sol:UpgradeSponsoredTaskHookV2` with `FORGE_SPONSORED_TASK_HOOK_V2_ADDRESS`, and
   `UpgradeRemoteSponsoredTaskHookV2` with `FORGE_SPONSORED_TASK_REMOTE_HOOK_V2_ADDRESS`. When the key
   does not own the hook (a Safe does), each deploys the implementation and prints the
   `upgradeToAndCall` call for the owner.
2. For each live hook-mode vault factory (Base and Tempo), deploy its successor:
   `DeployHooksV2.s.sol:RedeploySponsoredTaskFactoryV2` with
   `FORGE_SPONSORED_TASK_PREVIOUS_FACTORY`. It copies the controller, fee policy, registry and
   creation fee, and authorizes the new factory in the registry, or prints the `setFactory` call for
   the registry owner. It refuses a settler-mode factory whose settler signs the old `Reserve`:
   remote chains' settler-mode factories are replaced in step 6. Then point the app's chain
   registry at the new factory addresses.
3. Deploy the backend whose settler service counts paying awards (change 3) before the hook upgrade
   reaches a remote task with padded awards, so the service and the remote hook agree.
4. Deploy the Solana Sponsored Tasks program fresh, with its cluster id, when it goes live.
5. Redeploy `PayoutGateHook` on each chain it is live on (`make deploy-payout-gate-hook <chain>`),
   then repoint `PAYOUT_GATE_HOOK_ADDRESS_<chainId>` and add the hook registry manifest for the new
   address (change 7). It needs no diamond change, so it may run before or after the version step.
6. On each remote chain (Robinhood Chain), replace the settler-mode pair (change 8):
   `DeploySponsoredTaskSettler.s.sol:RedeploySponsoredTaskSettler` with
   `FORGE_SPONSORED_TASK_PREVIOUS_FACTORY` set to the live settler-mode factory. It deploys the new
   settler, with the old one's owner, settler set, threshold and registry, and a new factory
   controlled by it, then authorizes the new factory and deauthorizes the old one, or prints both
   `setFactory` calls for the registry owner. The old settler's claim delay and any authority are
   the owner's to set again on the new settler (the script prints what differs). Then point the
   app's chain registry at the new pair, recording the replaced one as `settlerMode.previous`, and
   in the same backend release set `SPONSORED_TASK_SETTLER_ADDRESS_<chainId>` to the new settler and
   `SPONSORED_TASK_SETTLER_PREVIOUS_ADDRESS_<chainId>` to the old one (and, where the indexer is
   configured by environment, `SPONSORED_TASK_SETTLER_PREVIOUS_FACTORY_ADDRESS_<chainId>`), so
   reserves for old vaults keep going to the old settler. The web vault page must be able to set a
   per-chain manager allowance (change 11) before the new factory goes live: until then it sets
   only the vault's own-chain allowance, which no task can spend on a Robinhood vault, so owners
   of a new Robinhood vault set managers with the CLI until the web form ships.

Not in this rollout: `TaskTokenRewardHookV2` (changes 10, 12, 31) stays on its rev030
implementation, and the live `EpochBudget` stays in place (change 25, `RedeployEpochBudget`). Until
the new budget is live, its owner must not raise the epoch duration after an epoch has lapsed
unrolled.

## Tests

- `evm/test/SponsoredTasksVaultTokenLockout.t.sol`: the exit records what arrived; tokens sent after
  the exit are swept by the owner only; the sweep refuses an active vault (change 2).
- `evm/test/SponsoredTaskHookV2Suite.t.sol`, `RemoteSponsoredTaskHookV2Suite.t.sol`: zero-amount
  padding no longer releases; nine paying awards still do; a 50-entry verdict stays inside the
  stipend (change 3).
- `evm/test/SponsoredTaskHookV2.t.sol`: on the diamond, a rejected delivery with a refund outcome
  releases the reservation and restores the manager's cap in the same call (change 4).
- `evm/test/SponsoredTaskHookV2.t.sol`, `SponsoredTaskHookV2Suite.t.sol`,
  `RemoteSponsoredTaskHookV2Suite.t.sol`: nine paying awards from `acceptSubmissions` on the
  diamond release the sponsorship and record `SponsoredTaskDefaultedByRequester`; an evaluator's
  oversized verdict records none (change 9).
- `evm/test/TaskTokenRewardHookV2Suite.t.sol`: fresh pairs cannot hold more than the zero-age
  share of the epoch budget and an earning pair still reserves; a release frees the share; the
  owner sets the share, an explicit 0 is kept, and 10000 lifts it; payout-age crediting is
  unchanged (change 10); a zero-age Bounty winner spends no budget and moves no vault tokens, and
  an aged winner is still paid from the budget (change 12).
- `apps/backend/test/unit/routers/requester.test.ts`, `test/unit/config/indexer-abi-drift.test.ts`:
  the requester's `sponsoredTaskDefaultCount`, and the indexed event matches both generated V2 ABIs
  (change 9).
- `evm/test/Rev031Upgrade.t.sol`: on a rev030 diamond every changed facet's selectors reach new
  bytecode, the unchanged facets keep their routes, the terms-only `grantOperator` is Removed and
  the form with limits Added, a routed zero selector is Removed, the Tempo split cut lands the same
  routing with each entry far under the transaction cap, a rerun sends no cut, and only a rev030
  diamond takes the step. `DiamondSelectorParity.t.sol` runs the step in the full sequence and checks
  the fresh-deploy version; `FacetSelectors.t.sol` checks the rev031 lists and the two
  `grantOperator` selectors.
- `evm/test/DeployHooksV2Scripts.t.sol`: the factory redeploy copies the live factory and leaves it
  authorized.
- `evm/test/SponsoredTaskSettler.t.sol`: a stale reserve signature is refused with
  `ReserveExpired`; a reserve lands at its deadline and not one second after; the deadline is
  signed; the typehash carries it (change 8).
- `evm/test/SponsoredTasksVaultTaskChain.t.sol`: an allowance for one task chain is not spent by
  another; each chain has its own cap; release and settlement charge the reserved chain; the
  unscoped entry points act on `block.chainid`; the signed form shares the owner nonce and signs
  the chain; a rev031 vault reports version 3 and takes the v2 signed actions; a zero chain and a
  non-controller are refused (change 11). `SponsoredTaskSettler.t.sol` reproduces the cross-chain
  spend through the settler; `SponsoredTaskFactoryV2.t.sol` and `SponsoredTasksVaultV2.t.sol`
  check version 3.
- `evm/test/SponsoredTaskSettlerDeployScripts.t.sol`: the settler redeploy copies the live settler,
  controls the new factory with it, deauthorizes the old factory and keeps its vaults registered,
  or leaves both calls to the registry owner; the factory redeploy refuses a settler with the old
  `Reserve` (change 8).
- `solana/programs/sponsored-tasks/tests/payout.rs`: a second attestation keeps paying the first
  until it takes effect; one that never took effect is replaced (change 1).
- `solana/programs/sponsored-tasks/tests/vault.rs`: `sweep_exited` (change 2); `extend_deadline`
  and the reservation that cannot be reserved again (change 5).
- `apps/backend/test/unit/sponsored-task-settler-award-count.test.ts`: the settler service's paying
  count (change 3).
- `apps/backend/test/integration/settler-service.test.ts`: a signed reserve's deadline, a reserve
  that expires unlanded re-signed (and skipped once its task ended), and the previous settler
  signing its own vaults' `Reserve` without a deadline (change 8);
  `settler-chain-vault-indexer.test.ts`, `unit/services/settler-signers.test.ts`,
  `unit/services/evm-settler-config.test.ts` and `unit/config/chains.test.ts` cover the rest.
- Change 11: `apps/backend/test/integration/settler-chain-vault-indexer.test.ts` (a version-3
  remote vault's manager rows per task chain),
  `unit/services/contract-preview-sponsored-task-funding.test.ts` (a version-3 remote vault
  previewed for the task's chain), `unit/lib/sponsored-vault-relay.test.ts` and
  `sponsored-vault-signed.test.ts` (the new owner actions relayed), and
  `apps/cli/test/unit/sponsored-task-managers.test.ts` (`--manager-chain-id`).
- Smoke: `make smoke sponsored-task` sweeps an exited vault; `make smoke sponsored-solana` sweeps an
  exited vault and extends a reservation deadline (local stacks only). The `sponsored-robinhood` smoke signs every reserve with a deadline
  and asserts `ReserveExpired` for one relayed past it (change 8), configures its vaults with
  `configureManagerForChain`, checks they report version 3, and asserts `ManagerNotActive` for a
  reserve from another task chain (change 11).

## Affected files

| File (under `packages/contracts/` unless noted)                                                                                                                                                      | Change                                                          |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `solana/programs/sponsored-tasks/src/lib.rs`, `events.rs`, `error.rs`                                                                                                                                | Payout promotion (1), `sweep_exited` (2), `extend_deadline` (5) |
| `solana/idl/sponsored_tasks.json`, `packages/solana-sponsored-client` (repo root)                                                                                                                    | Regenerated                                                     |
| `evm/src/hooks/sponsored-task/SponsoredTasksVaultV2.sol`                                                                                                                                             | `sweepExited`, received amount (2)                              |
| `evm/src/hooks/sponsored-task/libraries/SponsoredTaskSettlement.sol`                                                                                                                                 | `payingAwardCount` (3)                                          |
| `evm/src/hooks/sponsored-task/SponsoredTaskHookV2.sol`                                                                                                                                               | Paying count (3), forfeit release (4), size (6), default (9)    |
| `evm/src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol`                                                                                                                                         | Paying count (3), requester default (9)                         |
| `evm/abi/SponsoredTaskHookV2.json`, `evm/abi/RemoteSponsoredTaskHookV2.json` and their `generated/` bindings                                                                                         | Regenerated (9)                                                 |
| `apps/backend/src/services/indexer.ts`, `indexer-abi-events.ts`, `routers/requester.router.ts` (repo root)                                                                                           | Requester default indexed and counted (9)                       |
| `evm/src/hooks/TaskTokenRewardHookV2.sol`                                                                                                                                                            | Zero-age reservation share (10), zero-age Bounty payout (12)    |
| `evm/abi/TaskTokenRewardHookV2.json`, `evm/abi/generated/TaskTokenRewardHookV2.ts`                                                                                                                   | Regenerated (10)                                                |
| `evm/src/libraries/LibRevision.sol`                                                                                                                                                                  | `CURRENT_REVISION` 31                                           |
| `evm/script/upgrades/Rev031Upgrade.s.sol`, `evm/script/lib/FacetSelectors.sol`                                                                                                                       | Facet cut, zero selector, version step                          |
| `evm/script/DeployHooksV2.s.sol`                                                                                                                                                                     | `RedeploySponsoredTaskFactoryV2`                                |
| `evm/src/hooks/sponsored-task/SponsoredTaskSettler.sol`                                                                                                                                              | `Reserve` deadline, `ReserveExpired` (8)                        |
| `evm/script/DeploySponsoredTaskSettler.s.sol`                                                                                                                                                        | `RedeploySponsoredTaskSettler` (8)                              |
| `docs/specs/sponsored-tasks/evm-attested-settler.md`                                                                                                                                                 | The deadline and its reasoning (8)                              |
| `apps/backend/src/services/evm-settler.ts`, `lib/sponsored-task-settler-typed-data.ts`, `settler-chain-vault-indexer.ts` (repo root)                                                                 | Deadline, expiry and re-sign, the previous settler (8)          |
| `evm/abi/SponsoredTasksVaultV2.json`, `evm/abi/generated/SponsoredTasksVaultV2.ts`                                                                                                                   | Regenerated                                                     |
| `evm/src/hooks/sponsored-task/SponsoredTasksVaultV2.sol`, `SponsoredTaskFactoryV2.sol`, `interfaces/ISponsoredTasksVault.sol`                                                                        | Per-chain allowances, version 3 (11)                            |
| `docs/specs/sponsored-tasks/signed-vault-actions-and-signed-funding.md`                                                                                                                              | Per-chain allowances and their reasoning (11)                   |
| `apps/backend/src/lib/sponsored-vault-relay.ts`, `sponsored-vault-signed.ts`, `services/contract.ts`, `sponsored-task-projection.ts`, `apps/cli/src/commands/sponsored-task/managers.ts` (repo root) | Relay, preview, indexer, CLI (11)                               |
| `docs/specs/sponsored-tasks/*.md`, `docs/extensions/ext-003-sponsored-task-hook.md`, `solana/README.md`                                                                                              | Reasoning for each change                                       |
| `apps/backend/src/services/sponsored-task-settler.ts`, `indexer-abi-events.ts`, `lib/solana/sponsored-task-events.ts` (repo root)                                                                    | Paying count (3), new events decoded and not projected          |
