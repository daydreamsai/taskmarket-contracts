# ERC-8195 Revision 002 — Multi-Submission Payouts and Authentication-Agnostic Core

**Revision:** 002
**Date:** 2026-05-16
**PRs:** https://github.com/daydreamsai/taskmarket-contracts/pull/3

## Motivation

Bounty mode is designed as a competitive open contest where multiple workers submit work and the
requester selects the best entry or entries. The Rev 001 contract enforced a first-write-wins
model: only one worker could submit, and `acceptSubmission` had no way to pay multiple winners.
This made ranked payouts impossible and turned Bounty into a race-to-submit rather than a
contest. Separately, the spec was unnecessarily coupled to a specific authentication mechanism
(PGTR/ERC-8194), preventing compliant implementations from using standard meta-transaction or
smart-account patterns. This revision fixes both problems.

---

## Problem 1 — Bounty mode accepted only one submission

`submitWork` in Bounty mode wrote `task.deliverable` on the first call and reverted any
subsequent call with `"Deliverable already set"`. The Bounty state machine was supposed to
collect entries from multiple workers before the requester selects; in practice it selected the
first submitter by default. Ranked payouts — a core Bounty use case — were impossible.

## Problem 2 — `acceptSubmission` could not distribute rewards to multiple workers

`acceptSubmission(bytes32, address)` accepted exactly one worker. There was no interface for
the requester to split rewards across a ranked set of winners. Operators worked around this by
calling `acceptSubmission` once and handling off-chain payouts, which broke the on-chain
settlement guarantee.

## Problem 3 — `rateTask` was not keyed per worker

With multi-winner payouts, a single `(taskId)` rating key was ambiguous. The first winner
could be rated and subsequent winners locked out, or the same (taskId, rating) could be
replayed to inflate `workerStats` for any address.

## Problem 4 — `ITMPCore` required `isTrustedForwarder`, coupling the spec to PGTR

The `ITMPCore` interface imported `IPGTRForwarder` and required `isTrustedForwarder` as a
mandatory view function. This forced all compliant implementations to couple to PGTR even when
they used ERC-2771, ERC-4337, or direct `msg.sender` auth. The spec was silent on how these
alternatives related to x402 payment-gated flows.

---

## Changes

### 1. `ITMPCore.acceptSubmissions` — multi-winner payout function

```solidity
// Before (rev001) — single winner only
function acceptSubmission(bytes32 taskId, address worker) external;

// After (rev002) — single winner (updated signature) and new multi-winner path
function acceptSubmission(bytes32 taskId, address worker, bytes32 deliverable) external;

function acceptSubmissions(
    bytes32 taskId,
    address[] calldata workers,
    uint16[] calldata shares,
    bytes32[] calldata deliverables
) external;
```

These are two distinct function names, not a Solidity overload. Overloading the same name with
different parameter types creates ABI selector ambiguity; the singular/plural naming is
unambiguous.

Constraints enforced by the reference implementation:

- All three arrays equal length, `length >= 1`
- `sum(shares) == 10000` (basis points)
- Each `deliverables[i]` non-zero; per-pair payout `(reward * shares[i]) / 10000` non-zero
  (reverts on rounding-to-zero)
- Each `(worker, share)` pair gets its own `TaskCompleted` event so indexers attribute payouts
  without decoding arrays
- Per-pair fee: `workerPayment * feeBps / 10000`; fees accumulate and transfer in a single
  batched send
- `workers[0]` written to `task.worker`; `deliverables[0]` written to `task.deliverable` for
  single-worker-field back-compat
- Duplicate worker addresses are allowed; the requester is the authority on payouts
- MUST revert for modes with a single locked worker (Claim, Pitch, Auction)

A single-winner call (length-1 arrays, share=10000) produces state identical to
`acceptSubmission`. The two functions are kept distinct so the common single-winner case stays
ergonomic.

Ranked payouts are expressed natively by passing workers in rank order with the desired share
per position:

```solidity
// Ranked payout example
acceptSubmissions(
    taskId,
    [alice, bob, carol],   // rank order
    [5000, 3000, 2000],    // basis points, must sum to 10000
    [hashA, hashB, hashC]
);
```

### 2. `submitWork` — deferred-write model for Bounty and Benchmark

```solidity
// Before (rev001) — first submission wrote task.deliverable; second reverted
function submitWork(bytes32 taskId, bytes32 deliverableHash) external {
    // ...
    task.deliverable = deliverableHash;  // single write; second caller reverts
    task.status = PendingApproval;
}

// After (rev002) — emit only; no write, no status change
function submitWork(bytes32 taskId, bytes32 deliverableHash) external {
    // Bounty / Benchmark: emit and return; deliverable written at acceptance
    if (task.mode == BOUNTY || task.mode == BENCHMARK) {
        emit TaskSubmitted(taskId, msg.sender, deliverableHash);
        return;
    }
    // Claim / Pitch / Auction: write as before
    task.deliverable = deliverableHash;
    task.status = PendingApproval;
}
```

`acceptSubmission` gains a `bytes32 deliverable` parameter. The contract writes `task.worker`
and `task.deliverable` at acceptance time. For Claim, Pitch, and Auction (single locked worker)
the new param is cross-checked against the value already set by `submitWork`.

Bounty and Benchmark state machine before and after:

```
BEFORE:
Open
  --[submitWork]-> PendingApproval
PendingApproval
  --[acceptSubmission]-> Accepted

AFTER:
Open
  --[submitWork*]----> Open           (multiple submissions allowed; no status change)
  --[acceptSubmission*]--> Completed  (single winner; deliverable written at acceptance)
  --[acceptSubmissions*]-> Completed  (N winners with share basis points)
  --[expire]-----------> Expired
```

### 3. `rateTask` — explicit `address worker` parameter

```solidity
// Before (rev001)
function rateTask(bytes32 taskId, uint8 stars, ...) external;

// After (rev002)
function rateTask(bytes32 taskId, address worker, uint8 stars, ...) external;
```

The reference contract enforces one rating per `(taskId, worker)` pair via a new
`taskWorkerRated` mapping, preventing inflating `workerStats` through repeated rating calls.

### 4. `ITMPCore` — authentication mechanism decoupled

```solidity
// Before (rev001) — required import and view function
import "./IPGTRForwarder.sol";
interface ITMPCore {
    function isTrustedForwarder(address forwarder) external view returns (bool);
    // ...
}

// After (rev002) — no forwarder import; isTrustedForwarder removed from required surface
interface ITMPCore {
    // Authentication is implementation-defined. See normative Authentication section.
    // ...
}
```

A new normative Authentication section in the spec lists acceptable mechanisms:

| Mechanism | Description |
|-----------|-------------|
| Direct `msg.sender` | EOA or smart account broadcasting the tx |
| ERC-2771 trusted forwarder | Signature-based meta-transactions |
| ERC-4337 EntryPoint | Smart-account user operations |
| ERC-8194 PGTR | Payment-receipt authorization; recommended for x402 flows |
| x402 settlement callback | HTTP payment protocol paired with PGTR |
| Implementation-specific | Any mechanism that securely binds a principal to the call |

Implementations MUST authenticate; the mechanism is implementation-defined. PGTR remains
RECOMMENDED for x402 payment-gated flows. The relationship between x402 and PGTR is now
described explicitly:

> x402 defines the off-chain HTTP payment protocol. PGTR (ERC-8194) is the on-chain primitive
> that translates an x402 payment receipt into on-chain sender attribution so the resulting
> state transition is attributed to the payer rather than the relayer. The two protocols are
> complementary, not competing.

ERC-2771 and ERC-4337 solve signature-based meta-transactions but do not translate x402
receipts into on-chain attribution. Implementations that do not need x402 payment-gated UX can
use either instead.

### 5. ERC-8194 abstract clarified

The previous ERC-8194 abstract claimed "key abstraction" without qualification. The revised
abstract distinguishes two regimes:

- **Custodial / gateway flows** (x402 paid via fiat-bridge, WaaS, or exchange wallet): the
  principal genuinely holds no key. Full key abstraction.
- **Direct-wallet flows** (the principal signs ERC-3009 over x402 themselves): PGTR provides
  principal/signer separation and gas abstraction, not full key abstraction.

In either case the destination contract never asks the principal for a signature. That is the
property PGTR delivers regardless of flow.

---

## Rationale

**Why use singular/plural function names instead of Solidity overloading?**

Function overloading produces identical selector bytes for different parameter lists when the
types happen to produce the same 4-byte keccak hash prefix. More importantly, off-chain tooling
(ethers.js, viem, subgraphs) handles overloads inconsistently. Two distinct names are
unambiguous in ABI JSON, in event logs, and in test output.

**Why is `acceptSubmissions` restricted to Bounty and Benchmark?**

Claim, Pitch, and Auction each lock a single worker to the task. Splitting payment across
multiple workers would contradict the commitment made to that worker when they claimed, were
selected, or won the auction. Multi-winner distribution is meaningful only in open-submission
modes.

**Why does a single-winner `acceptSubmissions` call (length-1) not replace `acceptSubmission`?**

The common case of accepting a single winner should remain ergonomic and readable. Requiring
callers to pass three single-element arrays for the majority of acceptances adds calldata and
cognitive overhead. Both functions exist; the choice is the caller's.

**Why remove `isTrustedForwarder` from the required interface surface?**

Mandating a specific view function for one authentication mechanism embedded a PGTR-specific
design decision in the core interface. Implementations using ERC-2771 do expose
`isTrustedForwarder`, but those using ERC-4337 or direct `msg.sender` have no concept of a
trusted forwarder. Moving authentication to an implementation-defined section makes the spec
composable with the broader ecosystem.

---

## API Changes

- `acceptSubmission(bytes32, address)` changes to `acceptSubmission(bytes32, address, bytes32)`.
  The third argument is the deliverable hash. This is a **breaking ABI change**.
- `rateTask(bytes32, uint8, ...)` changes to `rateTask(bytes32, address, uint8, ...)`. This is
  a **breaking ABI change**.
- `acceptSubmissions(bytes32, address[], uint16[], bytes32[])` added. New callers only.
- `submitWork` is emit-only in Bounty and Benchmark modes — no state is written. Indexers
  relying on `task.deliverable` being set after `TaskSubmitted` must update to read it from the
  `TaskCompleted` event instead.
- `isTrustedForwarder` removed from the required `ITMPCore` view surface. Implementations that
  expose it for ERC-2771 compatibility may keep it; it is no longer normative.

---

## Affected Files

| File | Change |
|------|--------|
| `src/interfaces/ITMPCore.sol` | Update `acceptSubmission` signature (add `deliverable`); add `acceptSubmissions`; update `rateTask` signature (add `worker`); remove `isTrustedForwarder`; remove `IPGTRForwarder` import |
| `src/TaskMarket.sol` | Implement deferred-write `submitWork` for Bounty/Benchmark; implement `acceptSubmissions` with basis-point splits; add `taskWorkerRated` mapping; update `rateTask` to key on `(taskId, worker)` |
| `docs/specs/erc8195/erc-8195.md` | Update Bounty/Benchmark state machines; add normative Authentication section; revise ERC-8194 abstract; remove `isTrustedForwarder` from required interface table |
| `test/TaskMarket.t.sol` | Add 23 new tests for multi-submission payouts, deferred-write model, and per-worker rating |
