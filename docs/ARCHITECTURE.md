# TaskMarket Contract Architecture

Developer reference for non-obvious technical decisions in the Diamond proxy and facet design.

---

## Diamond Proxy (EIP-2535)

TaskMarket uses the Diamond proxy pattern. The proxy address is permanent — it is what gets
deployed on-chain, listed in the UI, and what users interact with. Logic is split across
nine facet contracts, each well under the EIP-170 24,576-byte limit. Facets are upgradeable
individually via `diamondCut` without redeploying the proxy.

All calls enter through `Diamond.fallback()`, which looks up the target facet address in
`LibDiamond.DiamondStorage` using the 4-byte selector, then delegates via `delegatecall`.
All facets execute in the Diamond's storage context, sharing `AppStorage`.

---

## AppStorage

All state is unified in `AppStorage`, a struct stored at a deterministic slot:

```solidity
bytes32 constant APPSTORAGE_SLOT = keccak256("taskmarket.appstorage.v1");
```

Every facet accesses it via `LibAppStorage.appStorage()`. The struct is defined in
`src/libraries/LibAppStorage.sol`.

**Adding new state**: append to the END of the struct. Never insert between existing fields.
No `__gap` is needed: the struct lives at a fixed `keccak256` slot and appending is always
safe. New fields zero-initialise by default; use lazy-init in the facet function body if a
non-zero default is needed.

---

## Task Struct Split

The `Task` struct in `ITMPCore` has 12 fields. This is a hard ceiling, not a style preference.

### Why

`forge coverage` forcibly disables `via_ir` and the Solidity optimizer to generate accurate
source mappings. Without `via_ir`, the legacy ABI encoder puts every field of a returned struct
on the Yul stack simultaneously. The Yul stack limit is 16 slots. A struct with N fields
needs N + 2 slots (N values + `headStart` + `RET`). At 12 fields that is 14 slots — safely
under the limit. At 13 or more fields coverage compilation fails with
`Stack too deep. Try compiling with --via-ir`.

The design follows the Uniswap V4 / Aave split-by-concern pattern: a lean core struct for
fields used on every execution path; extension fields in separate mappings keyed by `taskId`.
A monolithic struct with all task fields would exceed the stack limit and make `forge coverage`
unusable.

### What lives where

| Mapping                  | Getter                      | Fields                                                           | When non-zero           |
|--------------------------|-----------------------------|------------------------------------------------------------------|-------------------------|
| `tasks`                  | `getTask()`                 | id, requester, worker, status, mode, reward, expiryTime, stakeAmount, feeBps, deliverable, rating, hookContract | always |
| `taskMetadata`           | `getTaskMetadata()`         | createdAt, claimedAt, contentHash, contentURI                    | always (set at creation)|
| `taskPitchConfigs`       | `getTaskPitchConfig()`      | pitchDeadline                                                    | PITCH mode only         |
| `taskAuctionConfigs`     | `getTaskAuctionConfig()`    | bidDeadline, maxPrice, auctionSubtype, lowestBidder, lowestBidPrice | AUCTION mode only    |
| `taskEvaluatorConfigs`   | `getTaskEvaluatorConfig()`  | evaluator, evaluatorStake, evaluatorFeeBps, evaluationWindow, appealWindow, disputeResolver | evaluator assigned |

### Rule for new fields

Do not add fields to the core `Task` struct. New task-related fields go into an existing
extension mapping if they fit the same concern, or into a new mapping appended to `AppStorage`
if they represent a new concern.

---

## phaseDeadline Dual Purpose

`phaseDeadline[taskId]` has two distinct meanings depending on task state:

- **Review state**: holds the evaluation deadline. Set by `submitWork` when the task
  transitions to `Review`. Read by `evaluatorTimeout` to check whether the evaluator has
  missed their window.
- **Appealing state**: holds the appeal deadline. Overwritten by `evaluate()` when the task
  transitions to `Appealing`. Read by `appeal()` (must be before deadline) and
  `finalizeVerdict()` (must be at or after deadline).

This dual use avoids a separate AppStorage field. The invariant is safe because a task can only
be in one of these states at a time.

---

## PGTR-Only Mutating Functions

User-facing task-flow functions call `LibTaskMarket._requireForwarder(s)`. Direct calls from
EOAs or non-registered contracts will revert. The following functions are explicitly exempt
and may be called without a PGTR forwarder:

- `refundExpired` — fund-recovery invariant; must always be callable once a task expires
- `finalizeVerdict` — permissionless after appeal window closes
- `resolveDispute` — callable by the designated dispute resolver address only
- All `AdminFacet` functions — owner-only via `LibDiamond.enforceIsContractOwner`
- `diamondCut` — owner-only

`LibTaskMarket._effectiveSender(s)` returns `IPGTRForwarder(msg.sender).pgtrSender()` when
the caller is a trusted forwarder, otherwise `msg.sender`. The `msg.sender` branch is
unreachable for PGTR-gated functions in normal operation but is retained as a defensive
fallback for the exempt paths above.

---

## Fund Recovery Invariant

`refundExpired()` is explicitly exempt from all hook checks and MUST always be callable once
a task has expired. The design rule is: any code path that extends `expiryTime` must ensure
the extension only covers the duration of active work (evaluation window, appeal window), and
only while funds are legitimately locked. No hook, evaluator, or dispute resolver may block
a requester from recovering escrowed funds after all deadlines have passed.

When an evaluator is assigned and `submitWork` is called, `expiryTime` is extended to
`max(expiryTime, block.timestamp + evaluationWindow)` so that `refundExpired` cannot fire
while the submission is under active assessment.

---

## Upgrade Mechanism

Upgrades use `diamondCut(FacetCut[], address init, bytes calldata data)`:

- `Add`: register new selectors pointing to a new facet address
- `Replace`: reroute existing selectors to a new facet implementation
- `Remove`: unregister selectors (calls to them revert)

Only the contract owner may call `diamondCut`. Post-upgrade initialisation, if needed, is
passed as the `init`/`data` arguments. There is no reinitializer pattern — new AppStorage
fields zero-initialise by default.

---

## Ownership

Ownership lives in `LibDiamond.DiamondStorage` (separate from `AppStorage`). Two-step transfer:

- `AdminFacet.transferOwnership(address)` — sets `pendingOwner`
- `AdminFacet.acceptOwnership()` — promotes `pendingOwner` to `contractOwner`

`LibDiamond.enforceIsContractOwner()` is called by `DiamondCutFacet` and `AdminFacet`.

---

## ReentrancyGuard

The reentrancy guard uses `AppStorage.reentrancyStatus` directly (not OpenZeppelin's
`ReentrancyGuard`) because all facets run via `delegatecall` into the Diamond's storage.
`LibTaskMarket._nonReentrantBefore` and `_nonReentrantAfter` wrap every state-mutating
function body.

---

## CEI Pattern

All mutating functions follow Checks-Effects-Interactions: state is fully committed before
any external call (USDC transfers, hook callbacks, reputation registry calls). Hook callbacks
that are fire-and-forget notifications (`on*` hooks) are called after state is committed and
payments are sent. Hook callbacks that gate state transitions (`check*` hooks) are called
after state is committed but before payments, so the hook sees final state when making its
decision.
