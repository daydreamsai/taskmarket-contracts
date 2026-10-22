# Security

This document describes the security practices used in the TaskMarket smart contracts.

## Audit Status

These contracts have not had a traditional audit by a security firm. They had one open security
review, run as a Taskmarket bounty task
([task](https://taskmarket.dev/tasks/0x779ac4c1bfa18e2fc2475f4e0243d30e753ad3759df46ff00c7ee2e73a7f03ff)):
opened 2026-07-13, closed 2026-07-20, settled 2026-07-23, 20 USDC reward, 311 submissions, with
findings rated and paid to multiple reviewers. Its scope was the diamond facets, AppStorage,
access control, escrow and payout, the reward vault and hooks, reviewed against this repository
at revision rev010. Later revisions (rev011 onward) have not had an independent review.

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
| `unused-state` | AppStorage fields are intentionally reserved for use by facets via delegatecall — not dead code |
| `timestamp` | `block.timestamp` is required for all deadline checks; `not-rely-on-time` is also off in solhint for the same reason |
| `low-level-calls` | Informational detector for any `.call()` usage; both call sites are handled explicitly (see inline suppressions) |
| `solc-version` | 0.8.24 is intentional — it adds transient storage opcodes and improved error messages; Slither recommends 0.8.18 |

Any suppression that applies to a specific line rather than the whole project uses an inline `// slither-disable-next-line` comment with a rationale comment above it. The `controlled-delegatecall` detector is excluded project-wide because `Diamond.fallback` performs a selector-gated `delegatecall` to registered facets only — not to arbitrary addresses. See `relay` in `TaskMarketForwarder.sol` for inline suppressions.

### Linting — Solhint

[Solhint](https://protofire.github.io/solhint/) enforces Solidity-specific security rules as part of the standard lint step. The ruleset is security-focused: function visibility, reentrancy patterns, call value safety, and complexity limits. Style rules are handled by `forge fmt` instead.

```bash
make lint-check contracts   # runs as part of the standard CI lint step
```

Configuration: `packages/contracts/.solhint.json`

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

The contract uses the Diamond proxy pattern (EIP-2535). The proxy address is permanent; individual
facets are upgraded via `diamondCut`. Storage layout is protected by:

- An append-only rule: new state variables are appended to the end of `AppStorage` in `LibAppStorage.sol`; no insertions between existing fields
- `AppStorage` is stored at a deterministic `keccak256("taskmarket.appstorage.v1")` slot; field offsets are stable across upgrades

Only the contract owner may call `diamondCut`. The owner must be a multisig or timelock in
production to prevent a single compromised key from upgrading to a malicious facet.

`diamondCut` accepts an optional `init`/`data` pair for post-upgrade initialisation. There is no
reinitializer version counter — new `AppStorage` fields zero-initialise by default; non-zero
defaults use lazy-init in the facet function body.

### Access Control

All mutating functions require a call via a trusted PGTR forwarder (ERC-8194). The forwarder accepts calls only from its `authorizedRelayer` and exposes the actor the relayer named via `pgtrSender()`; it does not verify a user signature or payment proof itself (see Off-Chain Trust Boundaries). `resolveDispute` additionally accepts direct calls from the registered dispute resolver address.

Owner-only functions (fee configuration, forwarder registration, `diamondCut`, pause/unpause) are restricted to the contract owner via `LibDiamond.enforceIsContractOwner()`. The two-step pattern requires the incoming owner to call `acceptOwnership()` before the transfer completes, preventing irrecoverable ownership loss from a mistyped address.

### Emergency Pause

`pause()` halts all state-mutating operations without exception. This gives complete
control over all attack vectors during an emergency — a bug could exist in any function,
including fund recovery paths, so no exceptions are carved out. All user funds remain
safe in the contract; they are not accessible to any party (including the owner) while
paused. The owner MUST unpause promptly once the emergency is resolved (deploy a fix via
`diamondCut`, then unpause). Task expiry windows are measured in days, so a short pause
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

## Off-Chain Trust Boundaries

Some guarantees depend on off-chain components run by the operator. They are listed here so
reviewers do not assume the contracts enforce them.

### Forwarder and relayer (ERC-8194 payment-gated relay)

`TaskMarketForwarder.relay` reverts unless `msg.sender == authorizedRelayer` (immutable, set at
construction). It checks receipt expiry (`validBefore`) and replay (`consumedReceipts`, keyed on
chain id, actor, amount, nonce, target and selector), pulls `paymentAmount` USDC from the relayer
into the diamond, and records `pgtrSenderAddr` as the actor the diamond reads via `pgtrSender()`.

It verifies no user signature. Users are authenticated off-chain: the relayer accepts a request
only after the user has paid for it (an x402 payment from the user's wallet), and it then relays
the call naming that wallet as the actor. The contracts therefore trust the relayer to name the
actor correctly and to relay only paid requests. A compromised relayer key can act as any user
within the task flow, bounded by what the diamond allows that role to do and by the USDC the
relayer itself holds; it cannot call owner-only functions. Recovery is to deploy a new forwarder
and swap it with `addForwarder` / `removeForwarder`.

### Token policy pre-checks

On Tempo, TIP-20 receive policies and token blacklist / transfer-policy restrictions are checked
off-chain in the operator's backend before a task is escrowed and before a payout is sent. The
contracts do not perform these checks. Contract transfers keep revert semantics: a transfer the
token refuses reverts the whole call (see Push Payment Failure), and funds stay escrowed until it
can succeed.

### Owner key

The owner (`LibDiamond.contractOwner`) can:

- upgrade any logic, add or remove any selector and run arbitrary init code via `diamondCut`;
  this is equivalent to full control of escrowed funds
- `pause` / `unpause` all state-mutating operations
- `addForwarder` / `removeForwarder`, which decides which relayer may act for users
- `setDefaultFeeBps` and `setFeeRecipient`
- `setReputationRegistry` and `setDefaultHooks`
- `setMinAppealWindowSecs` and `setMinFeedbackGas`
- `setDiamondVersion`
- `transferOwnership` (two-step, completed by `acceptOwnership`)

Custody: the diamond owner is an externally owned account (EOA) on each chain. Whoever controls
the owner key can exercise every power listed above.

The forwarder has no owner: its `authorizedRelayer` is fixed at deployment and can only be
replaced by deploying a new forwarder. The relayer key is likewise an EOA. Protection of both
keys is handled out of band and is not specified here.

### Hook gas

Hooks are external contracts. Each hook call gets a fixed stipend (`HOOK_GAS_STIPEND`, 1,000,000
gas) and is only made when enough gas remains to forward the full stipend, so a caller
cannot starve a hook by sending a short gas limit; reputation feedback calls are guarded by the
gas floor introduced in rev023 (450,000) and made owner-set per chain as `minFeedbackGas` in rev024.

---

## CI and Reproducing Checks

This package is mirrored from a private repository. CI workflow files are not mirrored and CI
runs are not publicly viewable, so CI claims in this document cannot be checked from outside.
The public mirror, [taskmarket-contracts](https://github.com/daydreamsai/taskmarket-contracts),
holds the sources and tests, so every check reproduces locally with Foundry:

```bash
forge build
forge test -j 1            # serial: the upgrade scripts share process-wide env
```

---

## Reporting a Vulnerability

### Scope

In scope: the Solidity sources in this package (`src/`, including hooks) and the deployed
diamonds and forwarders built from them.

Out of scope: the operator's backend, relayer and web app (report those to the same channel,
but they are not covered by this policy), third-party tokens and registries the contracts call,
findings that require the owner key to act maliciously, and gas or style findings with no
security impact.

### How to report

Report privately through a [GitHub private security advisory](https://github.com/daydreamsai/taskmarket-contracts/security/advisories/new)
on this repository. Do not open a public issue for anything that could put funds at risk.
You can also reach us on the Taskmarket Discord. Low-severity findings with no fund risk may be
opened as public issues.

Please include the affected contract and function, the deployment (chain and address) if any,
and a proof of concept (a Foundry test is ideal). We ask that you do not disclose publicly until a
fix is deployed or we agree a date.

We respond on a best-effort basis and do not commit to fixed response times.

### Bug bounty

There is a bug bounty, handled per finding. Contact us through either channel above; we then
list a Taskmarket task for you to submit the finding to, and the reward is set on that task.
There is no fixed reward table.
