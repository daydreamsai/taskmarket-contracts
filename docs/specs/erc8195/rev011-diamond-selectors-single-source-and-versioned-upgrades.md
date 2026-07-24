# ERC-8195 Revision 011 — Shared Facet Selector Source and Explicit `diamondVersion`

## Motivation

Every diamond upgrade or fresh deploy needs the exact set of function selectors routed to each
facet. Before this revision that list was maintained independently in three places
(`DiamondDeploy.s.sol`, `DiamondFullUpgrade.s.sol`'s steady-state Replace path, and
`DiamondTestHelper.sol`), with no mechanism forcing them to agree. This revision consolidates
selector lists into one shared source and adds an explicit on-chain version counter so a
diamond's upgrade-step revision is a queryable fact instead of something inferred from which
selectors happen to be present.

---

## Problem 1 — Three independently maintained selector lists had already drifted

`DiamondDeploy.s.sol`'s `RegistryFacet` selector list was stale, missing 8 selectors that were
already present in `DiamondFullUpgrade.s.sol`'s canonical steady-state list. `DiamondTestHelper.sol`
carried a third, independently drifted `RegistryFacet` list. A fresh deploy, an upgraded diamond,
and a test fixture diamond could each expose a different set of callable functions with no test
catching the divergence.

## Problem 2 — No on-chain record of which upgrade revision a diamond is at

`DiamondFullUpgrade.s.sol` decided which migration path to run (`Path A` / `Path B` / `Path C`)
by probing the diamond via `IDiamondLoupe.facetAddress(...)` for the presence or absence of
specific old selectors. This worked but left a diamond's revision state implicit and fragile —
every future upgrade script would need to keep adding its own presence/absence heuristics rather
than reading a single fact.

---

## Changes

### 1. `script/lib/FacetSelectors.sol` — new shared selector library

```solidity
// New file
library FacetSelectors {
    function cutFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function loupeFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function adminFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function coreFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function auctionFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function acceptFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function evalFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function ratingFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
    function registryFacetSelectors() internal pure returns (bytes4[] memory s) { ... }
}
```

Each function is the single canonical, steady-state selector set for one facet, built from
`Facet.function.selector` member access (so it tracks a facet's real signatures automatically
whenever a facet's source changes) rather than hardcoded 4-byte literals. `DiamondDeploy.s.sol`,
`DiamondFullUpgrade.s.sol`'s steady-state `_runReplace` path, and `DiamondTestHelper.sol` were
rewritten to call these functions instead of maintaining their own copies.

### 2. `LibAppStorage.AppStorage` — `diamondVersion` field

```solidity
// Appended at end of AppStorage struct
// Rev011: explicit upgrade-step counter, tracking the same revision numbering already used
// throughout this codebase's comments (rev007, rev008, ...).
uint256 diamondVersion;
```

### 3. `AdminFacet` — `diamondVersion()` / `setDiamondVersion()`

```solidity
// Before (rev010) — no version accessor existed

// After (rev011)
function diamondVersion() external view returns (uint256) {
    return LibAppStorage.appStorage().diamondVersion;
}

function setDiamondVersion(uint256 newVersion) external onlyOwner {
    AppStorage storage s = LibAppStorage.appStorage();
    if (newVersion < s.diamondVersion) revert ITMPCore.DiamondVersionNotIncreasing();
    s.diamondVersion = newVersion;
}
```

`initialize()` (the fresh-deploy path) also seeds `s.diamondVersion = 11`, since a fresh deploy
already includes the full rev011 steady-state selector set and should not start at 0.

### 4. `ITMPCore` — `DiamondVersionNotIncreasing` error

```solidity
error DiamondVersionNotIncreasing();
```

Reverted by `setDiamondVersion` if called with a version at or below the current one, so an
upgrade step script cannot silently re-apply out of order or move the counter backwards.

### 5. `DiamondFullUpgrade.s.sol` — all three migration paths now set `diamondVersion`

Every path (`_runWithMigration`, `_runRev010Migration`, `_runReplace`) now also cuts in
`AdminFacet.diamondVersion`/`setDiamondVersion` (absent on every diamond upgraded before this
revision) and calls `setDiamondVersion(11)` once its cut lands. From rev011 onward, every future
upgrade is a small, single-purpose script under `script/upgrades/RevNNNUpgrade.s.sol` that asserts
its own `EXPECTED_PRE_VERSION` precondition and bumps `TARGET_VERSION` on success, applied via
`make upgrade <network> [revNNN]` — see `script/upgrade.sh`.

### 6. `test/DiamondSelectorParity.t.sol` — new drift-detection test

Deploys a diamond fresh via `DiamondDeploy.s.sol`, separately brings a simulated old diamond to
steady state via `DiamondFullUpgrade.s.sol`'s `_runReplace` path, and asserts both end up with an
identical per-facet selector set via `IDiamondLoupe.facets()`. This is the actual enforcement
mechanism: a future edit that reintroduces a second, independently maintained selector list would
fail this test rather than silently drifting again.

---

## Rationale

**Why a shared library instead of just fixing the two stale lists?**

Fixing the immediate drift would not prevent it from recurring — a future facet function added to
one call site but not the others would reintroduce the exact same bug class. A single source that
every caller references, backed by a parity test, makes the drift structurally harder to
reintroduce rather than relying on reviewers to notice by hand.

**Why version selectors by presence/absence detection rather than a version counter, historically?**

That was the pre-existing approach (`DiamondFullUpgrade.s.sol`'s Path A/B/C), and it is not
removed by this revision — it is what gets a pre-rev011 diamond to rev011 in the first place, and
remains necessary for that one-time bootstrap since such diamonds have no version field to read.
It was not replaced going forward because a diamond, once at rev011, can always be trusted to
report its own version explicitly.

**Why seed `diamondVersion` at 11 instead of 1?**

Each diamond upgrade already corresponds to one of this codebase's existing numbered revisions
(`rev007`, `rev008`, ...). Starting a parallel "version 1" counter would create two competing
numbering schemes for the same underlying history. Backfilling to 11 (the revision this change
itself is) keeps a single number line.

**Why a monotonic guard (`DiamondVersionNotIncreasing`) instead of allowing arbitrary sets?**

An upgrade-step script asserts its own `EXPECTED_PRE_VERSION` before running, so the guard is a
second line of defense: even if a script were run out of order or against the wrong diamond, the
counter itself cannot be moved backwards or reapplied to an already-passed version, which would
otherwise make `diamondVersion` an unreliable source of truth for downstream tooling.

---

## API Changes

- New view function: `AdminFacet.diamondVersion() external view returns (uint256)` — returns 0
  for any diamond deployed before this revision.
- New owner-only function: `AdminFacet.setDiamondVersion(uint256 newVersion) external` — not
  intended for end users; called exclusively by upgrade-step scripts.
- New error: `ITMPCore.DiamondVersionNotIncreasing()`.
- No change to any existing function signature, event, or task-facing behavior.

## Affected Files

| File | Change |
|------|--------|
| `script/lib/FacetSelectors.sol` | New file — one canonical selector-list function per facet |
| `script/DiamondDeploy.s.sol` | Use `FacetSelectors.*` instead of independently maintained lists (fixes stale `RegistryFacet` list) |
| `script/DiamondFullUpgrade.s.sol` | Use `FacetSelectors.*` in the steady-state `_runReplace` path; all three paths add and set `diamondVersion` |
| `src/facets/AdminFacet.sol` | Add `diamondVersion()`/`setDiamondVersion()`; seed `diamondVersion = 11` in `initialize()` |
| `src/interfaces/ITMPCore.sol` | Add `error DiamondVersionNotIncreasing()` |
| `src/libraries/LibAppStorage.sol` | Append `uint256 diamondVersion` to `AppStorage` |
| `test/helpers/DiamondTestHelper.sol` | Use `FacetSelectors.*` instead of an independently maintained list |
| `test/DiamondSelectorParity.t.sol` | New file — fresh-deploy vs. upgraded-diamond selector parity test |
| `test/TaskMarket.t.sol` | Add `diamondVersion`/`setDiamondVersion` coverage |
| `docs/adr/0011-diamond-selectors-single-source-and-versioned-upgrades.md` | ADR recording this decision |
