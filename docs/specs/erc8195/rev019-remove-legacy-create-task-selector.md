# Rev019 — remove the deprecated pre-rev018 createTask selector

## Motivation

Rev018 changed `createTask`'s parameter list to carry the evaluator terms and grouped its
task-shape scalars into `ITMPCore.TaskConfig`, which changed its selector from `0xa595d889` to
`0xa810726c`. A diamond routes purely by `bytes4`, so swapping one
for the other in a single cut would have made every task creation revert at the fallback for the
entire window between the facet cut and the redeploy of every off-chain caller — not degraded,
reverting — and would have left creation down until a diamond rollback if that redeploy failed.

Rev018 therefore expanded rather than swapped: it added the new selector and deliberately kept the
old one routed to a deprecated overload that forwards to the same shared creation body with an
empty evaluator configuration. That made the facet cut and the caller deploy independently
schedulable and independently reversible.

This revision is the other half of that trade. It removes the legacy selector and deletes the shim
behind it.

It exists as a separate revision, rather than as a later amendment to rev018, for a reason that is
not bookkeeping: the removal only becomes safe at a moment nobody can identify from inside rev018
— when the last caller stops encoding the old signature. A deprecation with no scheduled contract
step is a permanent one. Splitting the contraction into its own numbered revision, with its own
upgrade script and its own precondition, makes the removal a deliberate act someone has to decide
to perform, and makes "have we actually done it yet" a question with an on-chain answer
(`diamondVersion == 19`).

### This revision does not recover bytecode

The expectation going in was that deleting the shim would return facet headroom, since `CoreFacet`
sits closer to the 24,576-byte limit than anything else in the diamond. Measured, it does not.
All three figures below are `forge build --sizes` runtime sizes from the same tree and the same
compiler settings:

| Variant | CoreFacet runtime (B) |
| --- | --- |
| rev018, shim present | 20,059 |
| shim deleted, shared `memory` body kept | 20,209 (+150) |
| shim deleted, body folded back into the external entry point (this revision) | 20,101 (+42) |

Removing the shim **costs** 42 bytes rather than saving any. The reason is that two external entry
points sharing one private body give the optimizer a reason to keep that body out of line and call
it twice; with a single entry point it inlines the body into the dispatcher instead, and the
inlined form — together with decoding five calldata structs at the call site — is marginally larger
than the shared out-of-line copy it replaces. Folding the body back into the external and returning
its struct parameters to `calldata` recovers most of that difference (150 bytes down to 42) but
does not erase it.

This is recorded because the opposite is easy to assume and was assumed here. It does not change
the decision: the reason to contract is that a deprecated selector left routed indefinitely becomes
permanent, and that task creation should have exactly one entry point. It does mean bytecode
headroom is not among this revision's benefits, and nobody should schedule it expecting relief on
facet size.

---

## Deploy precondition

**This step is only safe once nothing encodes selector `0xa595d889`.** After it lands, any caller
still sending that selector gets `Error("Diamond: function not found")` from the diamond's
fallback, on every attempt, with no partial degradation and no retry that will ever succeed.

**The backend deploy having happened is necessary but not sufficient.** The backend is the caller
this revision was written around, but it is not provably the only one: the selector is a public
ABI fact, and anything that ever encoded it — a second service, an operator script, a partner
integration, a queued relayed intent constructed before the redeploy and retried after it —
continues to work right up until this cut and then stops.

Verify against the chain, not against the deploy pipeline:

1. **Confirm the diamond is at rev018.** `diamondVersion()` must return `18`. The script requires
   this, but check it before scheduling, not at broadcast time.
2. **Confirm the legacy selector is currently routed and the new one is too.** `facetAddress()`
   for both `0xa595d889` and `0xa810726c` must be non-zero. If the legacy one is already
   unrouted, this step has already been applied or the diamond is not in the state assumed here.
3. **Observe real traffic, not deploy status.** Over a window long enough to cover the slowest
   periodic caller — infrequent cron-driven task creation is the case most likely to be missed by
   a short sample — scan the diamond's transactions for calldata whose first four bytes are
   `0xa595d889`. Zero occurrences across that window is the actual precondition. A backend
   redeploy timestamp is not evidence about callers that are not the backend.
4. **Check for in-flight retries.** Any relayed-intent or queued-write machinery that persists
   encoded calldata can hold a `0xa595d889` payload constructed before the caller migrated and
   replay it afterwards. Drain or re-encode those before cutting, since they will not appear in
   step 3's window until they fire.

If step 3 cannot be satisfied with confidence, the correct action is to wait. Nothing degrades
while both selectors stay routed; the only cost of waiting is the facet bytecode, which is a cost
already being paid.

Rollback is a re-`Add` of the legacy selector pointed at a CoreFacet built from rev018's source.
It is not a re-run of this script in reverse: the shim no longer exists in the tree, so the facet
that would serve it has to come from that revision's code.

---

## Problem 1 — A deprecated selector with no scheduled removal becomes permanent

Rev018 left `0xa595d889` routed with the stated intention that a later revision would remove it.
Nothing about the rev018 deployment enforces that. The selector keeps working, so no failure ever
prompts anyone to revisit it, and its real cost — a second, undocumented-in-the-interface entry
point into task creation that every future change to the creation body has to keep in mind, and a
signature the protocol has stopped describing but still honours — is paid indefinitely and
silently.

## Problem 2 — Unrouting alone leaves the dead code deployed

The naive contraction is a single `Remove` cut: stop routing `0xa595d889` and stop there. That
achieves the API change and none of the rest. The deployed `CoreFacet` still contains the shim, so
the source and the chain disagree about whether that entry point exists, and the next person to
`Replace` `CoreFacet` from current source changes its behaviour without meaning to.

Deleting the overload from the source and pointing the diamond at a newly deployed facet makes
this a `Replace` plus a `Remove` rather than a `Remove` alone. Note that this is a correctness and
maintainability argument, not a size one — see the measurement above.

---

## Changes

### 1. `CoreFacet` — the deprecated overload is deleted

Rev018 split creation into two externals and a shared private body. With one external left, the
split has no purpose, so the body folds back into `createTask` and `evaluatorConfig` returns to
`calldata` from `memory`.

```solidity
// before (rev018)
function createTask(
    ITMPCore.TaskConfig calldata config,
    ITMPCore.StakeConfig calldata stakeConfig,
    ITMPCore.HookConfig calldata hookConfig,
    ITMPCore.TaskContent calldata content,
    ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig
) external returns (bytes32 taskId) {
    return _createTask(config, stakeConfig, hookConfig, content, evaluatorConfig);
}

/// @notice Deprecated: `createTask` without evaluator terms.
function createTask(
    uint256 reward, uint256 duration, bytes4 mode,
    uint256 pitchDeadline, uint256 bidDeadline, bytes4 auctionSubtype,
    ITMPCore.StakeConfig calldata stakeConfig,
    ITMPCore.HookConfig calldata hookConfig,
    ITMPCore.TaskContent calldata content
) external returns (bytes32 taskId) {
    ITMPCore.TaskEvaluatorConfig memory noEvaluator;
    return _createTask(
        ITMPCore.TaskConfig({ reward: reward, duration: duration, mode: mode, /* ... */ }),
        stakeConfig, hookConfig, content, noEvaluator
    );
}

function _createTask(
    ITMPCore.TaskConfig memory config,          // memory, not calldata: the shim builds one
    ITMPCore.StakeConfig calldata stakeConfig,
    ITMPCore.HookConfig calldata hookConfig,
    ITMPCore.TaskContent calldata content,
    ITMPCore.TaskEvaluatorConfig memory evaluatorConfig
) private returns (bytes32 taskId) {
    /* the creation body */
}
```

```solidity
// after
function createTask(
    ITMPCore.TaskConfig calldata config,        // calldata again -- nothing materialises one
    ITMPCore.StakeConfig calldata stakeConfig,
    ITMPCore.HookConfig calldata hookConfig,
    ITMPCore.TaskContent calldata content,
    ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig
) external returns (bytes32 taskId) {
    /* the creation body */
}
```

Both struct parameters return to `calldata`. Rev018 had to widen them to `memory` because the shim
constructs a `TaskConfig` from its six loose scalars and passes it in; with the shim gone, the only
caller is the external entry point, whose arguments are already calldata. Keeping the `memory`
signature after deleting the shim measures 108 bytes worse than folding it back (20,209 against
20,101), so the fold is not tidying — it is the difference between this revision costing 150 bytes
and costing 42.

### 2. `FacetSelectors` — the legacy selector leaves the steady state

`coreFacetSelectors()` returns 21 entries again rather than 22, and its `createTask` entry is
`CoreFacet.createTask.selector` rather than an explicit signature hash. With one overload, the
plain form resolves again, so the `CREATE_TASK` constant rev018 had to introduce is removed and
every displaced `.selector` reference is restored.

`LEGACY_CREATE_TASK` is kept. It is not dead: `Rev018Upgrade` `Replace`s it, `Rev019Upgrade`
`Remove`s it, and `DiamondFullUpgrade`'s Path C does both in one run. A selector no facet serves
has no `.selector` expression to derive it from, so it stays written out as a signature hash — the
same idiom the other historical selectors in `DiamondFullUpgrade` use.

### 3. `DiamondFullUpgrade` — Path C removes it, Paths A and B stop adding it

Path C `Replace`s the selectors an old diamond routes (including the legacy one), `Add`s the
evaluator-aware selector, then `Remove`s the legacy one — ending at the post-rev019 steady state
in a single run. The legacy entry is `Replace`d and then `Remove`d rather than simply left out of
the `Replace`: an old diamond does route it, so omitting it would leave it pointing at the
previous `CoreFacet`.

Paths A and B `Add` only the evaluator-aware selector. Rev018 had them add both, so that a very
old diamond landed mid-migration alongside everything else; with the shim gone there is nothing
for the legacy selector to route to.

The new cut is appended with the running-index idiom (`cuts[i++]`) that rev018 introduced for Path
C, so a revision that appends a cut here and another that appends one elsewhere merge as two
`i++` lines rather than as a silent overwrite.

### 4. `Rev019Upgrade.s.sol`

Guards `diamondVersion == 18`, bumps to 19. The cut is `Replace(CoreFacet's remaining selectors)`
followed by `Remove(legacy selector)`. `Replace` comes first so that every selector the diamond
routes points at the new facet at all times.

### 5. Tests

`Rev019Upgrade.t.sol` deploys at the helper's rev011 baseline, advances through the intervening
revisions, reconstructs rev018's routing by `Add`ing the legacy selector back, applies the step,
and asserts the version bump, the facet replacement, that the new selector still executes, and —
the assertion the revision exists for — that the legacy selector no longer routes and its calls
are rejected by the diamond's fallback.

Rev018's assertion that the legacy selector still executes after *its* cut is removed rather than
relocated. It cannot be restored: no bytecode implementing that signature survives in the tree, so
`Rev018Upgrade`'s cut now points the legacy selector at a `CoreFacet` that has no such function.
This is the same limitation `Rev014UpgradeTest` and `Rev015UpgradeTest` already document — an
upgrade step's historical behaviour is only testable while the bytecode that implemented it still
exists in the repository.

`DiamondSelectorParity.t.sol`'s pre-rev018 fixture is inverted: it substitutes the legacy selector
for the new one rather than dropping the new one. This is what keeps Path C's `Add` and `Remove`
both load-bearing — include the new selector and the `Add` reverts on an already-routed selector;
omit the legacy one and the `Replace` reverts on a selector that does not exist and the `Remove`
becomes a no-op that proves nothing.

---

## Rationale

### Why not remove the selector as part of rev018?

That is the swap this whole pair exists to avoid. A diamond routes by `bytes4` alone, so a cut
that removes `0xa595d889` while adding `0xa810726c` makes every task creation revert from the
moment it mines until every off-chain caller has been redeployed. That is not a degradation window
— creation is down — and it welds two systems that deploy on different schedules into one
indivisible operation whose failure mode is "task creation stays down until someone rolls the
diamond back".

### Why a separate revision rather than an amendment to rev018 applied later?

Because the safe moment is not knowable when rev018 is written. Rev018 can state the intent to
remove; it cannot state when. Making the contraction its own revision gives it its own
precondition, its own version guard, and its own on-chain completion marker, so "has the
deprecated selector actually been removed" is answerable by reading `diamondVersion()` rather than
by remembering.

### Why not leave the selector routed permanently?

Not for bytecode — measurement says leaving it is 42 bytes *cheaper*, and that argument is
withdrawn above. The reason is that it leaves a second entry point into task creation that every
future change to the creation body has to reason about, and that is exactly the kind of surface
where a later revision tightens one path and silently leaves the other open. Rev018 itself made
this argument in the other direction: it consolidated `assignEvaluator` and the creation path onto
one shared body precisely so rev017's guards could not be sidestepped by the newer entry point. A
permanent shim reintroduces the shape that reasoning rejected.

The cost is also not static in the way the bytecode framing suggests. One shim is 42 bytes and one
extra code path; the precedent of never contracting is unbounded in both.

### Why not just `Remove` the selector without redeploying `CoreFacet`?

Because then the shim is still deployed and the source no longer describes what is on chain — see
Problem 2. The route would be gone while the code stayed, so the next `Replace` of `CoreFacet`
from current source would change deployed behaviour as an unintended side effect.

### Why keep `LEGACY_CREATE_TASK` in `FacetSelectors` if the shim is gone?

The historical upgrade paths still have to name it: `Rev018Upgrade` `Replace`s it, this revision's
script `Remove`s it, and `DiamondFullUpgrade`'s Path C does both. Deleting the constant would mean
re-deriving the same signature hash inline in three places.

### Why assert the fallback's `Error(string)` rather than `LibDiamond.FunctionNotFound`?

They are different failures and only one of them is on the call path. `LibDiamond.FunctionNotFound`
is raised by `_removeFunction` when a *cut* tries to remove a selector that is not routed. A call
to an unrouted selector is rejected earlier, by the `require(facet != address(0), "Diamond:
function not found")` in `Diamond.fallback`. Asserting the custom error passes nothing and fails
for the wrong reason; asserting the string is what actually distinguishes "rejected by the
diamond" from "reached a facet and reverted there", which is exactly the distinction that proves
the shim is gone rather than merely unreachable through one path.

---

## API Changes

- **Removed selector `0xa595d889`** —
  `createTask(uint256,uint256,bytes4,uint256,uint256,bytes4,(bool,uint16),(address[],bytes),(bytes32,string,bytes32[]))`.
  Calls to it revert `Error("Diamond: function not found")` from the diamond's fallback. There is
  no deprecation period beyond rev018 itself; this revision is the end of it.
- **No change to `0xa810726c`**, the evaluator-aware `createTask` added in rev018. Its signature,
  behaviour, and semantics are untouched.
- **No interface change.** The deprecated overload was deliberately never declared on `ITMPCore`
  or `ITMPDiamond`, so `type(ITMPCore).interfaceId` — which `DiamondLoupeFacet.supportsInterface`
  reports — is unaffected by its removal, just as it was unaffected by its addition.
- **No new or removed errors, events, or storage.** `AppStorage` is untouched.

## Affected Files

| File | Change |
| --- | --- |
| `packages/contracts/src/facets/CoreFacet.sol` | Deprecated nine-parameter `createTask` overload deleted; shared `_createTask` body folded back into the single external, `evaluatorConfig` back to `calldata` |
| `packages/contracts/script/lib/FacetSelectors.sol` | `coreFacetSelectors()` back to 21 entries using `CoreFacet.createTask.selector`; `CREATE_TASK` constant removed; `LEGACY_CREATE_TASK` retained for the historical upgrade paths |
| `packages/contracts/script/DiamondFullUpgrade.s.sol` | Path C `Remove`s the legacy selector via the running-index idiom; Paths A and B no longer `Add` it; `_legacyCreateTaskSelector()` added |
| `packages/contracts/script/DiamondUpgrade.s.sol` | CoreFacet selector list back to its pre-rev018 shape; unused `FacetSelectors` import dropped |
| `packages/contracts/script/upgrades/Rev019Upgrade.s.sol` | New: guards `diamondVersion == 18`, `Replace` + `Remove`, bumps to 19 |
| `packages/contracts/script/upgrades/Rev018Upgrade.s.sol` | `CoreFacet.createTask.selector` restored in place of the removed `CREATE_TASK` constant |
| `packages/contracts/test/Rev019Upgrade.t.sol` | New: version bump, facet replacement, legacy selector unrouted and rejected by the fallback, new selector still executes, pre-version guard |
| `packages/contracts/test/Rev018Upgrade.t.sol` | Fixture `Add`s the legacy selector back; the legacy half of the "both selectors execute" assertion removed as unrestorable |
| `packages/contracts/test/DiamondSelectorParity.t.sol` | Pre-rev018 fixture substitutes the legacy selector for the new one |
| `packages/contracts/test/TaskMarket.t.sol` | Rev018's four legacy-shim behaviour tests replaced by two asserting the selector is unrouted and rejected by the fallback |
| `packages/contracts/test/Diamond.t.sol`, `Rev012Upgrade.t.sol`, `Rev013Upgrade.t.sol` | `CoreFacet.createTask.selector` restored |
| `packages/contracts/.gas-snapshot` | Regenerated |
