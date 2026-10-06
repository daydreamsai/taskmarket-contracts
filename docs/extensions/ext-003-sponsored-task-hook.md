# EXT-003: Sponsored Task Hook

**Status:** Implemented (V1, Base-only)
**Type:** Daydreams Extension (not a TMP protocol standard)

---

## Overview

EXT-003 lets a project fund a vault with its own ERC-20 token and attach a
project-token reward to ordinary Taskmarket tasks, alongside the existing USDC
reward. It is implemented as an opt-in ERC-8195 hook — no core protocol changes are required,
and tasks without the hook are unaffected. Unlike EXT-001, this hook is never registered as a
protocol default; a vault manager (the task requester) attaches it explicitly per task.

Each vault is one project token, one chain, one vault. A vault owner deposits tokens,
authorizes one or more manager wallets with token-denominated spend caps, and a manager
creates tasks that reserve a fixed gross amount from the vault. On task completion, a
permissionless settlement step installs a Merkle root over the awarded workers' net amounts;
each worker then claims gaslessly to a destination wallet of their choosing, independent of
the underlying USDC settlement.

V1 is Base-local only. Robinhood Chain / cross-chain settlement was part of the originally
prototyped design and is explicitly out of scope for this revision — see Non-goals in
RFC-0018, "Sponsored Task: project-token sponsorship rewards on Taskmarket tasks" (not yet
merged to this branch).

This is a Daydreams-specific extension. It is not part of the ERC-8195 or TMP protocol
standard.

---

## Contracts

| Contract | Role |
|---|---|
| `SponsoredTaskHook` | `ITMPHook` implementation; the only contract that talks to the Diamond. UUPS-upgradeable, single canonical deployment. |
| `SponsoredTasksVault` | Per-vault escrow, deployed as an EIP-1167 clone; holds one vault's tokens and tracks available/reserved/claimable/paid/withdrawn balances. Immutable — never upgraded. |
| `SponsoredTaskFactory` | Permissionless `createVault` — deploys a new vault clone and registers it. |
| `SponsoredTaskRegistry` | Owner-gated allowlist of authorized factories; the canonical "is this a real vault" source of truth the hook checks against. |
| `SponsoredTaskFeeBank` | Manager's prefunded USDC credit balance, charged a flat creation fee per task at `checkFund` time. |
| `SponsoredTaskFeeBankGuard` | Non-upgradeable contract that permanently narrows administration of one exact `SponsoredTaskFeeBank` to a deployed contract (Safe/timelock) — closes the raw FeeBank owner's ability to authorize an arbitrary credit-draining charger. |
| `SponsoredTaskFeePolicy` | Owner-configurable project-token fee (bps + recipient), snapshotted per vault at reservation time. |
| `SponsoredTaskSettlement` (library) | Computes the Merkle tree of per-worker net entitlements from a verdict's awards. |
| `SponsoredTaskTerms` (library) | Hashes a snapshot of live Taskmarket task terms so `hookData` cannot be replayed against a task whose terms changed after it was built. |

The hook is UUPS-upgradeable, deliberately unlike vaults: its `taskmarket`/`usdc`/`feeBank`/`registry`
dependencies are `immutable`, baked into the implementation contract's bytecode, correct only
because there is exactly one canonical proxy for this hook. Vaults are immutable clones of a
fixed implementation — new vault logic ships as a new factory version; existing vaults keep
their original vault code for their lifetime.

---

## hookData

A vault manager builds a `SponsoredTaskHook.FundingRequest` and encodes it via
`hook.encodeHookData(request)`:

```solidity
struct FundingRequest {
    uint8 route;           // always ROUTE_BASE_LOCAL (0) in V1
    address vault;
    bytes32 vaultId;
    bytes32 allocationId;  // must be bytes32(0) for the local route; the hook sets it to taskId
    uint64 epoch;
    uint16 feeBps;
    address feeRecipient;
    uint256 grossAmount;
    bytes32 taskTermsHash; // from hook.currentTaskTermsHash(taskId), built immediately before createTask
}
```

`taskTermsHash` must be computed against the exact task terms submitted at `createTask` — any
drift (e.g. server-side normalization between a client's draft and what the relayer actually
submits) reverts `TaskTermsMismatch`. `hook.currentTaskTermsHash(taskId)` only works once the
task already exists, so a caller building `hookData` beforehand needs an off-chain equivalent:
every field the terms hash covers (`reward`, `duration`, `mode`, `pitchDuration`, `bidDuration`,
`auctionSubtype`, `stakeRequired`, `stakeBps`, `feeBps`, evaluator terms, `contentHash`,
`contentURIHash`, `tagsHash`, `hooksHash`) is derivable purely from the intended `createTask`
call and the live protocol state (`RegistryFacet.defaultFeeBps()`, `getDefaultHooks()`) — none of
it depends on anything the chain assigns only once the task is mined, since `duration`,
`pitchDuration` and `bidDuration` are relative offsets from `metadata.createdAt`, not absolute
timestamps. An off-chain implementation of this hash must be tested against
`keccak256(abi.encode(SponsoredTaskTerms.TASK_TERMS_TYPEHASH, terms))` directly, using the pinned
vector in `test/SponsoredTaskTerms.t.sol` (`test_hash_matchesPinnedVector`) on both sides, rather
than trusted by inspection: a wrong field name or ABI type produces a hash that differs only at
`TaskTermsMismatch`, not at compile or build time.

---

## Lifecycle

1. **Authorize.** Vault owner calls `vault.configureManager(manager, cap, true)` — mandatory;
   `reserveTask` reverts `ManagerNotActive` without it.
2. **Fund fee credit.** Manager `approve`s USDC to `SponsoredTaskFeeBank` and calls `deposit` —
   the credit `checkFund` charges the flat creation fee against.
3. **Create.** Manager creates a Taskmarket task with the hook and its `hookData` attached.
   `checkFund` validates the request, reserves `grossAmount` from the vault
   (`available → reserved`), and charges the creation fee — all in the same transaction as
   `createTask`. Any later revert (including an unmet precondition above) rolls the whole task
   creation back.
4. **Execute.** The task follows its normal Taskmarket lifecycle and evaluation.
5. **Complete.** The mandatory `checkComplete` callback commits the verdict's awards digest.
   **Nothing in this step pays anyone** — see Settlement below.
6. **Settle.** A permissionless `finalizeSettlement(taskId, awards)` call — supplying the exact
   awarded array, verified against the committed digest — installs a Merkle root on the vault.
7. **Claim.** Each awarded worker signs a destination-bound EIP-712 claim; the backend relays it
   gaslessly. Destination is bound inside the signature — no manager or owner can redirect it.
8. **Release.** Cancellation, expiry, or forfeiture returns the unearned reservation to
   `available` and restores the manager's spend capacity via `finalizeRelease`/`reconcile`.

---

## Award-count overflow (`MAX_AWARDS`)

`MAX_AWARDS = 8` is a **gas-safety threshold**, not a rejection rule. `_commitCompletion` loops
over awards to build the awards digest inside the mandatory `checkComplete` callback, under the
Diamond's fixed 1,000,000 gas hook stipend. A verdict exceeding this count does **not** revert
`checkComplete` (and therefore never blocks Taskmarket's own USDC settlement): the vault
reservation is released back to `available` and the allocation moves to the terminal
`AwardCountExceeded` status. `_checkEvaluate` does not enforce this cap at all — enforcement
lives solely at the completion boundary, where failure is provably non-terminal for USDC.

This is a deliberate correctness property distinguishing this hook from the originally
prototyped design, which reverted `evaluate()` itself on an oversized verdict (see the PR that
introduced this fix for the full before/after).

---

## Settlement keeper (operational requirement)

Nothing in the Taskmarket lifecycle drives a completed allocation to settlement or release —
`finalizeSettlement`, `finalizeRelease`, and `reconcile` are all permissionless but must be
actively called by an operator. Funds are never lost if nobody calls them, but they strand
(recoverably) in a reserved state until either an operator runs the keeper or the vault
owner eventually exits. Daydreams runs a backend service on the existing relay/outbox
machinery that watches for `CompletionCommitted` and terminal task states and drives each
allocation to a terminal outcome — this is a standing operational commitment, not a one-off
migration script.

---

## Curation

`SponsoredTaskFactory.createVault` is permissionless — any address can create a vault
for any ERC-20 with deployed code. Which vaults appear as valid, endorsed options in
Daydreams' own product surfaces (task cards, search, agent discovery, CLI, web) is a separate,
off-chain, revocable curation decision. An unverified or rejected vault's
sponsored task reward is never rendered as `$0`; it is marked explicitly unpriced/unverified.

---

## Owner authority and the emergency-exit trust boundary

The vault owner can always recover funds. Normal withdrawal (`withdrawAvailable`) is
limited to the unreserved balance; recovering reserved or claimable tokens requires
`emergencyExitVault`, which sweeps the entire vault balance — **including already-earned,
unclaimed worker funds** — closes the vault permanently, and bumps its epoch so every
outstanding signature and Merkle proof is invalidated at once. There is no timelock and no
per-allocation revoke at the contract level. This is the single largest trust assumption in
the system: a worker can complete accepted work and receive zero project tokens if the owner
exits at the wrong moment. The Base USDC settlement is unaffected either way — `checkComplete`
and `checkEvaluate` both short-circuit to a no-op success once an allocation is
`DefaultedByOwner`.

Every task carrying a Sponsored Task reward must surface this trust model plainly wherever
the reward is shown, not only in a detail view.

---

## Security Considerations

- **Fee-on-transfer / rebasing tokens are rejected, not silently mishandled.** Both funding and
  payout paths use exact balance-diff transfer checks.
- **Manager cap exhaustion, an exited vault, or a missing FeeBank credit each revert the
  whole `createTask`** — these must be pre-flighted by any client before payment rather than
  discovered only after a revert.
- **Sequential per-worker claim nonces.** `claimTo` requires a strictly increasing
  `claimNonces[worker]`; relaying two of a worker's pending claims out of order reverts the
  later one and invalidates every other outstanding signature for that worker. A relayer must
  serialize claims per worker.
- **Dust awards are silently dropped from the Merkle tree.** An award whose net amount rounds
  to zero after fees gets no leaf; `leafCount` can be smaller than `awardCount`.
- **Sponsored task amounts are not proportional to USDC awards.** An `APPROVE` verdict
  distributes the entire vault gross pro-rata by award weight; `PARTIAL` scales by the USDC
  payout ratio.

### Trust and token assumptions

- **The hook is every hook-mode vault's controller.** `SponsoredTaskHook` is UUPS-upgradeable,
  and each vault it creates names it as `controller`, so a hook upgrade can change how reserved
  project tokens are released or settled. Upgrade authority must sit behind the owner Safe and
  timelock, never a single key. A vault owner keeps `emergencyExitVault` at all times, whatever
  the hook does.
- **Balance-mutating tokens are unsupported.** Transfer checks catch fee-on-transfer behaviour at
  the moment of a transfer, but a rebasing token, or any token whose balances can change outside
  a transfer, can leave a vault holding less than its recorded `totalReserved + totalClaimable`.
  `available()` then reverts `Insolvent`. Such tokens must not be approved for listing.

This has had a `make contract audit` (Slither) pass and automated internal review, not a
professional external audit — this team has no external audit capacity today. A real audit should
be commissioned before any mainnet deployment moving non-trivial value.

---

## Deployment

See `script/DeploySponsoredTask.s.sol` (initial deploy — forces `SponsoredTaskFeeBankGuard`
ownership of the FeeBank unconditionally) and `script/UpgradeSponsoredTask.s.sol` (in-place
UUPS upgrade for the hook only, mirroring `UpgradeRewardHook.s.sol`).
`script/DeploySponsoredTaskFeeBankGuard.s.sol` is a separate, mainnet-only, runtime-hash-pinned
hardening script for re-activating or auditing a guard independent of the main deploy flow.

Makefile targets: `make deploy-sponsored-task <testnet|mainnet|preview>`,
`make upgrade-sponsored-task <testnet|mainnet>`.

---

## Integration

A vault manager attaches this hook the same way any other custom hook is attached — it is
never a protocol default. The CLI's `task create` command accepts
`--sponsored-task <vaultId> --tokens <amount>` flags that build `hookData` from live vault state,
pre-flight the preconditions above, and pass the hook at `createTask`.

---

## Event indexing

Vaults are dynamic per-vault clone addresses, not a single fixed address — an
indexer watching only the hook's fixed address will see the task lifecycle
(`SponsoredTaskFunded`, `CompletionCommitted`, `SettlementPrepared`,
`ReservationReleased`, `SponsoredTaskDefaultedByOwner`, `SponsoredTaskEntitlement`) but **not**
vault-side events (`VaultFunded`, `ManagerConfigured`, `TaskReserved`, `SponsoredTaskClaimed`,
`VaultEmergencyExited`, etc.), which requires a second, dynamically-maintained address-set
stream sourced from `VaultCreated`/registry events.
