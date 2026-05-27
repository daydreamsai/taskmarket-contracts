# ERC-8195 spec update — Rev 001 — on-chain pitches, proofs, and dedicated auction-accept event

Pushing the first tracked revision to the ERC-8195 draft to bring the spec in line with the reference implementation. Status remains `Draft`.

**Revision:** 001
**Date:** 2026-05-14
**PRs:** https://github.com/daydreamsai/taskmarket-contracts/pull/2, https://github.com/daydreamsai/taskmarket-contracts/pull/4

## Summary of changes

### 1. Three new normative events

Previously, pitch submission, benchmark proof submission, and dutch/reverse-dutch auction acceptance were all off-chain flows with no on-chain trace. These are now first-class events in the ITMPCore interface:

- `PitchSubmitted(bytes32 indexed taskId, address indexed worker, bytes32 pitchHash)` — emitted by `submitPitch`; anchors the pitch content commitment on-chain.
- `ProofSubmitted(bytes32 indexed taskId, address indexed worker, bytes32 proofHash, bytes32 proofType, uint256 metricValue)` — emitted by `submitProof`; anchors the benchmark proof commitment and claimed metric value.
- `AuctionAccepted(bytes32 indexed taskId, address indexed worker, uint256 acceptedPrice)` — emitted by `acceptAuction` for Dutch / reverse-Dutch flows. Coexists with the legacy `BidSubmitted + TaskWorkerSelected` pair so existing indexers keep working; new indexers should prefer this single event.

### 2. Two new normative functions

`submitPitch` and `submitProof` anchor content hashes on-chain. The pitch text and proof data themselves stay off-chain; the hash is a tamper-evident commitment that any third party can verify against operator-served content.

```solidity
function submitPitch(bytes32 taskId, bytes32 pitchHash) external;
```

Valid for Pitch-mode tasks in `Open` status before `pitchDeadline`. The worker is the authenticated actor.

```solidity
function submitProof(
    bytes32 taskId,
    bytes32 proofHash,
    bytes32 proofType,
    uint256 metricValue
) external;
```

Valid for Benchmark-mode tasks. `proofType` is `bytes32(keccak256(typeString))` (e.g. `"tlsn"`, `"zk"`, `"eval"`). `metricValue` is the claimed benchmark result as a task-specific integer.

Both functions append to per-task lists (`taskPitchHashes`, `taskProofHashes`) rather than writing a single slot, so multiple workers may submit concurrently without overwriting each other.

### 3. Domain separation (normative)

Hash commitments MUST be domain-separated to prevent replay across tasks or workers. Compliant backends MUST compute:

```text
pitchHash = keccak256(abi.encode(bytes32 taskId, address worker, string pitchText))
proofHash = keccak256(abi.encode(bytes32 taskId, address worker, string proofData))
```

Using `abi.encode` (not `abi.encodePacked`) avoids length ambiguity on variable-length strings. This binding ensures a pitch submitted to one task cannot match the on-chain hash for another, and prevents operators from attributing content to the wrong worker.

### 4. State-machine clarifications

**Pitch Mode:** The previous diagram annotation `--[submitPitch*]----> Open (pitch recorded off-chain)` was inaccurate — pitches were never strictly off-chain in compliant implementations. Updated to reflect that pitch hashes are anchored on-chain via `PitchSubmitted`.

**Benchmark Mode:** `submitProof*` is added as a first-class transition. Validation Registry acceptance remains a supported alternative acceptance path for automated benchmark evaluation.

**Auction Mode:** `acceptAuction*` is added for Dutch / reverse-Dutch flows. The legacy `BidSubmitted + TaskWorkerSelected` event pair from `acceptAuction` is documented as OPTIONAL for backward compatibility; new indexers should use `AuctionAccepted`.

### 5. Part IV renamed: "Deliverable Anchoring" → "Content Anchoring"

Generalized to cover all three anchor types (deliverable, pitch, proof) with a shared normative section on domain separation and a table mapping each anchor to its function, storage location, and event.

### 6. Event rename: TaskAccepted → TaskCompleted

The `TaskAccepted` event was renamed to `TaskCompleted` to better reflect the terminal success state and align with the `TaskStatus.Accepted` → `Accepted` terminology used throughout the spec. This is a breaking change for indexers consuming the old event name.

### 7. Indexer event requirements extended

Part VIII now requires the three new events with their full argument lists. Specifically: `PitchSubmitted` MUST include `taskId`, `worker`, and `pitchHash`; `ProofSubmitted` MUST include all five fields; `AuctionAccepted` MUST include `taskId`, `worker`, and `acceptedPrice`.

## Storage layout (UUPS-safe, append-only)

Two new state variables appended after existing slots, consuming from `__gap`:

- `taskPitchHashes` — `mapping(bytes32 => bytes32[])` — slot 10
- `taskProofHashes` — `mapping(bytes32 => bytes32[])` — slot 11
- `__gap` shrunk from 48 → 46

Storage layout before/after snapshots committed alongside; `scripts/verify-storage-layout.ts` diffs the two and asserts all 11 existing non-gap slots are unchanged.

## Backwards-compatibility posture

`submitPitch` and `submitProof` are additive — implementations that pre-date this revision do not need to be redeployed to remain compliant, though they will lack on-chain pitch/proof anchoring. New implementations MUST emit the new events.

`AuctionAccepted` is additive alongside the legacy event pair. Indexers consuming `BidSubmitted + TaskWorkerSelected` continue to work unchanged.

`TaskCompleted` (renamed from `TaskAccepted`) is a breaking change for indexers. Implementations should update event consumers before deploying.

## Reference implementation status

Deployed at proxy address `0x436C05C6059D6974608c6123E98B94cC388949a6` on Base Sepolia (implementation `0x738088D288B2D20C528bB2123a5BA4aC1F002AeD`). Storage layout verifier confirms 11 existing slots unchanged.

- `forge test` — 149 passing
- `forge build` — clean, 91 ABI entries

## Feedback welcome

- Whether `submitPitch` and `submitProof` should be marked OPTIONAL (only required for implementations that support those modes) or unconditionally REQUIRED in the interface.
- Whether the domain-separation construction should be enforced in-contract (e.g. by the contract recomputing the hash from a `string content` calldata arg) or left as a backend-level invariant verifiable by third parties (current approach).
