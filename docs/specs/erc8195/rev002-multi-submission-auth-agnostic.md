# ERC-8195 spec update — Rev 002 — multi-submission payouts, Bounty fix, authentication-agnostic core

Pushing the second tracked revision to the ERC-8195 draft to bring the spec in line with the reference implementation. Status remains `Draft`.

**Revision:** 002
**Date:** 2026-05-16
**PR:** https://github.com/daydreamsai/taskmarket-contracts/pull/3

## 1. Multi-submission payouts added to ITMPCore

`acceptSubmissions` is now a required function in the ITMPCore interface alongside `acceptSubmission`. Multi-winner payouts are a fundamental Bounty/Benchmark state-machine transition — not a peripheral feature — so the function lives in core rather than as an extension interface.

```solidity
function acceptSubmissions(
    bytes32 taskId,
    address[] calldata workers,
    uint16[] calldata shares,
    bytes32[] calldata deliverables
) external;
```

These are **two distinct function names**, not a Solidity function overload. Overloading the same name with different parameter types creates ABI selector ambiguity; the singular/plural naming is unambiguous.

Constraints (all enforced in the reference contract):

- All three arrays equal length, `length >= 1`
- `sum(shares) == 10000` (basis points)
- Each `deliverables[i]` non-zero; per-pair payout `(reward * shares[i]) / 10000` non-zero (reverts on rounding-to-zero)
- Each `(worker, share)` pair gets its own `TaskCompleted` event so indexers attribute payouts without decoding arrays
- Per-pair fee: `workerPayment * feeBps / 10000`; fees accumulate and transfer in a single batched send
- `workers[0] → task.worker`, `deliverables[0] → task.deliverable` for single-worker-field back-compat
- Duplicate worker addresses are allowed; the requester is the authority on payouts
- MUST revert for modes with a single locked worker (Claim, Pitch, Auction)

A single-winner call (length-1 arrays, share=10000) MUST produce state identical to `acceptSubmission`. The two functions are kept distinct so the common single-winner case stays ergonomic.

**Ranked payouts** are expressed natively by passing workers in rank order with the desired share per position — no separate ranked-acceptance function is needed:

```solidity
acceptSubmissions(
    taskId,
    [alice, bob, carol],   // rank order
    [5000, 3000, 2000],    // basis points
    [hashA, hashB, hashC]
)
```

## 2. Bounty multi-submission bug fixed (deferred-write model)

The previous reference contract reverted any second `submitWork` call with `"Deliverable already set"`. That contradicted Bounty mode's "any worker may submit" semantic — in practice it was a race-to-submit, not a contest.

The fix is a **deferred-write** model for Bounty and Benchmark:

- `submitWork` in Bounty / Benchmark now emits `TaskSubmitted` only — no deliverable write, no status transition. Multiple workers may call concurrently.
- `acceptSubmission` gained a `bytes32 deliverable` parameter. The contract writes `task.worker` and `task.deliverable` at acceptance time.
- For Claim / Pitch / Auction (single locked worker), the new param is cross-checked against the value already set by `submitWork`.

State machine before / after for Bounty mode:

```
BEFORE:                              AFTER:
Open                                 Open
  --[submitWork]-> PendingApproval     --[submitWork*]----> Open    (multiple submissions
PendingApproval                                              allowed; no status change)
  --[acceptSubmission]-> Accepted      --[acceptSubmission*]-> Completed  (single winner)
                                       --[acceptSubmissions*]---> Completed (N winners)
                                       --[expire]-----------> Expired
```

`rateTask` also gained an explicit `address worker` parameter — with N winners per task, each `(taskId, worker)` pair should be rateable separately. The reference contract enforces one rating per pair via a new `taskWorkerRated` mapping to prevent inflating `workerStats`.

## 3. Authentication-mechanism-agnostic core

The ITMPCore interface no longer imports `IPGTRForwarder` or requires `isTrustedForwarder` as a view function. A new normative **Authentication** section lists acceptable mechanisms:

| Mechanism | Description |
|-----------|-------------|
| Direct `msg.sender` | EOA or smart account broadcasting the tx |
| ERC-2771 trusted forwarder | Signature-based meta-transactions |
| ERC-4337 EntryPoint | Smart-account user operations |
| ERC-8194 PGTR | Payment-receipt authorization; recommended for x402 flows |
| x402 settlement callback | HTTP payment protocol paired with PGTR |
| Implementation-specific | Any mechanism that securely binds a principal to the call |

Implementations MUST authenticate; the mechanism is implementation-defined.

PGTR remains RECOMMENDED for x402 payment-gated authorization. The spec now frames the relationship clearly:

> x402 defines the off-chain HTTP payment protocol. PGTR (ERC-8194) is the on-chain primitive that translates an x402 payment receipt into on-chain sender attribution so the resulting state transition is attributed to the payer rather than the relayer. The two protocols are complementary, not competing.

ERC-2771 and ERC-4337 solve signature-based meta-transactions and don't translate x402 receipts into on-chain attribution. Implementations that don't need x402 payment-gated UX can use either instead.

## 4. ERC-8194 abstract clarified

The previous abstract claimed "key abstraction" without qualification. The revised abstract distinguishes two regimes:

- **Custodial / gateway flows** (X402 paid via fiat-bridge, WaaS, or exchange wallet): the principal genuinely holds no key. Full key abstraction.
- **Direct-wallet flows** (the principal signs ERC-3009 over X402 themselves): PGTR provides principal/signer separation and gas abstraction — not full key abstraction.

Either way, the destination contract never asks the principal for a signature. That is the property PGTR delivers regardless of flow.

## ABI changes (breaking, acceptable pre-mainnet)

- `acceptSubmission(bytes32, address)` → `acceptSubmission(bytes32, address, bytes32)`
- `rateTask(bytes32, uint8, …)` → `rateTask(bytes32, address, uint8, …)`
- New `acceptSubmissions(bytes32, address[], uint16[], bytes32[])`
- `submitWork` is emit-only in Bounty / Benchmark modes
- `isTrustedForwarder` removed from required ITMPCore view surface

## Reference implementation status

Updated and deployed at proxy address `0x436C05C6059D6974608c6123E98B94cC388949a6` on Base Sepolia. Storage layout before/after snapshots and a verifier script are committed alongside, demonstrating the UUPS upgrade-safety pattern.

- `forge test` — 169 + 23 new tests passing
- `forge build --sizes` — TaskMarket runtime 22,092 bytes (2,484 bytes margin under EIP-170)
- Storage layout verifier: 11 existing slots unchanged, `__gap` consumed from 48 → 45 across the v2 changes

## Feedback welcome

- Whether `submitPitch` and `submitProof` should be OPTIONAL (only required for implementations supporting those modes) or unconditionally REQUIRED.
- Whether the domain-separation construction for pitch/proof hashes should be enforced in-contract or left as a backend-level invariant verifiable by third parties (current approach).
