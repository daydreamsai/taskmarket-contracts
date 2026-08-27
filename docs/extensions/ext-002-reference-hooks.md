# EXT-002: Reference ITMPHook Implementations

This directory contains deliberately small hook implementations intended as secure starting
points built on `BaseTMPHook`, not as a second general-purpose hook framework:

- `RequiredTagPolicyHook` rejects `checkFund` unless the task includes its immutable
  `requiredTag`; Taskmarket's update flow cannot change tags, so accepted tasks stay compliant.
- `AllowlistedWorkerHook` supports Bounty and Claim tasks only. It allows only its immutable
  `allowedWorker` to submit Bounty work or claim and submit Claim work.
- `CompletionReceiptHook` is an observational hook that records completion, forfeiture,
  cancellation, and expiry receipts without gating any transition.

## Example

Deploy a hook with the Taskmarket Diamond proxy address, then include its address in the task's
immutable `HookConfig` at creation:

```solidity
RequiredTagPolicyHook hook =
    new RequiredTagPolicyHook(address(taskmarketDiamond), keccak256("public-goods"));
address[] memory hooks = new address[](1);
hooks[0] = address(hook);
ITMPCore.HookConfig memory hookConfig = ITMPCore.HookConfig({contracts: hooks, data: hex""});
// createTask(..., hookConfig, ...)
```

## Security model and tradeoffs

All ten lifecycle callbacks are guarded by `BaseTMPHook.onlyDiamond`. The Diamond address is an
immutable constructor argument and zero addresses are rejected. This prevents an arbitrary EOA
or contract from forging callback data or receipts. Hooks are therefore tied to one deployment;
deploy a new hook for a different Diamond rather than attempting to retarget one.

Checks default to `true` unless the example documents a rejection. A `false` check (or a revert)
blocks the associated Taskmarket transition, so policy hooks should be narrow and thoroughly
tested: an over-broad policy can prevent normal settlement. Do not add external calls or mutable
administration to check hooks without considering liveness and reentrancy.

`on*` callbacks are best effort at the Diamond level. `CompletionReceiptHook` uses only a local
append/overwrite record and never reserves funds. In particular, `onCancel` and `onExpire` always
record a terminal receipt and cannot leave hook-held funds or reservations stranded. Hooks that do
reserve assets must explicitly release them on both paths, while tolerating an `on*` callback being
swallowed by the Diamond.

### Allowlisted worker supported modes

`AllowlistedWorkerHook.checkFund` accepts only Bounty and Claim modes:

- Bounty work enters through `submitWork`, which invokes `checkSubmit`.
- Claim workers enter through `claimTask`, which invokes `checkClaim`; their work also enters
  through `submitWork`, which invokes `checkSubmit`.

Pitch, Benchmark, and Auction tasks are rejected during creation. Their `submitPitch`,
`submitProof`, and `submitBid` entry points do not invoke a worker-policy callback. Auction winner
selection is hook-gated later, but allowing unfiltered bids would let an unallowlisted lower bidder
become the recorded minimum and make winner selection revert. `TaskContext` does not expose the
auction subtype, so the hook conservatively rejects clock-price auctions as well.

## Conformance suite

`test/helpers/TMPHookConformance.t.sol` is an abstract Foundry test base for hooks built on
`BaseTMPHook`. Supply `hookUnderTest`, `taskmarketDiamond`, and a documented happy-path worker
address. It verifies ERC-165, authorized check and after-callback paths, and caller restrictions
across all ten lifecycle callbacks. Its fuzz properties exercise arbitrary unauthorized callers
and terminal callback liveness; the reference suites add policy-specific fuzzing for tag position
and worker identity. Add hook-specific invariants alongside them, as in `ReferenceHooks.t.sol`.
