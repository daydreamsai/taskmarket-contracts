# ERC-8195 Revision 017 — Evaluator Award Recipients and Bounded Hook Calls

## Motivation

A security scan of `packages/contracts` produced two independently-confirmed HIGH findings (issues
#316 and #317, 3/3 panel votes each) against code paths that move escrowed USDC. Both are escrow
integrity bugs, and both are reachable by the requester — the party who funds the escrow and
therefore the party the escrow exists to constrain.

The first is a missing authorization check: `EvaluatorFacet` decided *how much* each award was
worth but never *who was entitled to it*, so a caller-supplied `awards` array could redirect a
worker's payout to an arbitrary address. The second is a denial-of-service primitive: every hook
call used a plain low-level `.call()`, whose mandatory return-data copy a requester-deployed hook
could make arbitrarily expensive — including on `refundExpired`, the permissionless escape hatch
whose own source comment declares that `onExpire` MUST NOT block fund recovery.

This revision closes both. Because the second fix lives in `LibTaskMarket`, an `internal` library
that Solidity inlines into its callers, the deployable unit is four facets, not one — see
`script/upgrades/Rev017Upgrade.s.sol`.

---

## Problem 1 — evaluator awards are never validated against the task's real worker (#316)

`EvaluatorFacet.evaluate()` accepted an `awards` array from the assigned evaluator and stored it
verbatim into `s.taskVerdicts[taskId].awards`. `resolveDispute()` did the same for the dispute
resolver. The accounting path that eventually spends it — `_payAwards` → `_commitEvalAccounting`
→ `_distributeEvalAwards` — bounded only the *sum* of `awards[].amount` against the escrowed
reward. Nothing anywhere checked that `awards[i].worker` was the task's locked worker (Claim,
Pitch, Auction) or an address that had actually submitted work (Bounty, Benchmark).

The non-evaluator settlement path already enforced exactly that check:
`AcceptanceFacet._validateAcceptSubmission`/`_resolveDeliverables` reject a `worker` that is
neither `task.worker` nor present in `s.taskSubmissionHashExists`. The evaluator path's omission
was therefore a missing check, not a deliberate widening of who may be paid.

Two adjacent gaps in `assignEvaluator` turned this from "a rogue evaluator can misdirect a
payout" into "a requester can drain their own escrow past the worker who earned it":

- Nothing rejected `evaluator == requester` or `disputeResolver == requester`, so the requester
  could appoint themselves (or a colluding address) to both roles.
- `appealWindowSecs` was unrestricted, including `0`. `appeal()` is gated on
  `block.timestamp < s.phaseDeadline[taskId]`, and a zero-length window makes that deadline equal
  the block timestamp at which `evaluate()` mined — so the worker's only on-chain recourse
  reverted `AppealWindowClosed` from the moment the adverse verdict existed.

Observable exploit chain, entirely within a single requester's control:

1. Requester creates a Claim task and escrows `reward` USDC.
2. While Open, requester calls `assignEvaluator(taskId, evaluator=<own address B>, stakeAmount=0,
   feeBps=0, evaluationWindowSecs=X, appealWindowSecs=0, disputeResolver=<own address B>)`.
3. A real worker claims and submits genuine work; the task moves to Review.
4. Requester, now acting as `evaluatorAddr`, calls `evaluate(..., awards=[{worker: <own address
   C>, amount: reward, rank: 1}])`. No check rejects address C.
5. The appeal window is already closed, so the worker's `appeal()` reverts.
6. Anyone calls `finalizeVerdict(taskId)`; `_distributeEvalAwards` pays the full reward to
   address C. The worker who did the work is paid nothing and has no recourse.

## Problem 2 — an oversized hook return blob can force an out-of-gas in the caller (#317)

`s.taskHooks[taskId]` holds requester-chosen, requester-deployable contract addresses, validated
at `createTask` (`CoreFacet._buildAndCheckHooks`) only for non-zero address, non-empty code, and
no duplicates — never for trustworthiness or return-data size. Every dispatch site used a plain
low-level call:

```solidity
(bool ok, bytes memory ret) = hooks[i].call(callData);   // _dispatchCheckHooks, _checkFundHooks
(bool ok,) = hooks[i].call(callData);                    // _dispatchAfterHooks
```

Solidity compiles `.call()` into a `CALL` followed by an unconditional `RETURNDATACOPY` of the
callee's entire return blob, because that copy is how the `(bool, bytes memory)` tuple is
constructed — it happens even in the `(bool ok,)` form where the bytes value is immediately
discarded. Memory expansion is quadratic in size, so a hook returning a multi-hundred-kilobyte
blob imposes an arbitrarily large, unavoidable cost on the *caller's* frame, independent of the
boolean it nominally encodes.

**After-hooks (HIGH).** `_dispatchAfterHooks` runs as the last step of functions that have
already moved real USDC in the same transaction: `CoreFacet.refundExpired` (via
`_refundExpiredNormal`), `CoreFacet.cancelTask`, `CoreFacet.forfeitAndReopen`, and
`EvaluatorFacet._payAwards`. Transactions are atomic, so an out-of-gas in the hook-dispatch step
rolls back every transfer that already succeeded. A requester who registers a hook whose
`onExpire` returns an oversized blob makes `refundExpired` revert forever, permanently freezing
the escrowed reward and any worker stake tied to the task — with no alternative recovery path,
and in direct contradiction of `_onExpireHooks`' own normative comment.

**Check-hooks (MEDIUM).** `_dispatchCheckHooks` backs `checkClaim`/`checkSelectWorker`/
`checkSubmit`/`checkEvaluate`/`checkComplete`. Here escrow is not frozen (`refundExpired` skips
check-hooks entirely), but every worker or evaluator who touches the task burns excess gas or
hits an out-of-gas on a call whose hook they do not control — and since the backend's
`SERVER_PRIVATE_KEY` relays and pays gas for these calls through the forwarder, the platform's
own relayer absorbs the waste.

---

## Changes

### 1a. `EvaluatorFacet` — validate every award recipient (#316)

A shared private helper is called by both `evaluate()` and `resolveDispute()` before their
`awards` arrays are committed to storage.

```solidity
// Before -- evaluate(), after the status checks
ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
v.issued = true;

// Before -- resolveDispute(), after the awards-length check
if (awards.length == 0) revert ITMPCore.AwardsRequired();
ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
```

```solidity
// After -- evaluate()
_validateAwardRecipients(task, taskId, awards, s);

ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
v.issued = true;

// After -- resolveDispute()
if (awards.length == 0) revert ITMPCore.AwardsRequired();
_validateAwardRecipients(task, taskId, awards, s);
ITMPCore.Verdict storage v = s.taskVerdicts[taskId];
```

```solidity
// After -- new helper
function _validateAwardRecipients(
    ITMPCore.Task storage task,
    bytes32 taskId,
    ITMPCore.Award[] calldata awards,
    AppStorage storage s
) private view {
    bool bountyLike = task.mode == BOUNTY || task.mode == BENCHMARK;
    for (uint256 i; i < awards.length; ++i) {
        if (awards[i].amount == 0) continue;
        address worker = awards[i].worker;
        if (worker == address(0)) continue;
        if (bountyLike) {
            if (s.taskSubmissionHashes[taskId][worker].length == 0) revert ITMPCore.SubmissionNotFound();
        } else if (worker != task.worker) {
            revert ITMPCore.WorkerMismatch();
        }
    }
}
```

Zero-amount and zero-address awards are skipped: neither triggers a transfer nor writes
`task.worker`, so their recipient field is inert and rejecting them would break existing
empty/placeholder-award verdicts for no security benefit.

### 1b. `EvaluatorFacet.assignEvaluator` — self-assignment and appeal-window floor (#316)

```solidity
// Before
if (evaluator == address(0)) revert ITMPCore.InvalidEvaluator();
if (evalCfg.evaluator != address(0)) revert ITMPCore.EvaluatorAlreadyAssigned();
if (feeBps > 10000) revert ITMPCore.FeeBpsTooHigh();
```

```solidity
// After
if (evaluator == address(0)) revert ITMPCore.InvalidEvaluator();
if (evaluator == requester) revert ITMPCore.EvaluatorCannotBeRequester();
if (disputeResolver == requester) revert ITMPCore.DisputeResolverCannotBeRequester();
if (evalCfg.evaluator != address(0)) revert ITMPCore.EvaluatorAlreadyAssigned();
if (feeBps > 10000) revert ITMPCore.FeeBpsTooHigh();
if (appealWindowSecs < LibTaskMarket._minAppealWindowSecs(s)) revert ITMPCore.AppealWindowTooShort();
```

The floor itself is stored state, not a compiled-in constant. `AppStorage` gains one appended
field, `AdminFacet` gains an owner-guarded setter and a getter, and reads go through a shared
accessor that substitutes the default for an unset slot:

```solidity
// After -- AppStorage, appended to the end of the struct
uint32 minAppealWindowSecs;

// After -- LibTaskMarket
uint32 internal constant DEFAULT_MIN_APPEAL_WINDOW_SECS = 5 minutes;

function _minAppealWindowSecs(AppStorage storage s) internal view returns (uint32) {
    uint32 configured = s.minAppealWindowSecs;
    return configured == 0 ? DEFAULT_MIN_APPEAL_WINDOW_SECS : configured;
}

// After -- AdminFacet
function minAppealWindowSecs() external view returns (uint32) {
    return LibTaskMarket._minAppealWindowSecs(LibAppStorage.appStorage());
}

function setMinAppealWindowSecs(uint32 newMinimum) external onlyOwner {
    if (newMinimum == 0) revert ITMPCore.InvalidMinAppealWindow();
    LibAppStorage.appStorage().minAppealWindowSecs = newMinimum;
    emit ITMPCore.MinAppealWindowUpdated(newMinimum);
}
```

The lazy default is the load-bearing detail. A newly appended `AppStorage` field zero-initialises
on every diamond upgraded into rev017, and a zero minimum is precisely the hole the guard exists
to close -- so zero is read as "never set" and the compiled default is substituted, making the
guard live from the moment the cut lands rather than from the first time someone remembers to
call the setter. `setMinAppealWindowSecs` rejects zero for the same reason: it keeps "unset" and
"deliberately zero" from becoming indistinguishable in storage.

An admin-settable minimum is also an admin-defeatable one. Whoever holds the owner key can set
the floor to one second and restore the original exploit precondition. That is the normal trade
for a tunable protocol parameter and it is the right one here, but it is worth saying plainly
rather than leaving a reader to infer it: this guard constrains requesters, not the protocol
owner. `MinAppealWindowUpdated` is emitted on every change so that exercising the power is at
least a matter of public record.

### 2. `LibTaskMarket` — bounded hook calls (#317)

```solidity
// Before -- three dispatch sites
(bool ok, bytes memory ret) = hooks[i].call(callData);   // _dispatchCheckHooks
(bool ok,) = hooks[i].call(callData);                    // _dispatchAfterHooks
(bool ok, bytes memory ret) = hooks[i].call(callData);   // _checkFundHooks
```

```solidity
// After -- all three route through one helper
(bool ok, bytes memory ret) = _safeHookCall(hooks[i], callData);
(bool ok,) = _safeHookCall(hooks[i], callData);
(bool ok, bytes memory ret) = _safeHookCall(hooks[i], callData);

uint256 internal constant HOOK_MAX_RETURN_BYTES = 32;
uint256 internal constant HOOK_GAS_STIPEND = 1_000_000;

function _safeHookCall(address hook, bytes memory callData) private returns (bool ok, bytes memory ret) {
    uint256 maxCopy = HOOK_MAX_RETURN_BYTES;
    uint256 gasStipend = HOOK_GAS_STIPEND;
    ret = new bytes(maxCopy);
    assembly {
        ok := call(gasStipend, hook, 0, add(callData, 0x20), mload(callData), 0, 0)
        let copyLen := returndatasize()
        if gt(copyLen, maxCopy) { copyLen := maxCopy }
        returndatacopy(add(ret, 0x20), 0, copyLen)
        mstore(ret, copyLen)
    }
}
```

The 32-byte cap is the load-bearing guarantee: `ITMPHook`'s `check*` functions return exactly one
`bool` and its `on*` functions return nothing, so anything beyond one word is already an attacker
signal rather than a response worth preserving. The gas stipend is a second, independent guard
covering plain compute/loop griefing, sized against the real production hook —
`TaskTokenRewardHook.checkClaim`/`checkComplete` cold-write several storage slots and make two
further nested external calls into `EpochBudget`/`RewardVault`, each with their own cold writes.
An initial 100,000 stipend was caught by the existing `TaskTokenRewardHook` suite as too tight
before landing on 1,000,000, which is still a hard fixed cap far below a full transaction's
budget.

The stipend is a new consensus-visible constraint on hook contracts, which would ordinarily
require auditing every registered hook for one that needs more gas than the cap allows. It is
safe here for a specific reason worth recording: `TaskTokenRewardHook` is the only hook deployed
against this protocol, and it is the hook the figure was calibrated against. The same change
against a populated hook ecosystem would need that audit first, and could not ship as a silent
tightening.

---

## Rationale

### Why not validate award recipients inside `_distributeEvalAwards` instead of at verdict time?

`_distributeEvalAwards` runs during `finalizeVerdict`/`resolveDispute` settlement, long after the
verdict was written to storage. Rejecting there would mean the invalid verdict is accepted,
`appeal()`'s window runs against it, and the failure surfaces only when someone tries to settle —
by which point the task is wedged in a state no caller can move forward. Validating at the point
the `awards` array enters storage keeps the invalid input from ever becoming state, and gives the
evaluator an immediate, actionable revert.

### Why not require `awards[i].worker` to have submitted for *every* mode, rather than only Bounty/Benchmark?

Claim, Pitch, and Auction tasks have exactly one locked worker in `task.worker`, and the
submission-hash mapping is not the authority for those modes — checking it instead of
`task.worker` would be a weaker test that a second address with an unrelated submission could
satisfy. Mirroring `AcceptanceFacet._resolveDeliverables`' existing per-mode split keeps one
definition of "legitimate recipient" in the codebase rather than two.

### Why not allow the requester to be their own evaluator, and rely on the appeal window alone?

That was the pre-revision design, and it is what made the exploit chain a single-party attack.
The appeal window is only a real check if the party who would rule on the appeal is not the party
being appealed against; with `disputeResolver == requester` the worker's escalation lands back
with their adversary. A minimum window without a self-assignment guard would have narrowed the
timing but left the outcome unchanged. This does break the previously documented
requester-as-evaluator convention — see API Changes.

### Why not keep the minimum as a compiled-in constant?

That was the first shape, and it was wrong twice over. A `public constant` on a facet generates a
getter and therefore a new selector, which the branch never registered in `FacetSelectors.sol` --
so it would have sat in the ABI answering `FunctionNotFound` through the proxy, visible but
unreachable, with nothing in CI to notice. More fundamentally, nobody yet knows the right value
for this parameter, and a facet upgrade is far too heavy an instrument for tuning one number.
Stored state with an owner-guarded setter costs one appended `AppStorage` slot and two selectors,
and makes the parameter adjustable without touching bytecode.

### Why not set the default minimum to something substantial, like an hour or a day?

The bug is the degenerate zero-length window that closes recourse before it can ever fire, not
the absence of a protocol opinion on how long a dispute window ought to be. That remains the
requester's choice, exactly as `evaluationWindowSecs` does. An hour or a day would be a genuine
policy about dispute duration imposed on every requester, which this revision has no basis to
make.

Five minutes is the smallest value that closes the degenerate case *in practice* rather than
merely on paper. The relevant worker is an agent polling on a bounded schedule, not one watching
the chain continuously, so the floor has to exceed a realistic poll interval by enough to leave
room to act — and a one-minute floor, which was drafted first, does not. It was rejected for
that reason, not for being too permissive in the abstract.

This repo's own timing-sensitive smoke tests were the argument for the lower value, and they are
the wrong thing to optimise: a test-only need should not set a production security parameter.
Because the floor is admin-settable, those tests can lower it for their own runs and restore it
afterwards, which is what they now do.

### Why not use `try`/`catch` or an interface call instead of assembly?

Neither bounds the return-data copy. A high-level call through `ITMPHook` decodes the return
value, and `catch (bytes memory reason)` copies the full revert blob — both reintroduce the
unbounded `RETURNDATACOPY` that is the vulnerability. Explicit `call`/`returndatacopy` in
assembly is the only construct in Solidity that lets the caller choose how many bytes it is
willing to copy.

### Why not pull in a library such as ExcessivelySafeCall?

The needed logic is roughly ten lines of assembly with no configuration surface. Adding a
dependency to the contracts package — which is mirrored to `taskmarket-contracts` on every push
to `main` — for that would enlarge the audit and supply-chain surface more than it reduces the
code we own.

### Why not rely on the gas stipend alone and skip the return-data cap?

A gas stipend bounds the *cost* of the attack under today's gas schedule; it does not make the
unbounded copy impossible. EVM repricing (memory expansion, `RETURNDATACOPY`) has changed before
and can change again, and a stipend large enough for a realistic production hook is also large
enough to build a meaningful blob. The 32-byte cap is a structural guarantee that holds
regardless of gas costs; the stipend is defence in depth against a different attack (compute
griefing) that the cap does not address. Both are kept for that reason.

### Why not replace only `EvaluatorFacet` in the upgrade?

`LibTaskMarket` is an `internal` library, so its code is inlined into every facet that calls it
rather than sitting at a shared address. Replacing only `EvaluatorFacet` would leave the patched
hook dispatch off `CoreFacet` — that is, it would leave the HIGH-severity `refundExpired`
fund-freeze path fully live. `CoreFacet`, `AuctionFacet`, `AcceptanceFacet`, and `EvaluatorFacet`
all dispatch hooks and are therefore all redeployed -- verified by searching for the dispatch
helpers' call sites rather than assumed. `AdminFacet` is redeployed for the separate reason that
it gains the two new appeal-window functions.

---

## API Changes

**Three new custom errors on `ITMPCore`** — `EvaluatorCannotBeRequester()`,
`DisputeResolverCannotBeRequester()`, `AppealWindowTooShort()`. Every one of these must be added
to the backend's Diamond revert-decoding map before this revision is deployed. An unmapped
Diamond revert resolves as `unknown revert`, which the relayer classifies as *transient* and
retries indefinitely — so an unmapped new error turns a clean, permanent user-input rejection
into an infinite retry loop. That backend change lands in a separate, non-contracts PR; this
revision is contracts-only, but the deployment is not safe without it.

**One new error on `ITMPCore`** — `InvalidMinAppealWindow()`, thrown by
`AdminFacet.setMinAppealWindowSecs(0)`. Owner-only and not reachable by ordinary users, but it
belongs in the backend's decode map alongside the other three for the same reason.

**One new event on `ITMPCore`** — `MinAppealWindowUpdated(uint32)`, emitted on every change to
the floor.

**Two new selectors, both on `AdminFacet`** — `minAppealWindowSecs()` (`uint32`) and
`setMinAppealWindowSecs(uint32)` (owner only). The getter returns the effective floor including
the lazy default, so a backend or CLI can read what the contract will actually enforce rather
than hardcode a value that drifts. No existing selector's signature changed and none was removed;
`script/upgrades/Rev017Upgrade.s.sol` therefore performs a `Replace` of `AdminFacet`'s seventeen
pre-existing selectors plus an `Add` of these two, and the other four facets are pure `Replace`.
`script/DiamondFullUpgrade.s.sol`'s Path C gains a matching `Add` cut, because
`DiamondSelectorParity.t.sol` asserts a fresh deploy and the upgrade route produce the same
selector set — adding to one and not the other fails CI, which is that guard working as intended.

**Breaking behaviour change: the requester may no longer act as their own evaluator or dispute
resolver.** `assignEvaluator` now reverts `EvaluatorCannotBeRequester()` when
`evaluator == task.requester` and `DisputeResolverCannotBeRequester()` when
`disputeResolver == task.requester`. This contradicts the previously documented convention:
`AGENTS.md` listed `EVALUATOR_PRIVATE_KEY` as optional with "requester can act as evaluator if
not set", and `smoke-evaluator.ts`, `smoke-evaluator-timeout.ts`, and `smoke-concurrent-tasks.ts`
all deliberately relied on it. All three smoke scripts, `AGENTS.md`, and the evaluator reference
docs are updated in this revision to require a distinct `EVALUATOR_PRIVATE_KEY`. Any external
integration that self-assigns will start reverting the moment this is deployed — there is no
grace period and no opt-out, which is the intended shape of the fix, since a self-assigned
evaluator is precisely the exploit precondition.

**Breaking behaviour change: `appealWindowSecs` below the floor is rejected.** `assignEvaluator`
reverts `AppealWindowTooShort()` for any `appealWindowSecs` below the effective minimum --
**300 seconds (five minutes) at launch**, or whatever the owner has since configured -- including
the previously accepted `0`. That is the number operators will see, and it is deliberately larger
than the smallest value that closes the degenerate case: a worker who discovers an adverse verdict
by polling on a bounded schedule needs long enough to notice it and act, and a minute is barely
distinguishable from zero for such a worker.

Callers constructing short windows for test or demo purposes must raise them, or lower the floor
for their own run. Four smoke scripts spend their runtime waiting an appeal window out; rather
than let a test-only need dictate the production value, `smoke-evaluator.ts`,
`smoke-concurrent-tasks.ts` and `smoke-nonce.ts` call `setMinAppealWindowSecs` themselves at the
start of a run and restore it in a `finally`, asserting the value actually went back.
(`smoke-evaluator-timeout.ts` already used an hour and needs no override.) That restore path
needs the diamond owner's key, so those three now skip loudly and exit non-zero when it is
absent, rather than appearing to pass -- see AGENTS.md.

**Breaking behaviour change: award recipients are validated.** `evaluate()` and
`resolveDispute()` now revert `WorkerMismatch()` (Claim/Pitch/Auction) or `SubmissionNotFound()`
(Bounty/Benchmark) for any non-zero-amount award whose `worker` is not the task's locked worker
or an actual submitter. Both errors already exist on `ITMPCore` and are already emitted by
`AcceptanceFacet`, so no new decoding is required for these two.

**Hook contract limits are now enforced.** A hook receives a fixed 1,000,000 gas stipend and at
most 32 bytes of its return data are observed. A hook that previously relied on more of either —
none exist in this repo; `TaskTokenRewardHook` fits comfortably — will now have its `check*` call
treated as a rejection and its `on*` call swallowed with a `HookCallFailed` event. Documented for
integrators in `apps/docs/src/pages/developer/hooks.md`.

---

## Affected Files

| File | Change |
|------|--------|
| `packages/contracts/src/facets/EvaluatorFacet.sol` | `assignEvaluator` self-assignment and appeal-window guards; `_validateAwardRecipients` helper called from `evaluate` and `resolveDispute` (#316) |
| `packages/contracts/src/facets/AdminFacet.sol` | Add `minAppealWindowSecs()` getter and owner-guarded `setMinAppealWindowSecs(uint32)` setter |
| `packages/contracts/src/libraries/LibAppStorage.sol` | Append `uint32 minAppealWindowSecs` to the end of `AppStorage` |
| `packages/contracts/src/interfaces/ITMPCore.sol` | Add errors `EvaluatorCannotBeRequester`, `DisputeResolverCannotBeRequester`, `AppealWindowTooShort`, `InvalidMinAppealWindow`; add event `MinAppealWindowUpdated` |
| `packages/contracts/src/interfaces/ITMPDiamond.sol` | Add the two new `AdminFacet` functions to the aggregate interface |
| `packages/contracts/src/libraries/LibTaskMarket.sol` | Add `HOOK_MAX_RETURN_BYTES`, `HOOK_GAS_STIPEND`, `_safeHookCall`; route `_dispatchCheckHooks`, `_dispatchAfterHooks`, `_checkFundHooks` through it (#317); add `DEFAULT_MIN_APPEAL_WINDOW_SECS` and the lazy-init `_minAppealWindowSecs` accessor |
| `packages/contracts/script/lib/FacetSelectors.sol` | `adminFacetSelectors()` gains `minAppealWindowSecs()` and `setMinAppealWindowSecs(uint32)` |
| `packages/contracts/script/DiamondFullUpgrade.s.sol` | Path C gains an `Add` cut for the two new `AdminFacet` selectors, keeping it in parity with a fresh deploy |
| `packages/contracts/script/upgrades/Rev017Upgrade.s.sol` | New upgrade step -- Replace `CoreFacet`/`AuctionFacet`/`AcceptanceFacet`/`EvaluatorFacet`, Replace+Add `AdminFacet`, bump `diamondVersion` to 17 |
| `packages/contracts/test/Rev017Upgrade.t.sol` | New -- asserts the version bump, all five facet replacements, unbroken routing of every pre-existing selector, both added selectors, and that the getter answers with the default rather than a raw zero immediately after the cut |
| `packages/contracts/test/TaskMarket.t.sol` | Regression coverage for #316 (exploit chain, award mismatch in both mode families, dispute-resolver mismatch, both self-assignment guards, appeal-window floor) and #317 (return-bomb through `_dispatchAfterHooks` and `_dispatchCheckHooks`); existing Bounty `_payAwards` tests now submit work first, since awards must go to a real submitter |
| `packages/contracts/test/mocks/MockReturnBombHook.sol` | New -- hook returning a configurable oversized blob from selected `check*`/`on*` entry points |
| `packages/contracts/.gas-snapshot` | Regenerated |
| `apps/backend/src/scripts/smoke-evaluator.ts` | Require a distinct `EVALUATOR_PRIVATE_KEY`; appeal windows raised to the new floor |
| `apps/backend/src/scripts/smoke-evaluator-timeout.ts` | Require a distinct `EVALUATOR_PRIVATE_KEY` |
| `apps/backend/src/scripts/smoke-concurrent-tasks.ts` | Require a distinct `EVALUATOR_PRIVATE_KEY`; appeal window raised to the new floor |
| `AGENTS.md` | `EVALUATOR_PRIVATE_KEY` documented as required, not optional |
| `apps/docs/src/public/reference/evaluators.md`, `apps/docs/src/pages/reference/evaluators.md` | Requester-as-evaluator no longer supported |
| `apps/docs/src/pages/developer/hooks.md` | Document the hook gas stipend and return-data cap |

## References

- Issue #316 (evaluator payout never validated against the task's actual worker).
- Issue #317 (unbounded return-data copy from attacker-controlled hooks).
- `rev013-bounty-security-fixes.md` — the prior `EvaluatorFacet` security round, which fixed
  `appeal()`'s empty-awards authorization gap but not the award-recipient check.
- Deploy ordering: rev016 (escrow liability) must be applied first; rev018 and rev019 follow.
