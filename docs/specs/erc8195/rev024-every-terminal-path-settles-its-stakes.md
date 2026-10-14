# Rev024 -- every terminal path settles what it holds

## Status

Implemented.

## Problem

The diamond keeps every task's escrow and stakes in one pooled USDC balance. Several paths that
end a task left part of what they held in that balance, owed to no task. Once a task is terminal no
later call reads those amounts, so nothing short of an upgrade could recover them.

- **Claim stake on evaluator settlement.** A Claim worker's stake is returned by
  `acceptSubmission` and `refundExpired`, and forfeited by `forfeitAndReopen`. A Claim task with an
  evaluator cannot use `acceptSubmission`; it settles through `finalizeVerdict` or
  `resolveDispute`, and neither touched `task.stakeAmount`.
- **Evaluator stake on cancel.** The evaluator stake is pulled from the requester when the evaluator
  is assigned. `evaluate` pays it to the evaluator, and `evaluatorTimeout` and `refundExpired`
  forfeit it, but `cancelTask` refunded only the reward.
- **Rounding in multi-winner acceptance.** `acceptSubmissions` pays each winner its share of the
  reward rounded down, so the awards can sum to a few base units less than the reward.
- **Appeal with no dispute resolver.** Only the dispute resolver can call `resolveDispute`. An
  appeal on a task whose evaluator config has no resolver moved it to `Disputed`, where nothing
  could settle it until expiry; `refundExpired` then paid the requester and the worker lost any
  award the verdict gave them.
- **Auction evaluator fee on the price cap.** `evaluate` charged the evaluator fee on
  `task.reward`. For an auction that is the price cap the requester escrowed, not the price the task
  settled at, so the evaluator was overpaid and the requester's refund short by the difference.
- **Feedback gas floor too low on Tempo.** rev023 made every swallowed ERC-8004 `giveFeedback`
  call require 450,000 gas left (`MIN_FEEDBACK_GAS`), sized for a registry call of about 220k on
  Base. On Tempo the same call measured about 799,172 gas typically and 1,801,816 at most. A call
  that reaches the check with between 450k and about 1.83M gas left (the worst case plus the
  surrounding overhead) passes it, the registry call then runs out of gas inside the `try`, and the
  outer call succeeds with `ReputationFeedbackFailed`: the silent drop rev023 set out to prevent.

## Change

- `finalizeVerdict` and `resolveDispute` settle a Claim worker's stake exactly once and zero
  `task.stakeAmount`. A worker who receives an award gets the stake back (`StakeReturned`), as
  with `acceptSubmission`. A worker who is awarded nothing -- a REJECT verdict, or a verdict or
  dispute resolution that pays them zero -- forfeits it (`StakeForfeited`, recorded in
  `stakeForfeit`). The stake exists to make submitting work that will not pass costly; without the
  forfeit a worker could submit anything at no risk. The forfeit goes to the requester, whose task
  the rejected work held up. `forfeitAndReopen`, the missed-deadline forfeit, still pays the fee
  recipient in this revision.
- `cancelTask` refunds the evaluator stake to the requester who posted it, zeroes it and emits the
  new `EvaluatorStakeRefunded(taskId, requester, amount)` event. A task can only be cancelled while
  Open, before the evaluator has had anything to evaluate. `TaskCancelled` still reports the reward
  refund only.
- `acceptSubmissions` returns the rounding remainder of the split to the requester.
- `appeal` reverts with the new `NoDisputeResolver` error when the evaluator config has no dispute
  resolver. The verdict then finalizes when the appeal window closes. Assignment without a resolver
  stays valid, so existing integrations that never appeal are unaffected. `TaskDisputed` is emitted
  on every appeal, since a resolver now always exists.
- The evaluator fee is computed in one place, `LibTaskMarket._evaluatorFee`: basis points of the
  accepted price for an auction (`task.stakeAmount`, set by `selectLowestBidder` and
  `acceptAuction`) and of the reward for every other mode. `evaluate`, `finalizeVerdict`,
  `resolveDispute` and `refundExpired` all use it, so the amount charged and the amount later
  deducted always agree. The fee on a REJECT verdict is unchanged.
- Every other terminal path was checked and already settles what it holds: `acceptSubmission` in
  each mode, `evaluatorTimeout` followed by acceptance or expiry, `forfeitAndReopen`, and both
  `refundExpired` branches.

### Per-chain feedback gas floor

- `AppStorage` gains `uint256 minFeedbackGas`, appended after `minAppealWindowSecs` as the last
  field. `LibTaskMarket._requireFeedbackGas()` checks `gasleft()` against
  `_minFeedbackGas(s)`: the stored value, or `MIN_FEEDBACK_GAS` (450,000) while it is zero. Every
  diamond reads zero after the upgrade, so Base keeps exactly the rev023 behaviour with no call.
- `AdminFacet.setMinFeedbackGas(uint256)` (owner only) sets it and emits
  `MinFeedbackGasUpdated(uint256)`; `AdminFacet.minFeedbackGas()` returns the effective value.
  The setter rejects with `InvalidMinFeedbackGas` a value below 450,000, which would reopen the
  window the floor closes, or above 5,000,000 (`MAX_FEEDBACK_GAS`), where settlement paths that
  reach a feedback call could no longer fit under a chain's transaction gas cap.
- Tempo (chains 4217 and 42431) uses 1,900,000: the 1.83M worst case with about 5% headroom. A
  floor is a minimum, not a reservation, so a higher value costs nothing on calls that already have
  the gas; it only refuses limits that would have dropped the feedback.
- A single higher constant was rejected: it would raise the floor on Base fourfold for a cost that
  only Tempo's registry has, and change estimates and limits that Base integrations already use.
  An explicit gas stipend on the `giveFeedback` call was also not used: the registry's cost varies
  by chain and by call, and a stipend that is too low drops the feedback exactly as before.
- The check needs a storage read, so it compiles into each facet that calls it: `AcceptanceFacet`,
  `CoreFacet` and `RatingFacet`.

`Rev024Upgrade` replaces `AcceptanceFacet`, `CoreFacet`, `EvaluatorFacet` and `RatingFacet` with
their full selector lists, Replaces `AdminFacet`'s nineteen existing selectors and Adds
`minFeedbackGas()` and `setMinFeedbackGas(uint256)`. Storage gains one appended field,
`minFeedbackGas`; no existing field moves. It resolves the diamond through `DeployTarget`, so it
runs on Base and Tempo.

### Tasks in flight at the upgrade

An auction task with a nonzero evaluator fee that is `Appealing` or `Disputed` when the upgrade
lands was charged the old fee at `evaluate` and would be settled with the new one, refunding the
requester more than the task holds. Before upgrading, confirm no such task exists on the target
chain, or wait for any that do to settle.

### Hook and reputation gas

`onCancel` and `onExpire` dispatched through the swallowing path, so a relayed call whose limit
left a hook less than its stipend completed with the hook's release silently skipped. On Tempo
Moderato a relayed cancel sent with an 889k limit reached `onCancel` with about 256k and the hook
failed unnoticed. Both now use the same full-gas guard as `onComplete` and `onForfeit`: when less
than the stipend (plus the 63/64 forwarding loss and a margin) is left for a hook, the call reverts
`InsufficientGasForHook`. This covers the evaluator's REJECT verdict too, which releases through
`onCancel`. The guard does not block fund recovery: it demands at most one stipend per attached
hook (eight hooks, about 9M gas), and any caller can send that.

## Upgrade

`Rev024Upgrade` replaces AcceptanceFacet, CoreFacet, EvaluatorFacet, RatingFacet and AdminFacet, and
requires a diamond at revision 23:

```sh
make upgrade testnet rev024
make upgrade mainnet rev024
```

When `FORGE_MIN_FEEDBACK_GAS` is set, the same broadcast calls `setMinFeedbackGas` with it before
bumping the version, and `DiamondDeploy` does the same on a fresh diamond. The value is configured
per network as `FORGE_MIN_FEEDBACK_GAS_<NETWORK>`, like every other deploy input; `script/tempo.sh`
refuses a Tempo deploy or upgrade without `FORGE_MIN_FEEDBACK_GAS_TEMPO_TESTNET` or
`_TEMPO_MAINNET` (1,900,000), so the new facets never run on Tempo with the Base default. Base
leaves it unset.
To change it later, the owner calls `setMinFeedbackGas` directly; read it back with
`minFeedbackGas()`.

## Verification

- `StakeSettlement.t.sol` runs one task to each terminal path on a fresh diamond and asserts the
  exact payout to each party and a zero diamond balance afterwards: every verdict, dispute
  resolution for and against the worker, a zero award, cancel with and without an evaluator stake, appeal with and without a resolver, the
  auction fee on finalize and on expiry, and the multi-winner remainder.
- `invariant/EscrowConservation.t.sol` drives random lifecycles across Claim, Bounty and Dutch
  auction tasks, with and without an evaluator, evaluator stake, claim stake and dispute resolver,
  and asserts the diamond balance always equals what the live tasks still owe. Against the rev023
  facets it fails on a cancelled task with an evaluator stake, and with only the rev023
  `EvaluatorFacet` it fails on the verdict and dispute paths.
- `Rev024Upgrade.t.sol` asserts the bytecode behind every selector of the five facets moved, the two
  AdminFacet selectors are added, existing admin state survives the cut, the floor reads 450,000 on
  Base and 1,900,000 on both Tempo chains afterwards, and `DiamondSelectorParity.t.sol` replays the
  whole sequence.
- `TaskMarket.t.sol` asserts the 450,000 default, that a `rateTask` limit of 1M succeeds under the
  default but reverts `InsufficientGasForFeedback` once the floor is 1.9M, the setter's bounds,
  owner check and event.
- `TaskMarket.t.sol` sweeps gas limits on a relayed `cancelTask` and on `refundExpired` with a hook
  attached, asserts some limit reverts `InsufficientGasForHook` without calling the hook, and that
  3M runs the hook.
