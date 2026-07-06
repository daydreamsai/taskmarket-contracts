# ERC-8195 Revision 009 — Accept-Submissions Pinning and Expiry Validation Fix

## Motivation

Two bugs surfaced from community feedback:

1. **`--extend-expiry` CLI sends past timestamps to the contract.** The `update` command
   computes `currentExpiry + delta` but never checks whether the result is still in the future.
   A task that expired several days ago will have a past `expiryTime`. Adding any number of
   seconds to a past timestamp produces another timestamp that may still be in the past,
   causing the contract to revert with `ExpiryMustBeInFuture` (0x3583314c). The user sees
   a raw hex error with no actionable guidance.

2. **Submission pinning is documented but unshipped.** The public `skill.md` and
   `reference/split-acceptance.md` pages describe a three-part `<addr>:<share>:<submissionId>`
   winner spec for `accept-submissions` that allows requesters to pin a specific submission
   version when accepting a multi-winner bounty or benchmark. The CLI explicitly rejects any
   third token, and the contract always resolves to a worker's latest on-chain submission hash.
   Requesters with multiple worker re-submissions cannot choose which version to pay for.

The root cause of the pinning gap is that `acceptSubmissions` on-chain has no deliverables
parameter. It always calls `submitted[submitted.length - 1]`, giving the requester no way to
select an earlier hash.

## Changes

### Contract — `AcceptanceFacet.sol`

The `acceptSubmissions` function gains a new `bytes32[] calldata deliverables` parameter between
`shares` and `requesterAgentId`:

```
// before (4-param):
acceptSubmissions(bytes32 taskId, address[] workers, uint16[] shares, uint256 requesterAgentId)

// after (5-param):
acceptSubmissions(bytes32 taskId, address[] workers, uint16[] shares, bytes32[] deliverables, uint256 requesterAgentId)
```

Semantics:
- `deliverables` is empty (`length == 0`): auto-resolve each winner's latest submission (backward-compatible default).
- `deliverables` is same-length as `workers`: use `deliverables[i]` for worker `i`. A zero
  element (`bytes32(0)`) in a specific slot still auto-resolves that slot.
- Any other length reverts with `LengthMismatch`.

A pinned hash must satisfy `taskSubmissionHashExists[taskId][worker][hash] == true`; otherwise
the call reverts with `SubmissionNotFound`.

### Interface — `ITMPCore.sol`

The `acceptSubmissions` declaration is updated to match the new 5-param signature.

### Interface — `ITMPDiamond.sol` (new)

`test/helpers/ITaskMarketFull.sol` is promoted to `src/interfaces/ITMPDiamond.sol` and renamed
to `ITMPDiamond`. External integrators calling the Diamond proxy through a single typed interface
faced the same problem as tests. The file now lives in the published interface surface alongside
`ITMPCore.sol`. The old file is retained for compatibility (imports the new one).

### Upgrade script — `DiamondUpgradeAcceptPinning.s.sol` (new)

Atomically removes the old 4-param selector and adds the new 5-param selector in a single
`diamondCut` call so `acceptSubmissions` is never unrouted between the two operations:

```
cuts[0] = Remove: acceptSubmissions(bytes32,address[],uint16[],uint256)
cuts[1] = Add:    acceptSubmissions(bytes32,address[],uint16[],bytes32[],uint256)
```

Invoked via `make upgrade-accept-pinning testnet|mainnet`.

### Backend — `acceptance.schemas.ts`

The winner object gains an optional `submissionId: z.string()` field.

### Backend — `acceptance.router.ts`

Before calling the contract, the router now resolves per-winner deliverable hashes from the DB:

- If `submissionId` is absent: pass `bytes32(0)` (auto-resolve).
- If `submissionId` is present: look up `submissions.deliverableHash` where
  `id = submissionId AND taskId = taskId AND workerAddress = worker AND rejectedAt IS NULL`.
  - Not found: `BAD_REQUEST`.
  - Found but `deliverableHash` is null (pre-hash-tracking submission): `BAD_REQUEST` with a
    message explaining the submission predates on-chain hash tracking.
  - Found and hashed: pass the hash as the pinned deliverable.

### Backend — `contract.ts`

`contractAcceptSubmissions` gains a `deliverables: readonly \`0x${string}\`[]` parameter at
position 5 and encodes it in the calldata.

### CLI — `accept-submissions.ts`

`parseWinner` now accepts 2 or 3 colon-separated parts. The third part, if present, is the
string `submissionId` from the DB (not an integer). The winner type and the x402 POST body
both include the optional field.

Help text is updated to show the 3-part example.

### CLI — `update.ts`

`--extend-expiry` validation is strengthened:
- Rejects values `< 1` (0 is not useful; was previously `< 0`).
- Fetches the task's current `expiryTime` from the API.
- Computes `newExpiry = currentExpiry + delta`.
- If `newExpiry <= now`: prints a human-readable error showing how many seconds ago the task
  expired and the minimum delta required to extend it into the future; does not call the contract.

## Rationale

**Why `bytes32(0)` for auto-resolve?** Zero is the natural sentinel in Solidity and costs the
least gas to pass. Callers that want all slots auto-resolved pass an empty array (zero overhead).

**Why not a separate `acceptSubmissionsPinned` function?** A parallel function would require
separate ABI and routing entries, duplicate almost all of `_acceptSubmissions`, and fragment
the interface. A parameter with a zero-sentinel default is the minimal, backward-compatible
extension — callers on the old ABI can migrate by prepending an empty array.

**Why promote `ITaskMarketFull` to `src/interfaces/ITMPDiamond.sol`?** The Diamond proxy
dispatches all calls from a single address. Callers (external contracts, integrators, tests)
need a unified interface to avoid per-facet casting. Keeping this file in `test/helpers/` was
an oversight; the problem it solves is not test-specific.

## Affected Files

| File | Change |
|------|--------|
| `src/facets/AcceptanceFacet.sol` | New 5-param `acceptSubmissions`, pinning loop in `_acceptSubmissions` |
| `src/interfaces/ITMPCore.sol` | Updated `acceptSubmissions` declaration |
| `src/interfaces/ITMPDiamond.sol` | New file (promoted from `test/helpers/ITaskMarketFull.sol`) |
| `script/DiamondUpgradeAcceptPinning.s.sol` | New atomic selector-swap upgrade script |
| `script/DiamondFullUpgrade.s.sol` | Added `PREV_ACCEPT_SUBMISSIONS` constant; updated `_runReplace` to Remove+Add for changed selector |
| `test/helpers/DiamondTestHelper.sol` | Returns `ITMPDiamond` instead of `ITaskMarketFull` |
| `test/TaskMarket.t.sol` | Updated all `acceptSubmissions` call sites to 5-param |
| `apps/backend/src/schemas/acceptance.schemas.ts` | `submissionId?: string` added to winner schema |
| `apps/backend/src/routers/acceptance.router.ts` | Deliverable hash resolution before contract call |
| `apps/backend/src/services/contract.ts` | New `deliverables` param in `contractAcceptSubmissions` |
| `apps/cli/src/commands/task/accept-submissions.ts` | 3-part winner spec parsing |
| `apps/cli/src/commands/task/update.ts` | Future-check guard on `--extend-expiry` |

## Selector Change

| | Selector (keccak256) |
|-|----------------------|
| Old `acceptSubmissions(bytes32,address[],uint16[],uint256)` | `0x...` (4-param) |
| New `acceptSubmissions(bytes32,address[],uint16[],bytes32[],uint256)` | `0x...` (5-param) |

The old selector must be hardcoded in `DiamondUpgradeAcceptPinning.s.sol` because the source
no longer compiles the old signature.
