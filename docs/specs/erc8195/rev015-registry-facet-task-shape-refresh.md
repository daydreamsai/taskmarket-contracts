# ERC-8195 Revision 015 — Redeploy `RegistryFacet` So `getTask()` Returns the rev014 `Task` Fields

## Motivation

Rev014 appended `stakeRequired` and `stakeBps` to the shared `ITMPCore.Task` struct and changed
`CoreFacet.createTask` to write them. Its diamond cut replaced only `CoreFacet`. `RegistryFacet`
was not redeployed.

`RegistryFacet.getTask()` returns `ITMPCore.Task memory` by value. The return encoding is fixed in
the facet's bytecode when it is compiled, so the deployed `RegistryFacet` kept ABI-encoding the
struct shape it was built against: the pre-rev014 12-field tuple (384 bytes), not the 14-field
tuple (448 bytes) that current source declares. The new fields were stored on-chain by `createTask`
but no read path returned them.

This revision redeploys `RegistryFacet` from current source so `getTask()` returns `stakeRequired`
and `stakeBps` to any caller.

---

## Problem — stale return encoding in an un-replaced facet

After rev014 on Base mainnet, `getTask()` returned 12 words. The commit that introduced this
upgrade records that this was confirmed directly on-chain with `cast`. A backend decoder built
against the 14-field ABI read past the end of the returned data and failed in the indexer's
startup event replay the first time it read a task settled after rev014. The backend was changed
separately to decode only the 12-field prefix that was live, which stays correct whether or not
this upgrade has been applied, because tuple decoding only needs the declared prefix.

The general point: changing a struct that several facets share does not change a facet that is not
redeployed. Any facet whose functions take or return that struct must be part of the same cut.

---

## Changes

### 1. `RegistryFacet` — redeployed, no source change in this revision

No contract source changed in this revision. The new `RegistryFacet` is a fresh deployment of the
existing source, compiled against the rev014 `ITMPCore.Task`.

### 2. Diamond cut — single `Replace`

| Facet | Action | Selectors |
|-------|--------|-----------|
| `RegistryFacet` (new deployment) | `Replace` | every selector in `FacetSelectors.registryFacetSelectors()` |

No `Add` or `Remove` is needed. No `RegistryFacet` function signature changed; only the return
type of `getTask()` widened, and a return type is not part of a selector. This differs from
rev014, where `createTask` gained a parameter, so its selector changed and the cut had to `Remove`
the old one and `Add` the new one.

The cut has no initializer (`_init = address(0)`, empty calldata). There are no storage changes
and no new setters.

Note: `registryFacetSelectors()` is a shared list that later revisions have extended. The exact
selector set replaced when rev015 was applied is the list as it stood at that time; it is not
reproduced here.

### 3. Version

`Rev015Upgrade` requires `diamondVersion() == 14` before cutting and calls
`setDiamondVersion(15)` afterwards.

---

## Upgrade Procedure

`script/upgrades/Rev015Upgrade.s.sol`:

1. Check `AdminFacet.diamondVersion() == 14`, otherwise revert with
   `"Rev015Upgrade: diamond is not at rev014"`.
2. Deploy a new `RegistryFacet`.
3. `diamondCut` with one `Replace` of `FacetSelectors.registryFacetSelectors()` to the new facet.
4. `setDiamondVersion(15)`.

Required env vars: `FORGE_DEV_PRIVATE_KEY` (Diamond owner), `FORGE_DIAMOND_ADDRESS_TESTNET`
(Base Sepolia, chain 84532), `FORGE_DIAMOND_ADDRESS_MAINNET` (Base mainnet, chain 8453).

Normally applied by `make upgrade <testnet|mainnet>` as part of the pending-steps sequence; a single
step runs with `make upgrade testnet rev015` or `make upgrade mainnet rev015`.

---

## Compatibility

- No selector, event, error or storage change.
- `getTask()`'s returned tuple gains two trailing fields on-chain (`bool stakeRequired`,
  `uint16 stakeBps`), matching the struct rev014 declared. Decoders that read only the 12-field
  prefix keep working; decoders that expect 14 fields work only once this revision is applied.
- Other `RegistryFacet` reads return the same data, served from the new facet address.

## Affected Files

| File | Change |
|------|--------|
| `script/upgrades/Rev015Upgrade.s.sol` | New upgrade-step script: deploy `RegistryFacet`, `Replace` all registry selectors, set version 15 |
| `.gas-snapshot` | Snapshot entries added with the script |
