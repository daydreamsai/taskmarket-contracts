# Rev023 -- gas guards on swallowed calls

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

Ratings made before rev022 also had no registry entry, and `rateTask` refuses to rate a worker
twice, so nothing could deliver them.

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

### Backfill

Ratings made before rev022 had no registry entry, and `rateTask` refuses to rate a worker twice. A
temporary owner-only facet, routed and unrouted by standalone scripts outside the revision sequence,
delivered them from the original transactions' arguments, attributed to the Diamond. It has since been
removed, and the selector routes nowhere.

## Upgrade

`Rev023Upgrade` requires a diamond at revision 22:

```sh
make upgrade testnet rev023
make upgrade mainnet rev023
```

## Verification

`Rev023Upgrade.t.sol` asserts the bytecode behind every selector of all four facets moved,
`DiamondSelectorParity.t.sol` replays the whole sequence, and `TaskMarket.t.sol` covers the gas floor
at each call site, the absence of a floor when no registry call is due, and the hook guard on
`onComplete` and its absence on `onExpire`.
