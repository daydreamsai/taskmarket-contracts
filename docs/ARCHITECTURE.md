# TaskMarket Contract Architecture

Developer reference for non-obvious technical decisions in `TaskMarket.sol` and `ITMP.sol`.

---

## UUPS Upgradeable Proxy

`TaskMarket.sol` uses the UUPS (ERC-1967) upgradeable proxy pattern. The proxy address is
permanent — it is what gets deployed on-chain, listed in the UI, and what users interact with.
The implementation address changes on each upgrade.

**Consequence**: storage layout is immutable between upgrades. New state variables must always
be appended after existing ones and must consume from `__gap`. Never insert, reorder, rename,
or remove existing variables.

`__gap` started at 50 slots. Current value and consumers:

| Mapping / variable         | Slots consumed |
|----------------------------|---------------|
| `trustedForwarders`        | 1             |
| `requesterNonce`           | 1             |
| `taskTags`                 | 1             |
| `taskVerdicts`             | 1             |
| `phaseDeadline`            | 1             |
| `taskEvaluatorConfigs`     | 1             |
| `taskAuctionConfigs`       | 1             |
| `taskMetadata`             | 1             |
| `taskPitchConfigs`         | 1             |
| **Remaining `__gap`**      | **38**        |

---

## Task Struct Split

The `Task` struct in `ITMP.sol` has 12 fields. This is a hard ceiling, not a style preference.

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
extension mapping if they fit the same concern, or into a new mapping (consuming one `__gap`
slot) if they represent a new concern.

---

## phaseDeadline Dual Purpose

`phaseDeadline[taskId]` has two distinct meanings depending on task state:

- **Review state**: holds the evaluation deadline. Set by `submitWork` when the task
  transitions to `Review`. Read by `evaluatorTimeout` to check whether the evaluator has
  missed their window.
- **Appealing state**: holds the appeal deadline. Overwritten by `evaluate()` when the task
  transitions to `Appealing`. Read by `appeal()` (must be before deadline) and
  `finalizeVerdict()` (must be at or after deadline).

This dual use avoids a separate mapping slot. The invariant is safe because a task can only
be in one of these states at a time.

---

## PGTR-Only Mutating Functions

All state-mutating functions carry `onlyTrustedForwarder`. Direct calls from EOAs or
non-registered contracts will revert. The PGTR forwarder (`TaskMarketForwarder.sol`) is the
only supported entry point.

`_effectiveSender()` returns `IPGTRForwarder(msg.sender).pgtrSender()` when the caller is a
trusted forwarder, otherwise `msg.sender`. The `msg.sender` branch is unreachable in normal
operation (all mutating paths are gated) but is retained as a defensive fallback for view
contexts and any future non-forwarded extensions.

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

## Upgrade Initialization

`initialize()` uses the `initializer` modifier (equivalent to `reinitializer(1)`). On
first deploy this fires once and initializes all state including `__Ownable_init` and
`__Pausable_init`. These two calls MUST NOT appear in any subsequent reinitializer —
they write fixed owner/pause state that is already set.

When an upgrade introduces new state variables, the new implementation MUST add a function
with `reinitializer(N)` where N increments by 1 per upgrade that uses this mechanism.
The upgrade transaction calls `upgradeToAndCall(newImpl, calldata)` where `calldata`
encodes the reinitializer call. Upgrades with no new state pass empty calldata.

---

## ReentrancyGuard Choice

`ReentrancyGuardUpgradeable` does not exist in OpenZeppelin v5. The contract uses
`ReentrancyGuard` from `@openzeppelin/contracts/utils/ReentrancyGuard.sol` instead, which
uses namespaced storage and is safe with the UUPS proxy pattern.

---

## CEI Pattern

All mutating functions follow Checks-Effects-Interactions: state is fully committed before
any external call (USDC transfers, hook callbacks, reputation registry calls). Hook callbacks
that are fire-and-forget notifications (`on*` hooks) are called after state is committed and
payments are sent. Hook callbacks that gate state transitions (`check*` hooks) are called
after state is committed but before payments, so the hook sees final state when making its
decision.
