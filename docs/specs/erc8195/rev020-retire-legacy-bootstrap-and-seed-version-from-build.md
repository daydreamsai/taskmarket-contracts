# Rev020 — retire the legacy bootstrap and seed the version from the build

## Motivation

Rev011 introduced `AppStorage.diamondVersion` and the per-revision upgrade step scripts under
`script/upgrades/`. Alongside them it kept `script/DiamondFullUpgrade.s.sol`, a bootstrap with
three loupe-detected migration paths (A, B and C) that carried a diamond from whichever historical
selector state it happened to be in up to rev011, after which the step scripts took over one
revision at a time. `script/upgrade.sh` ran the bootstrap only when `diamondVersion()` read `0`.

Three things about that arrangement have come apart.

**No diamond that could use the bootstrap exists.** Both live diamonds read `diamondVersion() = 15`
on chain. They are version-tracked and well past rev011, so `upgrade.sh` never takes the bootstrap
branch. Paths A, B and C are unreachable in production and have been since rev011 shipped.

**A fresh deploy reported a revision it was not running.** `AdminFacet.initialize()` hardcoded
`s.diamondVersion = 11`. A deploy today builds every facet from current source and routes the
current selector set from `script/lib/FacetSelectors.sol`, then stamped itself 11. That number was
not a fact about the code; it was a constant left over from when 11 was current, and
`Rev012Upgrade.t.sol` asserted it (`"fresh deploy must start at rev011"`), cementing the mismatch
rather than catching it.

That is not cosmetic. On a newly deployed chain, `make upgrade` read 11, correctly skipped the
bootstrap, and then tried to apply rev012 onward because every target exceeded 11. It did not get
far:

- `Rev014Upgrade` opens with a `Remove` of the pre-rev014 `createTask` selector, which a fresh
  deploy never installed, so `LibDiamond` reverts `FunctionNotFound`. That is the first failure.
- Had that step passed, `Rev017Upgrade` would then `Add` `minAppealWindowSecs` and
  `setMinAppealWindowSecs`, which a fresh deploy already routes, and `LibDiamond` rejects an `Add`
  for an existing selector.

The general shape: a step script encodes a delta from a real historical state, while a fresh deploy
is already at the destination. Every step that is not a pure `Replace` re-attempts an operation
that is already satisfied, and each such attempt is a revert rather than a no-op.

**The parity test enforced the wrong invariant, and that is what kept breaking the bootstrap.**
Rev011 called for a test that deploys fresh, separately runs the full versioned upgrade sequence
from a simulated old state, and asserts both reach an identical selector set. What shipped
(`test/DiamondSelectorParity.t.sol::test_FreshDeploy_MatchesFullUpgradePathC`) compared a fresh
deploy against **Path C alone**, not against the sequence.

Because a fresh deploy routes today's complete selector set, keeping that test green forced Path C
to acquire each new revision's selectors while still calling `setDiamondVersion(11)`. Path C had
grown rev017's two selectors and stamped 11; `Rev017Upgrade` would later try to `Add` the same two
and revert. Paths A and B were never edited and did not have this problem, so the three paths no
longer agreed with each other.

This recurred every revision, and through every cut action: rev017 collided on `Add`; rev018 grew
`coreFacetSelectors()` from 21 entries to 22, so Path C's wholesale `Replace` would target a
selector a pre-rev011 diamond does not route; rev019 removed a selector, a third variant. Each
revision paid the same tax to keep unreachable code compiling against a test asserting something
that stopped being true at rev012.

## Changes

### 1. `script/DiamondFullUpgrade.s.sol` is deleted

All three migration paths go, along with the historical selector-set helpers
(`_regPreIntegritySelectors`, `_coreExistingSelectors` and peers) that only that file used. Git
history retains them; they stop being discoverable in the tree.

### 2. `script/upgrade.sh` no longer bootstraps

The `VERSION = 0` branch used to run the bootstrap and then continue. It now prints what it found
and exits non-zero. There is no automated path to bring a pre-rev011 diamond forward: if one is
ever discovered, the cut has to be reconstructed by hand from git history. Failing loudly is the
point — silently proceeding into the step sequence from an unknown selector state is exactly the
class of operation that should not happen unattended.

### 3. `src/libraries/LibRevision.sol` — a single constant for the current revision

```solidity
library LibRevision {
    uint256 internal constant CURRENT_REVISION = 20;
}
```

`AdminFacet.initialize()` seeds `s.diamondVersion = LibRevision.CURRENT_REVISION` instead of `11`.

A fresh deploy is built from `FacetSelectors.sol`, which is to say it is already at the destination
every step script is trying to reach, so the current revision is the only honest number for it to
report. Reporting anything lower sends `upgrade.sh` off applying historical deltas the diamond has
already absorbed.

The constant lives in its own library, rather than inline in `AdminFacet`, so that there is one
obvious place for the next revision's author to find it, and so that the upgrade step script and
the tests can reference the same value rather than repeating the literal.

### 4. `Rev020Upgrade.s.sol`

Rev020 changes no selector on any facet. The only source change it carries into deployed bytecode
is in `AdminFacet.initialize()`, and `initialize()` is `initializer`-guarded and already spent on
every live diamond, so nothing a live diamond can reach behaves differently.

The step exists anyway, and the reason is the same one the rest of this revision is about. Without
it, a fresh deploy of this build would report 20 while a live diamond carried forward by the step
sequence stopped at 19, with both running identical code — `diamondVersion` would then mean
different things depending on how the diamond got there. Its cut is a pure `Replace` of
`AdminFacet`'s selector set: not required to move the counter, but not decorative either, since it
points the diamond at bytecode built from this revision's source, keeping "the diamond is at
rev020" a claim about code rather than about a number someone set.

### 5. `test/DiamondSelectorParity.t.sol` is rebuilt around two properties

`test_FreshDeploy_MatchesFullUpgradeSequence` deploys two diamonds. One is left fresh. The other is
rewound to rev011-era routing and walked forward by every step script from rev012 to rev020, and
the two must end with the same per-facet selector set. Facets are compared by their canonical
(sorted) selector list rather than by address or by position in `facets()`, since those
legitimately differ between two independently deployed diamonds. Comparing per facet rather than as
one flat set matters: a selector that migrated from one facet to another would leave the flat set
identical while changing what executes.

`test_FreshDeployVersion_MatchesHighestUpgradeStep` asserts a fresh deploy's `diamondVersion()`
equals the highest `RevNNNUpgrade` step present. The highest step is discovered by listing
`script/upgrades/` at test time rather than hardcoded, so adding `Rev021Upgrade.s.sol` is by itself
enough to trip the test if `LibRevision.CURRENT_REVISION` was not bumped with it — nobody has to
remember to update the test as well, which is the failure mode a hardcoded expectation would have.
This required a `fs_permissions` read entry for `./script/upgrades` in `foundry.toml`.

#### What the sequence test does not cover, stated plainly

Two limits, neither of which the test papers over:

**Routing is reconstructed, bytecode is not.** This repository contains no historical facet source,
so every facet in the sequence run is built from current code. The test proves the cuts compose to
the right selector set. It does not prove the historical implementations behaved as they did. That
limitation is inherent to running the sequence in-tree and is not new to this revision.

**The step sequence is not internally consistent about `createTask`, so one reconstruction happens
mid-sequence.** Rev012, rev013 and rev016 each `Replace` `FacetSelectors.coreFacetSelectors()` —
the list as it stands today, which includes rev018's evaluator-aware selector — so that selector
must be routed for them to run at all. Rev018 then `Add`s the same selector, which requires it to
be absent. Both cannot hold from a single starting state, because rev012 and rev013 were written
against a `coreFacetSelectors()` that has since changed under them. The test therefore unroutes
that one selector between rev017 and rev018 and says so at the call site.

Everything else runs for real. In particular `Rev014Upgrade`, which the existing step tests skip by
nudging the version counter past it, is now genuinely executed: its `Remove` of the pre-rev014
`createTask` selector runs against reconstructed pre-rev014 routing rather than being asserted
around.

### 6. Upgrade-step test fixtures

`test/helpers/DiamondTestHelper.sol` gains `placeAtVersion(diamond, version)` and
`deployDiamondAtVersion(...)`, which write `AppStorage.diamondVersion` directly with `vm.store` and
assert the value back through `diamondVersion()`.

This is needed because the seed moved up: a fresh test diamond now lands at rev020, and every step
test needs to start from an earlier revision. `setDiamondVersion` deliberately refuses to decrease
(`DiamondVersionNotIncreasing`) and that guard is not relaxed to make tests convenient — the
counter is written directly instead. Only the counter moves; routing and bytecode remain the
current build's.

The slot is the `AppStorage` base slot plus 29. Every field ahead of `diamondVersion` occupies a
full slot of its own except `defaultFeeBps`/`feeRecipient`, which pack together into one (2 + 20
bytes). `AppStorage` is append-only, so appending a field cannot move this; inserting one would,
which is what the read-back assertion catches.

`Rev012Upgrade.t.sol`'s `"fresh deploy must start at rev011"` assertion is gone. It asserted the
defect.

### 7. Upgrade-step tests must run single-threaded

`forge test -j 1`, which is what `make test` and this package's `test` scripts now pass.

The `RevNNNUpgrade` scripts take their target diamond from `FORGE_DIAMOND_ADDRESS_*`, and
`vm.setEnv` writes the one process-wide environment shared by every concurrently-executing test
suite. Eight test contracts drive those scripts, so running them in parallel lets one suite
retarget another's step mid-sequence — a bare parallel `forge test` fails intermittently, in a
different suite each run. The hazard predates this revision; the sequence test, which drives nine
steps in a row, widened the window enough to make it fire on most runs.

The proper fix is to make the step scripts' target injectable so the tests do not go through
process environment at all. That touches every step script, several of which belong to revisions
still in flight, so it is deliberately not done here. Note that `foundry.toml`'s `threads` key is
not honoured by the test runner; only the CLI flag is.

## Rationale

### Why not repair Path C and keep the bootstrap?

It is the smallest diff and it preserves the recovery path, but it pays the same tax at the next
revision and every one after, and it leaves Path C stamping a version that contradicts the code it
just installed, with paths A, B and C disagreeing with each other. The cost recurs; the benefit is
insurance against a diamond nobody can find.

### Why not make every step idempotent against an already-satisfied state?

Loupe-checking before each `Add`/`Remove` would fix both the fresh-deploy break and the Path C
collision without deleting anything. It was rejected because a step script that silently accepts
either state can no longer assert what it upgraded *from*, and that precondition guard is the
reason the step scripts exist in the form they do. The version counter would still be wrong, and
the guard would have to be added to every past and future step that adds or removes a selector —
the same recurring tax in a new place.

### Why not leave it alone as dead code?

The unreachable bootstrap is dead code, but the seed is not. A fresh deploy on a new chain is
broken by it today, and every sandbox and Anvil diamond in development reports 11 while running
current bytecode.

### What is lost

No automated path remains to bring a pre-rev011 diamond forward. This rests on the observation that
both live diamonds are at 15; a deployment outside those two — a partner fork, an abandoned test
chain — would not have been seen by that check. If one is ever found, its cut must be reconstructed
by hand from git history.

## API Changes

None. No selector is added, removed, or changed. No external interface of `make deploy` or
`make upgrade` changes, beyond `upgrade.sh` now failing rather than bootstrapping when it reads a
`diamondVersion` of 0.

A fresh deploy's `diamondVersion()` now reads 20 instead of 11. Live diamonds are unaffected until
`Rev020Upgrade` is applied.

## Affected Files

| File | Change |
| ---- | ------ |
| `packages/contracts/script/DiamondFullUpgrade.s.sol` | Deleted |
| `packages/contracts/script/upgrade.sh` | Bootstrap branch replaced with a hard failure; header rewritten |
| `packages/contracts/src/libraries/LibRevision.sol` | New — `CURRENT_REVISION` |
| `packages/contracts/src/facets/AdminFacet.sol` | `initialize()` seeds `LibRevision.CURRENT_REVISION` |
| `packages/contracts/src/libraries/LibAppStorage.sol` | `diamondVersion` comment no longer refers to the bootstrap |
| `packages/contracts/script/upgrades/Rev020Upgrade.s.sol` | New — pure `Replace` of `AdminFacet`, sets version 20 |
| `packages/contracts/test/DiamondSelectorParity.t.sol` | Rebuilt around the sequence and seed invariants |
| `packages/contracts/test/helpers/DiamondTestHelper.sol` | `placeAtVersion` / `deployDiamondAtVersion` |
| `packages/contracts/test/Rev012Upgrade.t.sol` … `Rev019Upgrade.t.sol` | Start from an explicitly placed revision; rev011 seed assertion removed |
| `packages/contracts/test/Rev020Upgrade.t.sol` | New |
| `packages/contracts/foundry.toml` | `fs_permissions` read entry; note on single-threaded test runs |
| `packages/contracts/package.json` | `forge test -j 1` |
| `docs/guides/CONTRACTS_GUIDE.md` | Upgrade section no longer describes the bootstrap |
