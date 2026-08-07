# Rev018 — createTask takes the evaluator configuration

## Motivation

Before this revision, `CoreFacet.createTask` took no evaluator configuration. A requester who
wanted a task evaluated had to send a second transaction, `EvaluatorFacet.assignEvaluator`, after
the task already existed. That second call is gated on the task still being `Open`, and reverts
`TaskNotOpen` once any worker has claimed it.

The task is claimable from the instant `createTask` mines. On a fast chain with worker agents
watching for new tasks, the gap between the two transactions is milliseconds, and losing that race
is not an edge case: ADR-0046's correction note records a live run in which 4 of 4 evaluator
assignments were lost when the second call was deferred, and ADR-0047 names this two-transaction
shape as the root cause of the chaining subsystem that was subsequently withdrawn. A task that
loses the race is not merely missing an evaluator -- it is a task whose requester believes it is
evaluator-gated and which will instead settle through the plain acceptance path.

Making `createTask` carry the evaluator terms removes the window rather than narrowing it. There
is no second transaction to lose.

## Problem 1 — Evaluator assignment races the first claim

`EvaluatorFacet.assignEvaluator` requires `task.status == Open`:

```solidity
if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
```

`CoreFacet.createTask` sets `Open` and returns. Between that transaction and the requester's
follow-up `assignEvaluator`, any worker may call `claimTask`, moving the task to `Claimed`. The
assignment then reverts and cannot be retried: no later status ever returns to `Open`. The
observable symptom is a permanently un-evaluated task plus a failed transaction, with no on-chain
record that an evaluator was ever intended.

The gate itself is correct for what it guards -- appointing an evaluator after a worker has
committed would change the terms that worker accepted. The problem is that a requester who knew
the terms at creation time had no way to express them at creation time.

## Problem 2 — Two entry points writing the same storage will drift

Once creation can also write `s.taskEvaluatorConfigs[taskId]`, two code paths validate and write
the same struct. Duplicated validation drifts: the path that is easier to forget becomes the way
around whatever the other path checks. This is not hypothetical here -- rev017 tightened what
evaluator terms `assignEvaluator` accepts (an evaluator or dispute resolver equal to the
requester, and an appeal window below the protocol minimum), and a creation path with its own copy
of the checks would have silently become the way to set exactly those configurations.

## Problem 3 — Swapping a selector takes task creation down for the deploy window

A diamond routes purely by `bytes4`. Changing `createTask`'s parameter list changes its selector,
so the naive cut is `Remove(old) + Replace(unchanged) + Add(new)`. From the moment that cut mines
until every off-chain caller has been redeployed against the new signature, every task creation
reverts at the diamond's fallback -- not degraded, reverting. If the caller deploy then fails,
task creation stays down until someone rolls the diamond back. The facet cut and the backend
deploy become one indivisible operation across two systems that deploy on different schedules.

## Changes

### 1. `createTask` takes `TaskEvaluatorConfig`, and its scalars are grouped into `TaskConfig`

Before:

```solidity
function createTask(
    uint256 reward,
    uint256 duration,
    bytes4 mode,
    uint256 pitchDeadline,
    uint256 bidDeadline,
    bytes4 auctionSubtype,
    ITMPCore.StakeConfig calldata stakeConfig,
    ITMPCore.HookConfig calldata hookConfig,
    ITMPCore.TaskContent calldata content
) external returns (bytes32 taskId) {
    ...
    _buildAndCheckHooks(taskId, hookConfig, s);
```

After:

```solidity
struct TaskConfig {
    uint256 reward;
    uint256 duration;
    bytes4 mode;
    uint256 pitchDeadline;
    uint256 bidDeadline;
    bytes4 auctionSubtype;
}

function createTask(
    ITMPCore.TaskConfig calldata config,
    ITMPCore.StakeConfig calldata stakeConfig,
    ITMPCore.HookConfig calldata hookConfig,
    ITMPCore.TaskContent calldata content,
    ITMPCore.TaskEvaluatorConfig calldata evaluatorConfig
) external returns (bytes32 taskId) {
    ...
    // Applied before the hooks so a checkFund hook observes a fully configured task rather
    // than one that only becomes evaluator-gated a moment later.
    _applyCreationEvaluatorConfig(taskId, requester, evaluatorConfig, s);

    _buildAndCheckHooks(taskId, hookConfig, s);
```

The six loose scalars are grouped into `ITMPCore.TaskConfig` in the same revision that adds the
evaluator terms. They are the same fields as before, in the same order, reached as `config.reward`,
`config.mode`, and so on; only the calldata shape changes. `AppStorage` is untouched -- no field is
added, moved, or resized, and nothing about the struct is stored.

The zero struct means "no evaluator", which is the common case. Evaluator terms supplied with a
zero `evaluator` address revert `InvalidEvaluator` rather than being silently discarded:

```solidity
function _applyCreationEvaluatorConfig(
    bytes32 taskId,
    address requester,
    ITMPCore.TaskEvaluatorConfig memory evaluatorConfig,
    AppStorage storage s
) private {
    if (evaluatorConfig.evaluator != address(0)) {
        LibTaskMarket._applyEvaluatorConfig(taskId, requester, evaluatorConfig, s);
        return;
    }
    if (
        evaluatorConfig.evaluatorStake != 0 || evaluatorConfig.evaluatorFeeBps != 0
            || evaluatorConfig.evaluationWindow != 0 || evaluatorConfig.appealWindow != 0
            || evaluatorConfig.disputeResolver != address(0)
    ) {
        revert ITMPCore.InvalidEvaluator();
    }
}
```

No `AppStorage` field is added: `s.taskEvaluatorConfigs[taskId]` already holds this struct.

### 2. Both entry points share one validation and write body

`EvaluatorFacet.assignEvaluator` keeps only the checks that depend on its own caller context and
delegates the rest.

Before:

```solidity
if (requester != task.requester) revert ITMPCore.NotRequester();
if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();
if (evaluator == address(0)) revert ITMPCore.InvalidEvaluator();
if (evalCfg.evaluator != address(0)) revert ITMPCore.EvaluatorAlreadyAssigned();
if (feeBps > 10000) revert ITMPCore.FeeBpsTooHigh();

evalCfg.evaluator = evaluator;
// ... five more field writes, the stake pull, and the event
```

After:

```solidity
if (requester != task.requester) revert ITMPCore.NotRequester();
if (task.status != ITMPCore.TaskStatus.Open) revert ITMPCore.TaskNotOpen();

// Remaining validation, storage writes, stake pull and event live in LibTaskMarket so
// this path and createTask's cannot drift apart. See _applyEvaluatorConfig.
LibTaskMarket._applyEvaluatorConfig(
    taskId,
    requester,
    ITMPCore.TaskEvaluatorConfig({ ... }),
    s
);
```

`NotRequester` and `TaskNotOpen` stay with the caller because they have nothing to test on the
creation path: there the requester is the authenticated sender by construction and the task is
`Open` by construction. Every check on the evaluator *terms* lives in the shared body, so a later
revision tightening one of them tightens both paths without needing to know both exist.

`LibTaskMarket._applyEvaluatorConfig` emits `EvaluatorAssigned` whichever path called it, so an
indexer needs one event vocabulary for "this task has an evaluator" rather than having to infer it
from `TaskCreated` on the creation path.

### 3. The pre-rev018 selector stays routed (expand, then contract)

The cut adds the new selector without removing the old one, and the old one keeps working via a
deprecated overload on the same facet:

```solidity
function createTask(
    uint256 reward,
    ...
    ITMPCore.TaskContent calldata content
) external returns (bytes32 taskId) {
    ITMPCore.TaskEvaluatorConfig memory noEvaluator;
    return _createTask(..., noEvaluator);
}
```

Both overloads forward to one private `_createTask`, so the shim cannot drift from the real path:
it is the same body with an empty configuration.

`Rev018Upgrade.s.sol`'s cut is therefore `Replace` across the 21 CoreFacet selectors a rev017
diamond already routes (the legacy `createTask` among them), `Add` for the new selector, and
`Replace` across EvaluatorFacet's unchanged selector set. There is no `Remove`. Rev019 removes the
legacy selector and deletes the shim, once nothing encodes the old signature any more.

`FacetSelectors.coreFacetSelectors()` grows to 22 entries and gains two named constants,
`CREATE_TASK` and `LEGACY_CREATE_TASK`. Both are explicit `bytes4(keccak256(...))` signature
hashes rather than `.selector` expressions, because with two overloads in scope
`CoreFacet.createTask.selector` no longer compiles -- the same idiom the file already uses for
public constant getters and for `DiamondFullUpgrade`'s historical selectors.

`DiamondFullUpgrade`'s Path C splits its CoreFacet cut the same way: `Replace` for the selectors an
existing diamond routes, plus one `Add` for the new one.

## Rationale

### Why not keep `assignEvaluator` as the only way to configure an evaluator?

Because the race is not fixable from that side. Every mitigation available to a second transaction
-- retry loops, private mempools, tighter nonce management -- narrows the window without closing
it, and the window is bounded below by block production, not by anything the caller controls. The
only thing that removes the race is not having a second transaction.

### Why not have `createTask` write the config directly instead of sharing a library body?

Because two copies of the validation is exactly how the creation path becomes the bypass. The
concrete instance is rev017, which landed one revision earlier: had the creation path kept its own
checks, it would have accepted an evaluator equal to the requester, and a below-minimum appeal
window, while `assignEvaluator` rejected both. The guard cheapest to skip is the one nobody has
written yet, so the shared body is the mechanism that makes skipping impossible rather than merely
inadvisable.

### Why not replace the selector outright, as rev014 did?

Rev014 could afford it: it was a coordinated change where the contract and its only caller shipped
together, and task creation reverting between the two was accepted. It is a worse trade every time
it is repeated, and it is a strictly avoidable one. A replacement makes the facet cut and the
backend deploy a single operation spanning two systems with different deploy schedules and
different rollback mechanisms: the failure mode is total (every creation reverts, not some), and
the recovery for a failed backend deploy is a diamond rollback rather than a backend rollback.
Expanding first makes each half independently deployable and independently reversible. The cost is
one dead code path and roughly 800 bytes of CoreFacet bytecode for one revision, against a facet
with over 4,800 bytes of headroom.

### Why not route the legacy selector to a facet that reverts with a clear "migrate" error?

That is a replacement with better ergonomics, not an alternative to one: creation through the old
signature still fails, so the deploy window still exists. It would only be preferable if silently
accepting the old signature were dangerous -- and it is not. The old signature has always meant
"create a task with no evaluator", and the shim does exactly that. A caller that has not migrated
gets its previous behaviour, including the option to call `assignEvaluator` afterwards and accept
that race, which is the same deal it had before rev018.

### Why not add the legacy overload to `ITMPCore` and `ITMPDiamond`?

Because it is a migration shim, not part of the protocol interface. Declaring it there would change
`type(ITMPCore).interfaceId`, which `DiamondLoupeFacet.supportsInterface` reports, so an ERC-165
consumer would see the protocol interface change twice -- once for the real signature change, once
again when rev019 removes the shim. Declaring it only on the concrete facet keeps the shim invisible
to interface detection.

### Why not add `evaluatorConfig` and leave the six scalars as they were?

Because the resulting ten-parameter function could not be coverage-checked. `forge coverage`
compiles with `--ir-minimum`, whose instrumentation needs more stack slots than the default
`via_ir` profile, and the tenth parameter pushed `createTask` past what it can allocate:
`Cannot swap Variable var_mode with Variable var_taskId: too deep in the stack by 4 slots`. The
contract compiled and all 574 tests passed -- which is precisely the problem, since
`make contract coverage-check` runs in CI and the shipped code could not satisfy it.

The durable reason is the one behind the immediate one. `stakeConfig`, `hookConfig` and `content`
are each an earlier round of exactly this fix, made one field at a time as the signature crossed
the stack window again; `evaluatorConfig` was simply the field that made the next round due. A
ten-parameter external function was one field away from unmaintainable regardless of the compiler,
and each of these rounds costs a selector change and a coordinated off-chain migration. Folding the
remaining scalars into `TaskConfig` takes the signature to five calldata pointers, ends the stack
pressure rather than deferring it, and makes the next task-shape field a struct member -- free,
with no selector change and no migration.

Doing it now was also the cheap moment and the only cheap moment: rev018 already changes
`createTask`'s selector and has not merged, so the fold costs nothing extra. Deferring it would
have meant a second full expand-then-contract cycle, and a third routed selector for rev019 to
remove instead of one.

### Why revert on evaluator terms with no evaluator, rather than ignoring them?

A dropped configuration is unobservable. Nothing ever reports the discarded fields, so a requester
who mis-encoded the struct would believe the task was evaluator-gated for its entire life and only
discover otherwise at settlement. A revert costs a malformed request; silence costs a
misconfigured escrow that cannot be corrected once a worker has claimed.

## API Changes

- `ITMPCore.createTask` and `ITMPDiamond.createTask` take five calldata structs:
  `(ITMPCore.TaskConfig, ITMPCore.StakeConfig, ITMPCore.HookConfig, ITMPCore.TaskContent,
  ITMPCore.TaskEvaluatorConfig)`. The evaluator terms are new; the six task-shape scalars
  (`reward`, `duration`, `mode`, `pitchDeadline`, `bidDeadline`, `auctionSubtype`) move unchanged
  and in the same order into the new `ITMPCore.TaskConfig` struct. Selector changes from
  `0xa595d889` to `0xa810726c`. `type(ITMPCore).interfaceId` changes accordingly.
- `ITMPCore.TaskConfig` is a new struct: `(uint256 reward, uint256 duration, bytes4 mode,
  uint256 pitchDeadline, uint256 bidDeadline, bytes4 auctionSubtype)`. It is calldata only --
  nothing stores it.
- The nine-parameter `createTask` (`0xa595d889`) remains callable on the diamond, routed to a
  deprecated overload declared on `CoreFacet` only. It creates a task with no evaluator, exactly
  as before. It is scheduled for removal in rev019 and is not part of `ITMPCore`/`ITMPDiamond`.
- `createTask` may now revert `InvalidEvaluator`, `EvaluatorAlreadyAssigned`, `FeeBpsTooHigh` and
  `StakeTransferFailed` -- the evaluator-term errors previously reachable only via
  `assignEvaluator`.
- `EvaluatorAssigned` may now be emitted from within a `createTask` transaction.
- `EvaluatorFacet.assignEvaluator`'s signature, semantics and errors are unchanged.
- No storage layout change.

## Affected Files

| File | Change |
| --- | --- |
| `packages/contracts/src/facets/CoreFacet.sol` | `createTask` takes `TaskConfig` and `TaskEvaluatorConfig`; deprecated nine-parameter overload added; shared body extracted to private `_createTask`; `_applyCreationEvaluatorConfig` added |
| `packages/contracts/src/facets/EvaluatorFacet.sol` | `assignEvaluator` delegates term validation, writes, stake pull and event to `LibTaskMarket._applyEvaluatorConfig` |
| `packages/contracts/src/libraries/LibTaskMarket.sol` | `_applyEvaluatorConfig` added, shared by both entry points |
| `packages/contracts/src/interfaces/ITMPCore.sol` | `TaskConfig` struct added; `createTask` declaration takes `config` and `evaluatorConfig` |
| `packages/contracts/src/interfaces/ITMPDiamond.sol` | `createTask` declaration takes `config` and `evaluatorConfig` |
| `packages/contracts/script/lib/FacetSelectors.sol` | `CREATE_TASK`/`LEGACY_CREATE_TASK` constants; `coreFacetSelectors()` grows to 22 |
| `packages/contracts/script/upgrades/Rev018Upgrade.s.sol` | New: rev017 to rev018 step (Replace + Add, no Remove) |
| `packages/contracts/script/upgrades/Rev014Upgrade.s.sol` | Uses `FacetSelectors.LEGACY_CREATE_TASK` for the selector it historically added |
| `packages/contracts/script/DiamondFullUpgrade.s.sol` | Path C splits CoreFacet into Replace + Add; Paths A/B add both createTask selectors |
| `packages/contracts/script/DiamondUpgrade.s.sol` | CoreFacet selector list carries both overloads |
| `packages/contracts/docs/specs/erc8195/erc-8195.md` | Note on atomic evaluator configuration |
| `packages/contracts/test/Rev018Upgrade.t.sol` | New: version bump, both selectors route, both selectors execute |
| `packages/contracts/test/TaskMarket.t.sol` | Creation-with-evaluator tests, entry-point validation parity tests, legacy-overload tests |
| `packages/contracts/test/DiamondSelectorParity.t.sol` | Pre-rev018 CoreFacet selector set for the old-state diamond |
| `packages/contracts/test/helpers/EvaluatorConfigHelper.sol` | New: `noEvaluatorConfig()` for the many call sites that use no evaluator |
| `packages/contracts/test/helpers/TaskConfigHelper.sol` | New: `taskConfig(...)` builders so call sites do not repeat a six-field literal |
| `packages/contracts/test/ITMP.t.sol`, `TaskMarketForwarder.t.sol`, `TaskTokenRewardHook.t.sol`, `Rev012Upgrade.t.sol`, `Rev013Upgrade.t.sol`, `Diamond.t.sol` | Updated for the new `createTask` signature and the now-overloaded selector expression |
