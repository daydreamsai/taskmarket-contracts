# ERC-8195 Revision 014 — Record `stakeRequired`/`stakeBps` On-Chain at Task Creation

## Motivation

`stakeRequired` and `stakeBps` are requester-chosen, per-task values (whether a worker must post
a stake to claim a Claim-mode task, and the required stake as a fraction of reward) that, before
this revision, existed only in the backend's Postgres row for a task — nothing about them was
ever written on-chain. The backend's own synchronous `create()` write is the only place these
values were ever persisted; if that write failed after the on-chain `createTask` call had already
succeeded (e.g. the server crashed in between), the indexer's `processTaskCreatedEvent`
reconciliation path had to reconstruct the task row from the bare `TaskCreated` event alone and
had no way to recover the requester's real `stakeRequired`/`stakeBps` choice, silently
hardcoding both to `0`. This revision makes both values part of the on-chain `Task` record so
they are recoverable the same way `reward`/`mode`/`expiryTime` already are.

---

## Problem 1 — `stakeRequired`/`stakeBps` had no on-chain equivalent to recover

`processTaskCreatedEvent` (`apps/backend/src/services/indexer.ts`) is a reconciliation-only,
`onConflictDoNothing()` insert that only ever actually applies when the router's synchronous
`create()` write is missing — the narrow crash-recovery window described above. Before this
revision, `createTask` accepted no stake-related parameter at all, and the `Task` struct returned
by `getTask()` had no field describing the requester's stake requirement (`stakeAmount` is a
different, worker-chosen value written later by `claimTask`, not the requester's original
configuration). There was therefore no contract call, live or historical, that could recover the
original `stakeRequired`/`stakeBps` choice once the off-chain write was lost — the reconciliation
path's `0`/`0` hardcode was not a bug that a smarter query could fix; the data genuinely did not
exist on-chain.

---

## Changes

### 1. `ITMPCore.Task` — `stakeRequired`/`stakeBps` fields

```solidity
// Before (rev010)
struct Task {
    bytes32 id;
    address requester;
    address worker;
    TaskStatus status;
    bytes4 mode;
    uint256 reward;
    uint256 expiryTime;
    uint256 stakeAmount;
    uint16 feeBps;
    bytes32 deliverable;
    uint8 rating;
    address hookContract;
}

// After (rev014) -- appended at the end, per this codebase's append-only struct convention
struct Task {
    bytes32 id;
    address requester;
    address worker;
    TaskStatus status;
    bytes4 mode;
    uint256 reward;
    uint256 expiryTime;
    uint256 stakeAmount;
    uint16 feeBps;
    bytes32 deliverable;
    uint8 rating;
    address hookContract;
    bool stakeRequired;
    uint16 stakeBps;
}
```

### 2. `ITMPCore.StakeConfig` — new struct, and `createTask` parameter

```solidity
// New struct -- packs stakeRequired/stakeBps into one calldata pointer, mirroring HookConfig/
// TaskContent, to stay within the Yul stack limit under the --ir-minimum coverage profile.
struct StakeConfig {
    bool required;
    uint16 bps;
}
```

```solidity
// Before (rev010)
function createTask(
    uint256 reward,
    uint256 duration,
    bytes4 mode,
    uint256 pitchDeadline,
    uint256 bidDeadline,
    bytes4 auctionSubtype,
    ITMPCore.HookConfig calldata hookConfig,
    ITMPCore.TaskContent calldata content
) external returns (bytes32 taskId);

// After (rev014)
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
) external returns (bytes32 taskId);
```

`CoreFacet.createTask`'s body now validates `stakeConfig.bps <= 10000` (mirroring the existing
`feeBps`/`FeeBpsTooHigh` pattern) and assigns `t.stakeRequired = stakeConfig.required; t.stakeBps
= stakeConfig.bps;` alongside the other per-task fields it already sets.

### 3. `ITMPCore` — `StakeBpsTooHigh` error

```solidity
error StakeBpsTooHigh();
```

Reverted by `createTask` when `stakeConfig.bps > 10000`.

### 4. `ITMPCore.TaskCreated` — new event fields

```solidity
// Before (rev010)
event TaskCreated(
    bytes32 indexed taskId, address indexed requester, uint256 reward, bytes4 indexed mode, uint256 expiryTime
);

// After (rev014)
event TaskCreated(
    bytes32 indexed taskId,
    address indexed requester,
    uint256 reward,
    bytes4 indexed mode,
    uint256 expiryTime,
    bool stakeRequired,
    uint16 stakeBps
);
```

`stakeRequired`/`stakeBps` are appended as new non-indexed data fields (unpacked from
`stakeConfig` at the emit site); the existing three indexed topics (`taskId`, `requester`,
`mode`) are unchanged, so no client that only reads indexed topics is affected.

### 5. `script/upgrades/Rev014Upgrade.s.sol` — new upgrade step

`createTask`'s signature change also changes its 4-byte selector
(`0x6025c050` -> `0xa595d889`), so this is a `Remove`(old selector) + `Replace`(the 20 unchanged
`CoreFacet` selectors) + `Add`(new selector) cut on `CoreFacet`, not a pure `Replace` like rev013.
`EXPECTED_PRE_VERSION = 13; TARGET_VERSION = 14;`.

---

## Rationale

**Why extend the core `Task` struct instead of enforcing the stake on-chain at claim time?**

`claimTask(taskId, stakeAmount)` already lets the worker choose an arbitrary `stakeAmount`, and
`claims.router.ts` currently always calls it with a hardcoded `0`. Wiring actual on-chain
enforcement of `stakeBps` into `claimTask` is a separate, larger change (validating the worker's
chosen stake against `task.stakeBps * task.reward / 10000`, deciding what happens if the worker
under-stakes, etc.) that was explicitly out of scope for that decision — this revision only
makes the requester's original configuration chain-recoverable, matching `reward`/`mode`/
`expiryTime`'s existing treatment. Enforcement remains a follow-up.

**Why not put `stakeRequired`/`stakeBps` in `TaskMetadata` instead, like `createdAt`/`contentHash`?**

`TaskMetadata` is documented as holding fields "never read by internal contract logic" and is
split out specifically to keep `getTask()`'s ABI encoder within Yul stack limits. `stakeRequired`/
`stakeBps` fit that "never read internally" description today, which made `TaskMetadata` an
initial candidate. It was rejected in favor of the core `Task` struct because the whole point of
this revision is recoverability through the exact same `getTask()` call already used for
`reward`/`mode`/`expiryTime` — the chosen option describes this explicitly — splitting
across two structs and two accessor calls would only partially achieve that. Adding the two small
fields (one `bool`, one `uint16`, packed into a single storage/return word) to `Task` itself did
not reproduce any stack-too-deep failure on the `getTask()` return side, confirmed by `forge
build` and `forge coverage --ir-minimum` both compiling cleanly after this change. If a future
revision needs to add several more fields to `Task` and reintroduces that failure mode, moving to
a satellite struct (following the `TaskMetadata`/`TaskAuctionConfig` precedent) remains available.

**Why pack the two new `createTask` parameters into a `StakeConfig` struct instead of passing them
as two loose scalars (`bool stakeRequired, uint16 stakeBps`)?**

The first implementation attempt did exactly that — two loose scalar parameters inserted between
`auctionSubtype` and `hookConfig`. It compiled cleanly under this repo's default `via_ir = true`
Foundry profile, but `forge coverage --ir-minimum` (the profile `make contract coverage`/
`coverage-check` actually uses, and what CI runs) failed with a genuine Yul "stack too deep"
error inside `createTask`'s own function body — the same failure class `HookConfig`/`TaskContent`
were introduced specifically to avoid, on the parameter side rather than the `getTask()` return
side. Packing `stakeRequired`/`stakeBps` into one `StakeConfig calldata` pointer, mirroring the
`HookConfig`/`TaskContent` precedent exactly, resolved it — verified by re-running both `forge
build` and `forge coverage --ir-minimum` clean after the change. This is a case where the
default-profile build alone was not sufficient evidence that a signature change is coverage-safe;
the `--ir-minimum` profile needs to be checked too.

**Why validate `stakeBps <= 10000` on-chain if it is not yet enforced against the worker's actual
stake?**

The same range constraint already exists off-chain (`packages/shared/src/schemas/task.schemas.ts`'s
`z.number().min(0).max(10000)`) and mirrors the existing `feeBps` pattern
(`AdminFacet.setDefaultFeeBps`'s `FeeBpsTooHigh` check). Rejecting an out-of-range value at the
source of truth is strictly better than silently accepting a nonsensical basis-points figure that
would only be caught later, if at all, by an off-chain consumer.

---

## API Changes

- `createTask`'s calldata ABI changes: a new `ITMPCore.StakeConfig calldata` parameter
  (`{ bool required; uint16 bps; }`) inserted between `auctionSubtype` and `hookConfig`. Any
  off-chain caller encoding this call directly (rather than through the backend) must update its
  ABI.
- `TaskCreated`'s event ABI changes: two new non-indexed data fields appended
  (`stakeRequired`, `stakeBps`). Indexed topics are unchanged.
- `getTask()`'s returned `Task` tuple gains two new trailing fields (`stakeRequired`, `stakeBps`).
- New error: `ITMPCore.StakeBpsTooHigh()`.
- Backend: `apps/backend/src/services/contract.ts`'s `contractCreateTask` and
  `apps/backend/src/routers/tasks.router.ts`'s `create()` now pass the requester's
  `stakeRequired`/`stakeBps` input through to the on-chain call (previously computed for the DB
  write only). `apps/backend/src/services/indexer.ts`'s `processTaskCreatedEvent` now decodes
  `stakeRequired`/`stakeBps` from the `TaskCreated` event instead of hardcoding `0`/`0`.
  `apps/backend/src/services/settlement-contract.ts`'s `SETTLEMENT_READ_ABI.getTask` tuple gains
  matching trailing fields.

## Affected Files

| File | Change |
|------|--------|
| `src/interfaces/ITMPCore.sol` | Append `stakeRequired`/`stakeBps` to `Task`; add `StakeConfig` struct; add `stakeRequired`/`stakeBps` to `TaskCreated`; add `StakeBpsTooHigh` error; add `stakeConfig` param to `createTask` declaration |
| `src/interfaces/ITMPDiamond.sol` | Mirror `createTask` parameter change |
| `src/facets/CoreFacet.sol` | Add `stakeConfig` param to `createTask`; validate `stakeConfig.bps <= 10000`; assign `t.stakeRequired`/`t.stakeBps`; update `TaskCreated` emit |
| `script/upgrades/Rev014Upgrade.s.sol` | New upgrade-step script -- Remove old `createTask` selector, Replace unchanged `CoreFacet` selectors, Add new `createTask` selector |
| `test/TaskMarket.t.sol`, `test/ITMP.t.sol`, `test/TaskMarketForwarder.t.sol`, `test/TaskTokenRewardHook.t.sol` | Update `createTask` call sites and `TaskCreated` event assertions for the new signature |
| `apps/backend/src/services/contract.ts` | `MARKET_ABI` and `contractCreateTask` accept and encode `stakeRequired`/`stakeBps` as a `(bool,uint16)` tuple |
| `apps/backend/src/routers/tasks.router.ts` | Pass `input.stakeRequired`/`input.stakeBps` to `contractCreateTask` |
| `apps/backend/src/services/indexer.ts` | `TASK_CREATED_EVENT` ABI and `processTaskCreatedEvent` decode `stakeRequired`/`stakeBps` from the event instead of hardcoding `0` |
| `apps/backend/src/services/settlement-contract.ts` | `SETTLEMENT_READ_ABI.getTask` gains `stakeRequired`/`stakeBps` fields |
| `docs/adr/0028-task-created-reconciliation-cannot-recover-off-chain-only-create-inputs.md` | Status updated to `Accepted`; records this as the chosen follow-up |
