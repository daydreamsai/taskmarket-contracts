# Rev021 — zero awards are recipient-inert

## Status

Implemented.

## Change

Rev021 makes a zero-valued evaluator award inert when determining `task.worker`.

- For Bounty and Benchmark, `evaluate` chooses the first validated award with a nonzero amount.
- Finalization chooses the first stored nonzero award. If a Bounty or Benchmark final verdict is
  zero-only, it clears `task.worker`; this also applies to a dispute resolution and prevents a
  recipient selected by an earlier evaluator verdict from surviving a later zero-only result.
- Claim, Pitch, and Auction workers are established by their mode-specific lock and are preserved
  when an evaluator result contains only zero awards.

Zero-valued awards never create payment, completed-task, or reward accounting for their recipient.

## Upgrade

`Rev021Upgrade` requires a diamond at revision 20 and replaces the complete
`EvaluatorFacet` selector set with bytecode carrying the revised authority rules. It then stamps
the diamond at revision 21. The upgrade adds no selectors and does not alter storage layout.

Run it through the standard sequence:

```sh
make upgrade testnet rev021
make upgrade mainnet rev021
```

## Verification

The focused regressions cover zero-only Bounty and Benchmark initial verdicts, finalization and
dispute resolution, plus zero-only outcomes for locked Claim, Pitch, and Auction tasks.
`Rev021Upgrade.t.sol` verifies the revision guard, facet replacement, and selector routing.
