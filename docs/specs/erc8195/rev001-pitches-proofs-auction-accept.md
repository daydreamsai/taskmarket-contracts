# ERC-8195 Revision 001 — On-Chain Pitches, Proofs, and Auction Accept

**Revision:** 001
**Date:** 2026-05-14
**PRs:** https://github.com/daydreamsai/taskmarket-contracts/pull/2, https://github.com/daydreamsai/taskmarket-contracts/pull/4

## Motivation

The initial ERC-8195 draft described Pitch mode, Benchmark mode, and Dutch/reverse-Dutch
auction acceptance as first-class task flows, but left all three without any on-chain trace.
Pitch submissions, benchmark proof submissions, and dutch auction acceptances occurred entirely
off-chain, making it impossible for third parties to verify worker activity, detect front-running,
or build indexers that reflect the true state of a task. This revision promotes all three flows
to normative on-chain status and fixes a confusing event naming inconsistency in the process.

---

## Problem 1 — Pitch and benchmark flows had no on-chain evidence

`submitPitch` and `submitProof` were described in the spec but not normative. No events were
required. A pitch could be submitted off-chain, attributed to any worker, and repudiated or
replayed across tasks without detection. Benchmark proofs claimed metric values with no
tamper-evident anchor. Any third party relying on off-chain content had to trust the operator
entirely.

## Problem 2 — Dutch/reverse-Dutch auction acceptance produced ambiguous events

`acceptAuction` emitted the legacy pair `BidSubmitted + TaskWorkerSelected` to signal acceptance.
These two events were designed for bid-based flows; repurposing them for clock-price acceptance
forced indexers to interpret a `BidSubmitted` event that did not represent a bid. New indexers
had no clean signal to distinguish a price-clock acceptance from a bid submission.

## Problem 3 — Hash commitments lacked domain separation

Without a normative encoding rule, implementations could compute pitch and proof hashes
inconsistently. A hash computed without binding the task ID and worker address could be
replayed: a pitch submitted to one task would match the on-chain hash for another, or content
could be attributed to the wrong worker.

## Problem 4 — `TaskAccepted` event name misrepresented the terminal state

The terminal success event was named `TaskAccepted`, matching the `TaskStatus.Accepted` enum
value. However, "accepted" is a mid-flow term in Pitch and Auction modes — the worker is
accepted, not the task outcome. The event name created confusion between the ongoing status
and the completed state.

---

## Changes

### 1. Three new normative events added to `ITMPCore`

```solidity
// Before (rev000 — not present)
// No events for pitch, proof, or auction acceptance.

// After (rev001)
event PitchSubmitted(bytes32 indexed taskId, address indexed worker, bytes32 pitchHash);
event ProofSubmitted(
    bytes32 indexed taskId,
    address indexed worker,
    bytes32 proofHash,
    bytes32 proofType,
    uint256 metricValue
);
event AuctionAccepted(bytes32 indexed taskId, address indexed worker, uint256 acceptedPrice);
```

`PitchSubmitted` is emitted by `submitPitch` and anchors the pitch content commitment on-chain.
`ProofSubmitted` is emitted by `submitProof` and anchors the benchmark proof commitment and
claimed metric value. `AuctionAccepted` is emitted by `acceptAuction` for Dutch and reverse-Dutch
flows. It coexists with the legacy `BidSubmitted + TaskWorkerSelected` pair so existing indexers
keep working; new indexers should prefer this single event.

### 2. Two new normative functions added to `ITMPCore`

```solidity
// Before (rev000 — not present)

// After (rev001)
function submitPitch(bytes32 taskId, bytes32 pitchHash) external;

function submitProof(
    bytes32 taskId,
    bytes32 proofHash,
    bytes32 proofType,
    uint256 metricValue
) external;
```

`submitPitch` is valid for Pitch-mode tasks in `Open` status before `pitchDeadline`. The worker
is the authenticated actor. `submitProof` is valid for Benchmark-mode tasks. `proofType` is
`bytes32(keccak256(typeString))` (e.g. `"tlsn"`, `"zk"`, `"eval"`). `metricValue` is the
claimed benchmark result as a task-specific integer.

Both functions append to per-task arrays rather than writing a single slot, so multiple workers
may submit concurrently without overwriting each other:

```solidity
// Storage additions (append-only, consuming from __gap)
mapping(bytes32 => bytes32[]) public taskPitchHashes;  // slot 10
mapping(bytes32 => bytes32[]) public taskProofHashes;  // slot 11
// __gap shrunk from 48 -> 46
```

### 3. Domain-separation rule (normative)

```solidity
// Before (rev000) — no encoding rule; implementations varied

// After (rev001) — compliant backends MUST compute:
// pitchHash = keccak256(abi.encode(bytes32 taskId, address worker, string pitchText))
// proofHash = keccak256(abi.encode(bytes32 taskId, address worker, string proofData))
```

`abi.encode` (not `abi.encodePacked`) is required to avoid length ambiguity on variable-length
strings. This binding ensures a pitch submitted to one task cannot match the on-chain hash for
another and prevents operators from attributing content to the wrong worker.

### 4. `TaskAccepted` event renamed to `TaskCompleted`

```solidity
// Before (rev000)
event TaskAccepted(bytes32 indexed taskId, address indexed worker, bytes32 deliverable);

// After (rev001)
event TaskCompleted(bytes32 indexed taskId, address indexed worker, bytes32 deliverable);
```

The new name reflects the terminal success state unambiguously and avoids confusion with
mid-flow "accepted" semantics in Pitch and Auction modes.

### 5. State-machine annotations updated

**Pitch Mode:** The previous annotation `--[submitPitch*]----> Open (pitch recorded off-chain)`
was inaccurate. Updated to reflect that pitch hashes are anchored on-chain via `PitchSubmitted`.

**Benchmark Mode:** `submitProof*` is added as a first-class transition. Validation Registry
acceptance remains a supported alternative acceptance path for automated benchmark evaluation.

**Auction Mode:** `acceptAuction*` is added for Dutch and reverse-Dutch flows. The legacy
`BidSubmitted + TaskWorkerSelected` event pair is documented as OPTIONAL for backward
compatibility; new indexers should use `AuctionAccepted`.

### 6. Part IV renamed: "Deliverable Anchoring" to "Content Anchoring"

Generalized to cover all three anchor types (deliverable, pitch, proof) with a shared normative
section on domain separation and a table mapping each anchor to its function, storage location,
and event.

### 7. Indexer event requirements extended

Part VIII now requires the three new events with their full argument lists. `PitchSubmitted`
MUST include `taskId`, `worker`, and `pitchHash`. `ProofSubmitted` MUST include all five fields.
`AuctionAccepted` MUST include `taskId`, `worker`, and `acceptedPrice`.

---

## Rationale

**Why not enforce domain separation in-contract by accepting `string content` calldata?**

Requiring the contract to recompute the hash from raw content would make the hash derivation
trustless but doubles calldata cost for large pitch texts and proof strings. The current approach
keeps content off-chain (cheaper) while providing a backend-level invariant any third party can
verify against operator-served content. If in-contract enforcement becomes necessary for a
specific deployment, it can be layered on top via a hook without a spec change.

**Why should `submitPitch` and `submitProof` be REQUIRED rather than OPTIONAL?**

Marking them optional would allow compliant implementations to omit on-chain anchoring entirely,
making third-party verification impossible and defeating the purpose of this revision. Modes that
do not use these functions (e.g. Claim, Auction) simply never call them; the interface overhead
is two function selectors. Implementations that support Pitch or Benchmark MUST emit the events.

**Why add `AuctionAccepted` alongside the legacy event pair instead of replacing it?**

Replacing `BidSubmitted + TaskWorkerSelected` in the Dutch/reverse-Dutch path would break all
existing indexers consuming those events. The additive approach gives new implementations a clean
signal without forcing a breaking migration on deployed consumers.

**Why rename `TaskAccepted` to `TaskCompleted`?**

"Accepted" describes a state transition (a worker or submission is accepted) rather than the
terminal outcome. Indexers that treat the event as a task-lifecycle signal need a name that
unambiguously means "this task is done." `TaskCompleted` is unambiguous; `TaskAccepted` was
overloaded.

---

## API Changes

- `TaskAccepted` event removed; `TaskCompleted` replaces it. Indexers consuming `TaskAccepted`
  must update their event filter. This is a **breaking change**.
- `PitchSubmitted`, `ProofSubmitted`, and `AuctionAccepted` events added. Indexers MUST subscribe
  to these events to track pitch, proof, and Dutch auction acceptance activity.
- `submitPitch(bytes32, bytes32)` and `submitProof(bytes32, bytes32, bytes32, uint256)` added to
  `ITMPCore`. Implementations that pre-date this revision remain compliant but will lack on-chain
  pitch and proof anchoring.

---

## Affected Files

| File | Change |
|------|--------|
| `src/interfaces/ITMPCore.sol` | Add `PitchSubmitted`, `ProofSubmitted`, `AuctionAccepted` events; rename `TaskAccepted` to `TaskCompleted`; add `submitPitch` and `submitProof` function signatures |
| `src/TaskMarket.sol` | Implement `submitPitch` and `submitProof`; emit `AuctionAccepted` from `acceptAuction`; emit `TaskCompleted` in place of `TaskAccepted` |
| `src/storage/TaskMarketStorage.sol` | Append `taskPitchHashes` (slot 10) and `taskProofHashes` (slot 11); shrink `__gap` from 48 to 46 |
| `docs/specs/erc8195/erc-8195.md` | Update Pitch/Benchmark/Auction state machine diagrams; update Part IV to "Content Anchoring"; extend Part VIII indexer event requirements |
| `test/TaskMarket.t.sol` | Add tests for `submitPitch`, `submitProof`, `AuctionAccepted`; update event assertions from `TaskAccepted` to `TaskCompleted` |
