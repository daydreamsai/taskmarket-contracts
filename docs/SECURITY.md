# Security

This document describes the security practices used in the TaskMarket smart contracts.

---

## Automated Analysis

Every pull request runs three layers of automated contract analysis in CI.

### Static Analysis — Slither

[Slither](https://github.com/crytic/slither) runs on every PR and produces a checklist-format report uploaded as a CI artifact (retained 30 days). It checks for reentrancy, CEI violations, unprotected state transitions, dangerous patterns, and ~80 other detectors.

Run locally:

```bash
make contract audit
# report written to packages/contracts/reports/slither-audit.md
```

Configuration: `packages/contracts/slither.config.json`

CI fails on any medium or high finding (`fail_on: medium`). The following detectors are excluded project-wide with justification:

| Detector | Reason for exclusion |
|---|---|
| `naming-convention` | Informational style rule; `forge fmt` + `solhint` handle naming conventions |
| `unused-state` | `__gap` storage is intentionally reserved for UUPS upgrade slots — not dead code |
| `timestamp` | `block.timestamp` is required for all deadline checks; `not-rely-on-time` is also off in solhint for the same reason |
| `low-level-calls` | Informational detector for any `.call()` usage; both call sites are handled explicitly (see inline suppressions) |
| `solc-version` | 0.8.24 is intentional — it adds transient storage opcodes and improved error messages; Slither recommends 0.8.18 |

Any suppression that applies to a specific line rather than the whole project uses an inline `// slither-disable-next-line` comment with a rationale comment above it. See `_afterHook` in `TaskMarket.sol` and `relay` in `TaskMarketForwarder.sol`.

### Linting — Solhint

[Solhint](https://protofire.github.io/solhint/) enforces Solidity-specific security rules as part of the standard lint step. The ruleset is security-focused: function visibility, reentrancy patterns, call value safety, and complexity limits. Style rules are handled by `forge fmt` instead.

```bash
make lint-check contracts   # runs as part of the standard CI lint step
```

Configuration: `packages/contracts/.solhint.json`

### Gas Regression — Forge Snapshot

A committed `.gas-snapshot` baseline is checked on every PR. If any function's gas cost increases unexpectedly, CI fails. This catches accidental complexity regressions and surfaces unintended state changes.

```bash
make contract snapshot-check   # verify no regression
make contract snapshot         # update baseline after intentional changes
```

---

## Contract Security Properties

### Reentrancy

Every external function that performs a token transfer or calls an external hook contract carries the `nonReentrant` modifier. This includes `createTask`, `claimTask`, `selectWorker`, `submitWork`, `submitBid`, `submitPitch`, `submitProof`, `appeal`, `assignEvaluator`, `forfeitAndReopen`, and all acceptance and payout paths.

`on*` hook calls (`onComplete`, `onCancel`, `onExpire`, `onForfeit`) are wrapped in try-catch so a buggy or malicious hook cannot block fund recovery. `check*` hooks fire after state commits but before transfers — a rejection reverts all state changes cleanly without leaving the contract in an inconsistent state.

### Checks-Effects-Interactions (CEI)

All state mutations are committed before any external call or token transfer. Accounting variables (`totalFeesCollected`, status fields, stake balances) are updated before the corresponding `transfer()` call throughout the contract.

### Fund Safety

`refundExpired` is normatively required to succeed once `block.timestamp > task.expiryTime` (ERC-8195 Part VII). The evaluator extension preserves this invariant by extending `task.expiryTime` rather than blocking the call: when a task enters `Review`, `expiryTime` is set to `max(expiryTime, block.timestamp + evaluationWindow)`; when it enters `Appealing`, it is extended again to `max(expiryTime, block.timestamp + appealWindow)`. This means `refundExpired` cannot fire while evaluation or appeal is live — the deadline has simply moved forward — and once the window passes, funds are always recoverable. If an evaluator is unresponsive before the window expires, the requester can use `evaluatorTimeout` to exit early.

Evaluator stakes are pulled in via `transferFrom` at assignment time and returned atomically at evaluation time. A timed-out evaluator forfeits their stake to the fee recipient.

### Upgradability

The contract is UUPS upgradeable. The proxy address is permanent; only the implementation changes on upgrade. Storage layout is protected by:

- An append-only rule: new state variables must be added after all existing ones and consume slots from `__gap`
- A committed `storage-layout.before.json` snapshot checked against the post-build layout in CI via `scripts/verify-storage-layout.ts`

### Access Control

All mutating functions require a call via a trusted PGTR forwarder (ERC-8194). The forwarder verifies x402 payment receipts and extracts the authenticated actor via `pgtrSender()`. `resolveDispute` additionally accepts direct calls from the registered dispute resolver address.

Owner-only functions (fee configuration, forwarder registration, upgrade authorization, pause/unpause) are restricted to the contract owner via OpenZeppelin's `Ownable2StepUpgradeable`. The two-step pattern requires the incoming owner to call `acceptOwnership()` before the transfer completes, preventing irrecoverable ownership loss from a mistyped address.

### Emergency Pause

`pause()` halts all state-mutating operations without exception. This gives complete
control over all attack vectors during an emergency — a bug could exist in any function,
including fund recovery paths, so no exceptions are carved out. All user funds remain
safe in the contract; they are not accessible to any party (including the owner) while
paused. The owner MUST unpause promptly once the emergency is resolved (deploy a fix via
UUPS upgrade, then unpause). Task expiry windows are measured in days, so a short pause
does not permanently strand funds.

Admin operations: `make contract pause` / `make contract unpause`.

### Push Payment Failure

USDC has an optional blocklist. If a worker or requester address is added to the USDC
blocklist between task creation and payout, the `transfer()` call to that address will
revert. The contract reverts with a typed transfer error (`WorkerPaymentFailed`,
`RefundFailed`, etc.) rather than silently skipping the payment.

The worst case is bounded by `task.expiryTime`: after expiry, `refundExpired` attempts
the same transfer and will continue reverting while the address is blocked. Once the
address is removed from the blocklist (or the operator unlocks it), `refundExpired` can
be called successfully. No USDC is permanently lost — it remains escrowed in the
contract until the transfer succeeds.

Integrators should document this risk to requesters and workers operating in regulated
contexts where USDC blocklist exposure is plausible.

### Hook Contract Destruction

EIP-6780 (Cancun) restricts `SELFDESTRUCT` to contracts that are deployed and destroyed
within the same transaction. After Cancun, a hook contract cannot be destroyed except in
that same-transaction deploy pattern. This makes hook destruction a deployment-time risk
only, not an ongoing operational risk.

`on*` hooks (`onComplete`, `onCancel`, `onExpire`, `onForfeit`) are wrapped in try-catch:
if a hook contract is destroyed, the outer call fails silently and does not block fund
recovery.

`check*` hooks (`checkFund`, `checkClaim`, etc.) are not try-catch. If a `check*` hook
is destroyed, the low-level call returns empty data, which fails ABI decoding, and the
calling function reverts. Task state changes before that call point are also reverted.
For `createTask`, this means the task is never created and no funds move — no harm done.
For mid-lifecycle functions (like `acceptSubmission`), state changes are reverted cleanly.
No funds are permanently stranded because `refundExpired` does not call `check*` hooks.

---

## Reporting a Vulnerability

**Critical or high severity** — use [GitHub private vulnerability reporting](https://github.com/daydreamsai/taskmarket/security/advisories/new). This creates a private advisory visible only to maintainers and allows coordinated disclosure before a fix is deployed.

**Low severity or general findings** — open a public [GitHub issue](https://github.com/daydreamsai/taskmarket/issues). Transparency is welcome for findings that do not put user funds at immediate risk.
