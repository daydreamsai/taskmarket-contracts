# Rev022 -- rateTask feedback gas floor

## Status

Implemented.

## Problem

`rateTask` calls the ERC-8004 reputation registry inside `try/catch`, so a failure of that call
never reverts the rating. `eth_estimateGas` searches for the smallest gas limit at which the outer
call succeeds. Because the catch swallows an out-of-gas inside the registry call, the estimate can
settle on a limit where the rating is recorded and the feedback is silently dropped. About 300
relayed `rateTask` transactions on Base mainnet landed in that state, with a gas limit near
330k and 90% of it consumed.

## Change

- `rateTask` reverts with `InsufficientGasForFeedback` when a registry call is due and
  `gasleft()` is below 450,000, so an under-funded limit can no longer succeed.
- A reverting `giveFeedback` now emits `ReputationFeedbackFailed(taskId, workerAgentId)`, matching
  the other facets, instead of being swallowed with no trace.

Selectors and storage layout are unchanged.

## Upgrade

`Rev022Upgrade` requires a diamond at revision 21, replaces the complete `RatingFacet` selector
set, and stamps revision 22.

```sh
make upgrade testnet rev022
make upgrade mainnet rev022
```

## Verification

`Rev022Upgrade.t.sol` covers the revision guard, facet replacement and selector routing.
`TaskMarket.t.sol` covers the gas floor revert and the failure event.
