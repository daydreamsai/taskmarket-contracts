# Rev023 -- gas guards on swallowed calls, and a temporary feedback backfill

## Status

Implemented.

## Problem

Rev022 gave `rateTask` a gas floor. Four more places call the ERC-8004 reputation registry inside a
`try/catch` -- `acceptSubmission`, `acceptSubmissions`, `cancelTask` and `refundExpired` -- and have
the same flaw: when the relayer lets `eth_estimateGas` choose the limit, the estimate can land where
the registry call runs out of gas, is swallowed, and the outer call still succeeds.

Settlement hooks have the same shape. A hook call forwards at most 63/64 of the gas left, so on a
tight limit a swallowed `onComplete` or `onForfeit` is silently handed less than its stipend and a
payout or release inside it is skipped.

Ratings made before rev022 also have no registry entry, and `rateTask` refuses to rate a worker
twice, so nothing can deliver them.

## Change

- `LibTaskMarket._requireFeedbackGas()` reverts with `InsufficientGasForFeedback` when less than
  450,000 gas remains. Every swallowed `giveFeedback` call site calls it immediately before the
  `try`, including `rateTask`. It only runs when a registry call is actually due (a nonzero agent id
  and a configured registry), so it cannot affect tasks without ERC-8004 identities. A call that
  needs about 225k therefore always has about twice that available.
- `LibTaskMarket._dispatchAfterHooksFullGas` reverts with `InsufficientGasForHook` before a hook
  call when the gas left is below the hook stipend scaled for the 63/64 rule plus a 100,000 margin.
  It is used for `onComplete` and `onForfeit`, the paths where a caller can starve a settlement
  hook. A caller that is refused simply retries with more gas.
- `onCancel` and `onExpire` keep the unconditional swallow. They are recovery paths and must not
  block fund recovery, so no gas requirement is added to them.
- Both guards are internal-library code compiled into each facet that uses it, so `Rev023Upgrade`
  replaces `AcceptanceFacet`, `CoreFacet`, `EvaluatorFacet` and `RatingFacet` with their full
  selector lists. Selectors and storage layout are unchanged.

### Temporary backfill facet

`FeedbackBackfillFacet.backfillFeedback(FeedbackBackfill[])` is callable only by the Diamond owner.
Each entry must be a rating the Diamond recorded (`taskWorkerRated`) and must carry a worker agent
id and a rating of at most 100. The registry call is not wrapped in a `try/catch`, so a failure
reverts the whole batch. It emits `FeedbackBackfilled(taskId, worker, workerAgentId)`. Feedback is
attributed to the Diamond, the same client address `rateTask` uses, with tag1 `tmp.task.rating` and
tag2 taken from the task's mode.

The facet holds no storage and is not part of the revision sequence, the deploy script or
`FacetSelectors`; a fresh diamond never carries it. It is routed with
`script/temp/AddFeedbackBackfill.s.sol` (requires revision 23, changes no version) and unrouted with
`script/temp/RemoveFeedbackBackfill.s.sol`, which asserts the selector routes nowhere afterwards. The
Diamond keeps no record of which ratings reached the registry, so the off-chain backfill script is
responsible for not sending an entry twice.

## Upgrade

`Rev023Upgrade` requires a diamond at revision 22:

```sh
make upgrade testnet rev023
make upgrade mainnet rev023
```

## Verification

`Rev023Upgrade.t.sol` asserts the bytecode behind every selector of all four facets moved,
`DiamondSelectorParity.t.sol` replays the whole sequence, and `TaskMarket.t.sol` covers the gas floor
at each call site, the absence of a floor when no registry call is due, the hook guard on
`onComplete` and its absence on `onExpire`, and every backfill precondition.
