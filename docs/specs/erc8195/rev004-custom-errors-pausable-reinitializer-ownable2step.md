# ERC-8195 Rev 004 — Custom Errors, Pausable, Reinitializer, Ownable2Step

This document is the normative specification for four additions implemented in TaskMarket Rev 004.

---

## 1. Custom Errors

All `require(condition, "string")` reverts are replaced with typed Solidity custom errors
(Solidity 0.8.4+). Errors are declared inside `interface ITMPCore` so they are ABI-visible as
`ITMPCore.ErrorName.selector` to callers, test suites, and off-chain integrators.

### Why

String reverts waste calldata proportional to message length and consume extra gas compared
to custom errors. Custom errors carry no string payload — just a 4-byte selector — which
reduces deployment size and revert cost, and gives off-chain clients a stable, ABI-decodeable
identifier that does not change if wording is revised.

### Error catalogue

| Category | Errors |
|---|---|
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

### Naming note

`TaskIsCancelled` and `TaskIsExpired` use the `Is` prefix to avoid shadowing the
`TaskCancelled(...)` and `TaskExpired(...)` events defined in the same interface. Solidity
treats identifiers in the same namespace — a bare `TaskCancelled` in a declaration is
ambiguous between the error and the event.

---

## 2. Ownable2Step

`OwnableUpgradeable` is replaced with `Ownable2StepUpgradeable` from OpenZeppelin v5.
The two-step pattern requires the incoming owner to explicitly call `acceptOwnership()` before
the transfer completes.

### Why

Single-step ownership transfer is irreversible if the target address is mistyped or
inaccessible. With Ownable2Step, a transfer to a wrong address leaves `owner()` unchanged
until the new address accepts; the current owner retains full control and can start a fresh
transfer.

### Upgrade initialization

`Ownable2StepUpgradeable` inherits `OwnableUpgradeable`. The `__Ownable_init(msg.sender)`
call in `initialize()` is unchanged — it sets the initial owner on first deploy.

### Storage

`Ownable2StepUpgradeable` uses ERC-7201 namespaced storage. It does NOT consume slots from
`__gap[38]`.

### Admin operation

```bash
# Transfer ownership (current owner calls this)
cast send $CONTRACT_ADDRESS "transferOwnership(address)" $NEW_OWNER_ADDRESS \
  --private-key $FORGE_DEV_PRIVATE_KEY --rpc-url $EVM_RPC_URL

# Accept ownership (new owner must call this)
make contract accept-ownership
```

---

## 3. Emergency Pause

`PausableUpgradeable` from OpenZeppelin v5 is added as an emergency circuit breaker. The
owner can halt all state-mutating operations without exception.

### Scope

All state-mutating functions carry `whenNotPaused`. There are no exemptions. A bug could
exist in any function — including fund recovery paths — so carving out exceptions would
leave attack vectors open during an emergency.

Modifier order for forwarded functions: `external onlyTrustedForwarder whenNotPaused nonReentrant`.

### Behavior while paused

All state changes stop. No USDC moves into or out of the contract. Funds remain safe in
escrow. The owner MUST deploy a fix via UUPS upgrade and unpause promptly. Task expiry
windows are measured in days, so a short pause does not permanently strand funds.

### Storage

`PausableUpgradeable` uses ERC-7201 namespaced storage. It does NOT consume slots from
`__gap[38]`.

### Admin operations

```bash
make contract pause    # halt all forwarded operations
make contract unpause  # restore normal operation
```

---

## 4. Bid Cap (MAX_BIDS_PER_TASK)

A constant `MAX_BIDS_PER_TASK = 500` is added to `TaskMarket.sol`. `submitBid` reverts with
`BidLimitReached` when the number of bids for a task reaches this limit.

### Why

The `taskBids` array is iterated by off-chain tooling and has no on-chain upper bound prior
to this revision. An adversary could exhaust gas limits by submitting bids up to the block
gas limit, making `getBids` and any downstream iteration prohibitively expensive. The 500 cap
bounds the worst case while accommodating any realistic auction with room to spare.

This limit is normative for ERC-8195 implementations: implementations MUST enforce a
maximum bid count per task. The reference implementation uses 500.

---

## 5. Reinitializer Convention

`initialize()` uses the `initializer` modifier (equivalent to `reinitializer(1)`). This
modifier can only fire once — the initializer state is stored in ERC-7201 namespaced
storage by `Initializable`.

Future upgrades that need to initialize new state variables MUST use `reinitializer(N)` with
N incrementing by 1 per upgrade that introduces new state. Call the new function via
`upgradeToAndCall`:

```solidity
// In the new implementation contract:
function initializeV2(address newDependency) public reinitializer(2) {
    newVar = newDependency;
}
```

```bash
# Upgrade with reinitializer call (in Upgrade.s.sol or cast):
cast send $PROXY_ADDRESS "upgradeToAndCall(address,bytes)" $NEW_IMPL \
  $(cast calldata "initializeV2(address)" $NEW_DEPENDENCY_ADDRESS) \
  --private-key $FORGE_DEV_PRIVATE_KEY --rpc-url $EVM_RPC_URL
```

If an upgrade introduces no new state, pass empty calldata:

```bash
cast send $PROXY_ADDRESS "upgradeToAndCall(address,bytes)" $NEW_IMPL "0x" \
  --private-key $FORGE_DEV_PRIVATE_KEY --rpc-url $EVM_RPC_URL
```

**Rules:**
- `__Ownable_init` and `__Pausable_init` MUST NOT be called in reinitializers — they only
  belong in the initial `initialize()`.
- Increment N by 1 for each upgrade that uses `reinitializer`. Never reuse an N.
- If two upgrades happen without reinitializer (no new state), the N counter stays the same.
