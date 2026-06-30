# ERC-8195 Revision 004 — Custom Errors, Pausable, Reinitializer, and Ownable2Step

**Revision:** 004
**Date:** 2026-05-22
**PRs:** (internal — no external PR link)

## Motivation

The Rev 003 contract reverted with string messages, used single-step ownership transfer, had no
emergency pause mechanism, and had no convention for initializing new state variables on upgrade.
These are independent but related hardening concerns: the custom errors change reduces gas and
improves client integration; Ownable2Step prevents ownership loss from a mistyped address;
Pausable provides a circuit breaker if a bug is discovered post-deployment; the reinitializer
convention defines how future upgrades safely initialize new storage. All four are addressed
in this revision. A bid cap is also added to close an unbounded iteration vector introduced by
the auction feature.

---

## Problem 1 — String reverts were costly and unstable as client identifiers

`require(condition, "string")` reverts encoded the full error string in calldata on every
revert. String payloads consume gas proportional to message length, increase deployment size,
and give off-chain clients no stable identifier — if the wording changed, any client matching
on the string would silently break.

## Problem 2 — Single-step ownership transfer was irreversible on typo

`OwnableUpgradeable` transferred ownership in a single transaction. If the target address was
mistyped or belonged to an inaccessible wallet, the transfer was final: the contract lost its
owner permanently with no recovery path.

## Problem 3 — No emergency pause mechanism

If a critical bug was discovered in a state-mutating function after deployment, the only
remediation was an immediate upgrade. Preparing and executing an upgrade under incident
conditions takes time; meanwhile the vulnerable function remained callable. There was no
way to halt all operations instantly while the fix was prepared.

## Problem 4 — No normative pattern for upgrade-time initialization

The spec described using `initializer` for first deploy but was silent on how subsequent
upgrades should initialize new state variables. Without a convention, developers might
re-call `initialize()` (failing, because `initializer` can only fire once), or bypass
initialization entirely (leaving new state at zero-values unintentionally).

## Problem 5 — `taskBids` array had no upper bound

The `taskBids` mapping stored bids in an unbounded array. Off-chain tooling iterates this
array; an adversary could submit bids up to the block gas limit, making `getBids` and any
downstream iteration prohibitively expensive for legitimate callers.

---

## Changes

### 1. All string reverts replaced with typed custom errors

```solidity
// Before (rev003)
require(task.requester == msg.sender, "NotRequester");
require(task.status == TaskStatus.Open, "TaskNotOpen");

// After (rev004)
if (task.requester != _msgSender()) revert ITMPCore.NotRequester();
if (task.status != TaskStatus.Open)  revert ITMPCore.TaskNotOpen();
```

Errors are declared inside `interface ITMPCore` so they are ABI-visible as
`ITMPCore.ErrorName.selector` to callers, test suites, and off-chain integrators.

Full error catalogue:

| Category | Errors |
|----------|--------|
| Access control | `NotTrustedForwarder`, `NotRequester`, `NotWorker`, `NotEvaluator`, `NotDisputeResolver` |
| Task state | `TaskDoesNotExist`, `TaskNotOpen`, `TaskNotClaimed`, `TaskNotAccepted`, `TaskAlreadyAccepted`, `TaskIsCancelled`, `TaskIsExpired`, `TaskNotYetExpired`, `NotInAppealingState`, `NotInDisputedState`, `NotInReviewState` |
| Mode | `NotAClaimTask`, `NotAPitchTask`, `NotAnAuctionTask`, `NotABenchmarkTask`, `NotAClockPriceAuction`, `NotABidAuction`, `InvalidMode`, `InvalidAuctionSubtype`, `MultiSubmissionOnlyForBountyBenchmark` |
| Worker / deliverable | `InvalidWorker`, `InvalidRequester`, `WorkerMismatch`, `WorkerAlreadyRated`, `WorkerRequired`, `DeliverableRequired`, `DeliverableMismatch`, `DeliverableAlreadySet`, `WorkerNotSelected`, `WinnerNotSelected`, `UseEvaluate` |
| Evaluator / appeal | `EvaluatorAlreadyAssigned`, `InvalidEvaluator`, `WrongStatusForEvaluation`, `AppealWindowClosed`, `AppealWindowStillOpen`, `NoVerdictIssued`, `EvaluationWindowNotExpired`, `DisputeResolutionMustAwardWorkers`, `AwardsRequired` |
| Auction | `BidDeadlinePassed`, `BidExceedsMaxPrice`, `BidDeadlineNotPassed`, `NoBidsSubmitted`, `BidsExist`, `PriceExceedsMaxPrice`, `BidLimitReached` |
| Deadline / timing | `PitchDeadlinePassed`, `ExpiryMustBeInFuture`, `BidDeadlineMustBeInFuture`, `PitchDeadlineMustBeInFuture` |
| Config / params | `InvalidFeeRecipient`, `InvalidRecipient`, `InvalidForwarderAddress`, `FeeBpsTooHigh`, `RewardMustBeGreaterThanZero`, `DurationMustBeGreaterThanZero`, `EmptyPitchHash`, `EmptyProofHash`, `RatingMustBe0To100`, `NoWinners`, `LengthMismatch`, `SharesMustSumTo10000`, `AwardsExceedEscrow`, `ZeroPayoutPerPair` |
| Transfers | `WorkerPaymentFailed`, `FeeTransferFailed`, `StakeReturnFailed`, `AuctionRefundFailed`, `RefundFailed`, `ForfeitTransferFailed`, `StakeTransferFailed`, `EvaluatorPaymentFailed`, `RequesterRefundFailed`, `USDCRefundFailed`, `ExcessRefundFailed` |
| Hooks | `HookCheckFundRejected`, `HookCheckClaimRejected`, `HookCheckSelectWorkerRejected`, `HookCheckSubmitRejected`, `HookCheckCompleteRejected`, `HookCheckEvaluateRejected` |

Naming note: `TaskIsCancelled` and `TaskIsExpired` use the `Is` prefix to avoid shadowing the
`TaskCancelled(...)` and `TaskExpired(...)` events defined in the same interface. Solidity
treats identifiers in the same namespace — a bare `TaskCancelled` in a declaration is
ambiguous between the error and the event.

### 2. `OwnableUpgradeable` replaced with `Ownable2StepUpgradeable`

```solidity
// Before (rev003)
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
contract TaskMarket is ..., OwnableUpgradeable {
    function initialize(address owner) public initializer {
        __Ownable_init(owner);
    }
}

// After (rev004)
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
contract TaskMarket is ..., Ownable2StepUpgradeable {
    function initialize(address owner) public initializer {
        __Ownable_init(owner); // unchanged — sets initial owner on first deploy
    }
}
```

`Ownable2StepUpgradeable` requires the incoming owner to explicitly call `acceptOwnership()`
before the transfer completes. A transfer to a mistyped or inaccessible address leaves
`owner()` unchanged; the current owner retains full control and can start a fresh transfer.

`Ownable2StepUpgradeable` uses ERC-7201 namespaced storage. It does not consume slots from
`__gap[38]`.

Admin operations:

```bash
# Transfer ownership (current owner calls this)
cast send $CONTRACT_ADDRESS "transferOwnership(address)" $NEW_OWNER_ADDRESS \
  --private-key $FORGE_DEV_PRIVATE_KEY --rpc-url $EVM_RPC_URL

# Accept ownership (new owner must call this to complete the transfer)
make contract accept-ownership
```

### 3. `PausableUpgradeable` added as emergency circuit breaker

```solidity
// Before (rev003) — no pause mechanism

// After (rev004)
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
contract TaskMarket is ..., PausableUpgradeable {
    // All state-mutating functions carry whenNotPaused.
    // Modifier order for forwarded functions:
    // external onlyTrustedForwarder whenNotPaused nonReentrant
}
```

All state-mutating functions carry `whenNotPaused`. There are no exemptions. A bug could exist
in any function — including fund recovery paths — so carving out exceptions would leave attack
vectors open during an emergency.

While paused: all state changes stop; no USDC moves into or out of the contract; funds remain
safe in escrow. The owner MUST deploy a fix via UUPS upgrade and unpause promptly. Task expiry
windows are measured in days, so a short pause does not permanently strand funds.

`PausableUpgradeable` uses ERC-7201 namespaced storage. It does not consume slots from
`__gap[38]`.

Admin operations:

```bash
make contract pause    # halt all forwarded operations
make contract unpause  # restore normal operation
```

### 4. Reinitializer convention for future upgrades

```solidity
// Current initializer (rev004 and earlier)
function initialize(address owner) public initializer {
    // initializer == reinitializer(1); can only fire once
    __Ownable_init(owner);
    __Pausable_init();
}

// Future upgrade that introduces new state variables
function initializeV2(address newDependency) public reinitializer(2) {
    newVar = newDependency;
}
```

Upgrade with reinitializer call:

```bash
cast send $PROXY_ADDRESS "upgradeToAndCall(address,bytes)" $NEW_IMPL \
  $(cast calldata "initializeV2(address)" $NEW_DEPENDENCY_ADDRESS) \
  --private-key $FORGE_DEV_PRIVATE_KEY --rpc-url $EVM_RPC_URL
```

If an upgrade introduces no new state, pass empty calldata:

```bash
cast send $PROXY_ADDRESS "upgradeToAndCall(address,bytes)" $NEW_IMPL "0x" \
  --private-key $FORGE_DEV_PRIVATE_KEY --rpc-url $EVM_RPC_URL
```

Normative rules:

- `__Ownable_init` and `__Pausable_init` MUST NOT be called in reinitializers — they belong
  only in the initial `initialize()`.
- Increment N by 1 for each upgrade that uses `reinitializer`. Never reuse an N.
- If two upgrades ship without reinitializer (no new state), the N counter stays the same.

### 5. `MAX_BIDS_PER_TASK = 500` — bid cap

```solidity
// Before (rev003) — no upper bound on taskBids array
function submitBid(bytes32 taskId, ...) external {
    s.taskBids[taskId].push(bid);
}

// After (rev004) — cap enforced
uint256 public constant MAX_BIDS_PER_TASK = 500;

function submitBid(bytes32 taskId, ...) external {
    if (s.taskBids[taskId].length >= MAX_BIDS_PER_TASK) revert ITMPCore.BidLimitReached();
    s.taskBids[taskId].push(bid);
}
```

This limit is normative for ERC-8195 implementations: implementations MUST enforce a maximum
bid count per task. The reference value is 500. This bounds the worst-case iteration cost for
`getBids` and any downstream indexer while accommodating any realistic auction.

---

## Rationale

**Why declare errors inside `ITMPCore` rather than in a separate `ITMPErrors` interface?**

Declaring errors inside the interface they relate to keeps them colocated with the functions
that throw them. Off-chain clients and test suites import a single interface and get the full
error surface without hunting across files. A separate errors file would require two imports
everywhere.

**Why not use `is` prefix consistently (e.g. `IsTaskCancelled`) rather than only for the
ambiguous cases?**

The `Is` prefix signals an ambiguity resolution — it is a hint to the reader that the name
would otherwise shadow an event. Using it universally would add noise to all error names
without conveying additional meaning. Applying it narrowly to the two ambiguous cases is a
local fix for a local problem.

**Why not exempt `refundExpired` from `whenNotPaused`?**

`refundExpired` transfers USDC out of the contract. If a bug exists in the refund logic itself
— not just in other functions — leaving it unpaused during an emergency means the vulnerability
can still be exploited on the recovery path. Total pause gives the owner a clean surface to fix
before reopening any transfer function. Task expiry windows (measured in days) provide enough
time for a prompt fix and unpause without permanently stranding funds.

**Why use `Ownable2StepUpgradeable` from OZ v5 rather than a custom two-step implementation?**

OZ v5's implementation is audited, widely reviewed, and uses ERC-7201 namespaced storage
(no slot consumption from `__gap`). A custom implementation adds audit surface without adding
capability. The OZ version is the obvious choice.

**Why is the bid cap 500 rather than a configurable per-task parameter?**

A per-task cap adds a storage field, extra calldata to `createTask`, and off-chain handling for
a feature whose only purpose is a safety bound. The 500 constant accommodates any realistic
auction (English or reverse-English) with substantial margin while bounding the worst-case
iteration to a fixed and documented limit. If the cap proves restrictive in practice, it can
be raised in a future revision.

---

## API Changes

- All string revert messages replaced with typed custom errors. Off-chain clients that parse
  revert reason strings MUST update to decode the 4-byte custom error selector instead. This
  is a **breaking change for any client that matches on string revert messages**.
- `pause()` and `unpause()` added as owner-only admin functions. No breaking change for
  existing callers; new admin operations only.
- `transferOwnership(address)` behavior changes: the transfer is now pending until the new
  owner calls `acceptOwnership()`. Scripts that previously called `transferOwnership` and
  assumed immediate effect MUST add an `acceptOwnership` step.
- `acceptOwnership()` added as a new function callable only by the pending owner.
- `submitBid` reverts with `BidLimitReached` when bid count reaches 500. Clients that do not
  check the current bid count before submitting may encounter this new revert in high-volume
  auctions.

---

## Affected Files

| File | Change |
|------|--------|
| `src/interfaces/ITMPCore.sol` | Add full custom error catalogue; add `pause`, `unpause`, `acceptOwnership` function signatures |
| `src/TaskMarket.sol` | Replace all `require(_, "string")` with typed error reverts; add `Ownable2StepUpgradeable` and `PausableUpgradeable` inheritance; add `whenNotPaused` to all state-mutating functions; add `MAX_BIDS_PER_TASK` constant and `BidLimitReached` guard in `submitBid`; document reinitializer convention in comments |
| `script/Upgrade.s.sol` | Document `upgradeToAndCall` with reinitializer pattern; add empty-calldata example for state-free upgrades |
| `docs/specs/erc8195/erc-8195.md` | Add Custom Errors section with full catalogue; add Ownable2Step section; add Pausable section; add Reinitializer Convention section; add bid cap normative requirement |
| `test/TaskMarket.t.sol` | Update all `vm.expectRevert("string")` calls to `vm.expectRevert(ITMPCore.ErrorName.selector)`; add pause/unpause and bid cap tests |
