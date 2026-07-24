# ERC-8195 Revision 012 — Surface Swallowed `giveFeedback` Reverts

## Motivation

Every call site that reports reputation feedback to the configured ERC-8004 registry wraps the
external `giveFeedback()` call in a bare `catch { }`, deliberately non-blocking so a broken or
misconfigured reputation registry can never hold up real task settlement. Before this revision
that catch block was silent, making a genuine registry failure indistinguishable on-chain from
"no requester agentId was set" (the normal, expected no-op case). This is exactly what let a real
mainnet misconfiguration — `reputationRegistry` pointed at the ERC-8004 Identity Registry instead
of the Reputation Registry — run undetected for the diamond's entire mainnet lifetime, since every
`giveFeedback` call reverted and nothing ever surfaced it.

---

## Problem 1 — Silent `catch { }` at all four `giveFeedback` call sites

`AcceptanceFacet.acceptSubmission`, `AcceptanceFacet.acceptSubmissions`, `CoreFacet.cancelTask`,
and `CoreFacet.refundExpired` each call `IReputationRegistry(s.reputationRegistry).giveFeedback(...)`
inside a try/catch whose catch block does nothing:

```solidity
try IReputationRegistry(s.reputationRegistry)
    .giveFeedback(
        requesterAgentId, 100, 0, "tmp.task.requester", _modeName(mode), "", "", bytes32(0)
    ) { }
    catch { }
```

A revert inside `giveFeedback` (wrong registry address, registry paused, registry logic reverting
for any reason) is swallowed with zero on-chain trace. The settlement itself still succeeds — by
design — but there is no way for an off-chain observer to distinguish "feedback genuinely was not
applicable" from "feedback silently failed."

---

## Changes

### 1. `ITMPReputation` — new `ReputationFeedbackFailed` event

```solidity
// Before (rev010) — no failure-visibility event existed for giveFeedback

// After (rev012)
/// @notice Emitted when a giveFeedback() call to the reputation registry reverts.
///         Deliberately non-blocking (see the try/catch call sites) so a broken or
///         misconfigured registry can never hold up real task settlement -- but a
///         silent catch with no event is indistinguishable from "no requester agentId
///         was set", so every failure is surfaced here instead.
event ReputationFeedbackFailed(bytes32 indexed taskId, uint256 indexed agentId);
```

### 2. `AcceptanceFacet.acceptSubmission` / `acceptSubmissions` and `CoreFacet.cancelTask` /
   `refundExpired` — emit on catch

```solidity
// Before (rev010)
try IReputationRegistry(s.reputationRegistry)
    .giveFeedback(
        requesterAgentId, 100, 0, "tmp.task.requester", _modeName(mode), "", "", bytes32(0)
    ) { }
    catch { }

// After (rev012)
try IReputationRegistry(s.reputationRegistry)
    .giveFeedback(
        requesterAgentId, 100, 0, "tmp.task.requester", _modeName(mode), "", "", bytes32(0)
    ) { }
catch {
    emit ITMPReputation.ReputationFeedbackFailed(taskId, requesterAgentId);
}
```

Applied identically at all four call sites (the two `AcceptanceFacet` positive-feedback sites and
the two `CoreFacet` negative-feedback sites on cancel/refund). Mirrors the existing
`HookCallFailed` pattern already used by `LibTaskMarket._dispatchAfterHooks` for hook failures.

---

## Rationale

**Why keep the catch non-blocking rather than letting a registry failure revert the whole call?**

Reputation feedback is an auxiliary side effect of settlement, not a precondition for it. A
requester's escrow release, a worker's payment, or a refund must not be held hostage by a
third-party registry the diamond owner does not control the uptime of. Reverting the outer call
on a `giveFeedback` failure would turn an availability problem in an external dependency into a
fund-safety problem in this protocol.

**Why an event instead of, say, a revert-reason-preserving storage log?**

An event is the idiomatic, cheap, off-chain-indexable way to surface "this happened but we chose
not to block on it" — it costs far less gas than persistent storage, and every consumer of this
protocol (the indexer, monitoring tooling) already watches events, not storage diffs. Mirrors the
existing `HookCallFailed` precedent exactly, so there is no new pattern for consumers to learn.

**Why not decode and re-emit the actual revert reason from `giveFeedback`?**

The registry is an external, implementation-defined contract (`IReputationRegistry`); its revert
reasons are not part of this protocol's interface and cannot be relied upon to have a stable
shape. `taskId` + `agentId` is enough for an operator to know *that* and *for which task*
feedback failed and go investigate the registry directly — decoding and forwarding an arbitrary
external revert reason on-chain would add complexity without a corresponding guarantee.

---

## API Changes

- New event: `ITMPReputation.ReputationFeedbackFailed(bytes32 indexed taskId, uint256 indexed agentId)`.
- No change to any existing function signature or return value. Settlement/fund-recovery behavior
  is unchanged; this revision only adds visibility into an existing silent failure mode.
- Off-chain indexers/monitors that want visibility into reputation-registry failures should
  subscribe to this new event; no other client-visible behavior changed.

## Affected Files

| File | Change |
|------|--------|
| `src/interfaces/ITMPReputation.sol` | Add `event ReputationFeedbackFailed(bytes32 indexed taskId, uint256 indexed agentId)` |
| `src/facets/AcceptanceFacet.sol` | Emit `ReputationFeedbackFailed` from the `giveFeedback` catch block in `acceptSubmission` and `acceptSubmissions` |
| `src/facets/CoreFacet.sol` | Emit `ReputationFeedbackFailed` from the `giveFeedback` catch block in `cancelTask` and `refundExpired` |
| `test/TaskMarket.t.sol` | Add coverage for all four call sites using a reverting mock registry |
| `test/mocks/MockRevertingReputationRegistry.sol` | New file — mock registry whose `giveFeedback` always reverts, for testing the catch path |
| `script/upgrades/Rev012Upgrade.s.sol` | New upgrade-step script — pure `Replace` on `CoreFacet` + `AcceptanceFacet` (selector set unchanged) |
