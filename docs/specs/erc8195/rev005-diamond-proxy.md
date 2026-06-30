# ERC-8195 Revision 005 — Diamond Proxy Architecture

## Motivation

`TaskMarket.sol` reached 31,208 bytes at runtime, exceeding the EIP-170 limit of 24,576 bytes by
6,632 bytes. Optimizer tuning alone saved fewer than 300 bytes. The contract is pre-mainnet, making
this the correct moment to adopt the Diamond proxy pattern (EIP-2535): the proxy address becomes
permanent from first deploy, and logic is split across multiple facet contracts each well under the
size limit.

---

## Problems

### Problem 1 — EIP-170 size limit breach

`TaskMarket.sol` compiled to a runtime bytecode size of 31,208 bytes, exceeding the EIP-170
deploy limit of 24,576 bytes by 6,632 bytes. The contract could not be deployed as-is on any
EVM-compatible network. Optimizer tuning (increasing `runs`, inlining tweaks, removing dead
branches) recovered fewer than 300 bytes — not nearly enough to close the gap.

### Problem 2 — No upgrade path that preserves the address

The monolithic contract was under active development pre-mainnet. A non-upgradeable rewrite
would require migrating all state and re-issuing the contract address to all off-chain consumers
on every significant change. A proxy was required so that the public-facing address remains
stable across future upgrades.

### Problem 3 — Monolithic upgrade surface

A UUPS or Transparent proxy would solve the size limit by splitting proxy from implementation,
but the entire implementation would still be upgraded atomically. Any change to one facet's logic
requires redeploying and re-verifying the full combined implementation. Per-facet granularity was
preferable given the expected rate of change across the different concern areas (core, acceptance,
auction, evaluator, registry).

---

## Architecture

```
Diamond proxy (permanent address)
  fallback() — selector lookup in DiamondStorage, delegatecall to facet

Facets (upgradeable per-facet via diamondCut):
  DiamondCutFacet     — diamondCut(), upgrades
  DiamondLoupeFacet   — facets(), facetFunctionSelectors(), supportsInterface()
  AdminFacet          — pause/unpause, setDefaultFeeBps, setFeeRecipient,
                        setReputationRegistry, addForwarder, removeForwarder,
                        transferOwnership, acceptOwnership, initialize
  CoreFacet           — createTask, claimTask, selectWorker, submitWork, submitPitch,
                        submitProof, cancelTask, updateTask, forfeitAndReopen, refundExpired
  AuctionFacet        — submitBid, selectLowestBidder, acceptAuction
  AcceptanceFacet     — acceptSubmission, acceptSubmissions (ranked payouts)
  EvaluatorFacet      — assignEvaluator, evaluate, appeal, finalizeVerdict,
                        resolveDispute, evaluatorTimeout
  RatingFacet         — rateTask; IReputationRegistry call; all WorkerStats updates
  RegistryFacet       — all view/getter functions
```

All calls enter through `Diamond.fallback()`, which looks up the target facet address from
`DiamondStorage` using the 4-byte selector and delegates via `delegatecall`. All facets execute
in the Diamond's storage context.

## AppStorage

All state is unified in an `AppStorage` struct stored at a deterministic slot:

```solidity
bytes32 constant APPSTORAGE_SLOT = keccak256("taskmarket.appstorage.v1");
```

The struct is defined in `src/libraries/LibAppStorage.sol`. Every facet accesses it via:

```solidity
AppStorage storage s = LibAppStorage.appStorage();
```

### Struct layout

| Offset | Field | Type |
|--------|-------|------|
| 0 | usdcToken | IERC20 |
| 1 | trustedForwarders | mapping(address => bool) |
| 2 | tasks | mapping(bytes32 => ITMPCore.Task) |
| 3 | workerStats | mapping(address => ITMPCore.WorkerStats) |
| 4 | stakeForfeit | mapping(bytes32 => uint256) |
| 5 | taskBids | mapping(bytes32 => ITMPCore.Bid[]) |
| 6 | defaultFeeBps | uint16 |
| 7 | feeRecipient | address |
| 8 | totalFeesCollected | uint256 |
| 9 | reputationRegistry | address |
| 10 | requesterNonce | mapping(address => uint256) |
| 11 | taskPitchHashes | mapping(bytes32 => bytes32[]) |
| 12 | taskProofHashes | mapping(bytes32 => bytes32[]) |
| 13 | taskWorkerRated | mapping(bytes32 => mapping(address => bool)) |
| 14 | taskTags | mapping(bytes32 => bytes32[]) |
| 15 | taskVerdicts | mapping(bytes32 => ITMPCore.Verdict) |
| 16 | phaseDeadline | mapping(bytes32 => uint256) |
| 17 | taskEvaluatorConfigs | mapping(bytes32 => ITMPCore.TaskEvaluatorConfig) |
| 18 | taskAuctionConfigs | mapping(bytes32 => ITMPCore.TaskAuctionConfig) |
| 19 | taskMetadata | mapping(bytes32 => ITMPCore.TaskMetadata) |
| 20 | taskPitchConfigs | mapping(bytes32 => ITMPCore.TaskPitchConfig) |
| 21 | reentrancyStatus | uint256 |
| 22 | paused | bool |
| 23 | taskHasSubmissions | mapping(bytes32 => bool) | Added in rev006: set on first `submitWork` for Bounty/Benchmark; blocks cancel/refund once submissions exist |

### Adding new state

Append new fields to the END of the struct. Never insert between existing entries.
No `__gap` is needed: the struct lives at a fixed `keccak256` slot, so appending is always safe.
New fields zero-initialise by default; use lazy-init in the facet function body if a non-zero
default is needed.

## Upgrade mechanism

Upgrades use `IDiamondCut.diamondCut(FacetCut[], address init, bytes calldata data)`:

- `Add`: register new selectors pointing to a new facet address
- `Replace`: reroute existing selectors to a new facet implementation
- `Remove`: unregister selectors (calls to them revert with "Diamond: function not found")

Only the contract owner may call `diamondCut`. Ownership lives in `LibDiamond`'s own storage slot
alongside the facet registry. Two-step ownership transfer (`transferOwnership` + `acceptOwnership`)
is implemented directly in `LibDiamond`.

This replaces the prior `upgradeToAndCall` / UUPS pattern entirely. There is no
`_authorizeUpgrade` hook and no reinitializer pattern. Post-upgrade initialisation, if needed,
is passed as the `init`/`data` arguments to `diamondCut`.

## Ownership

Ownership is stored in `LibDiamond.DiamondStorage` (separate from `AppStorage`) and managed by:

- `AdminFacet.transferOwnership(address)` — sets `pendingOwner`, emits `OwnershipTransferStarted`
- `AdminFacet.acceptOwnership()` — requires `msg.sender == pendingOwner`, promotes to `contractOwner`

`LibDiamond.enforceIsContractOwner()` is called by both `DiamondCutFacet` and `AdminFacet`.

## ERC-165

`DiamondLoupeFacet.supportsInterface` advertises the following interface IDs:

| Interface | ID |
|-----------|-----|
| IERC165 | 0x01ffc9a7 |
| IDiamondCut | computed from function signatures |
| IDiamondLoupe | computed from function signatures |
| ITMPCore | computed from function signatures |
| ITMPEvaluator | computed from function signatures |
| ITMPRegistry | computed from function signatures |
| ITMPModes | computed from function signatures |
| ITMPFees | computed from function signatures |
| ITMPReputation | computed from function signatures |

## Deployment

```bash
make deploy testnet   # deploys Diamond + all 9 facets via DiamondDeploy.s.sol
make deploy mainnet   # same, targeting Base mainnet
make upgrade testnet  # upgrades one or more facets via DiamondUpgrade.s.sol
```

After deploy, submit the Diamond proxy address on Basescan via "Is this a proxy?" —
Basescan supports EIP-2535 detection via `IDiamondLoupe`.

## Shared business logic

Helpers used by more than one facet live in `src/libraries/LibTaskMarket.sol`:

- `_requireForwarder(s)` / `_effectiveSender(s)` — PGTR forwarder check and sender resolution
- `_requireNotPaused(s)` — pause guard
- `_nonReentrantBefore(s)` / `_nonReentrantAfter(s)` — reentrancy guard using AppStorage slot
- `_buildContext(taskId, s)` — TaskContext snapshot for hook callbacks
- `_checkFundHook(taskId, hook, hookData, s)` — calls `ITMPHook.checkFund`, reverts on rejection
- `_afterHook(hook, data)` — fire-and-forget after-hook dispatch, swallows failures

Helpers used by only one facet remain `private` within that facet.

## Rationale

**Why not UUPS proxy?**

UUPS (EIP-1822) places the upgrade function in the implementation contract, keeping the proxy
thin. It solves the size limit by splitting proxy and implementation into separate deploys, and
it preserves the proxy address across upgrades. However, the implementation is still a single
monolithic contract: one `upgradeToAndCall` call replaces everything. Per-facet upgrades are not
possible, meaning any change to, say, `AuctionFacet` requires redeploying and re-verifying the
entire combined contract. The Diamond pattern was chosen specifically to enable targeted,
per-facet upgrades.

**Why Diamond over Transparent proxy?**

A Transparent proxy (EIP-1967) shares the monolithic-upgrade drawback of UUPS. Additionally, it
introduces an admin address that must be excluded from all proxied calls (the "admin slot
conflict"), which complicates ownership management. The Diamond pattern has no such conflict: the
owner calls `diamondCut` directly through the same fallback as any other function, gated only by
`LibDiamond.enforceIsContractOwner`. The Diamond also has no practical size limit on the
aggregate logic surface because each facet is independently sized and deployed.

---

## Changes from UUPS (rev004)

| Before | After |
|--------|-------|
| `TaskMarket.sol` monolithic contract | 9 facets + Diamond proxy |
| `ERC1967Proxy` + `UUPSUpgradeable` | `Diamond.sol` proxy |
| `upgradeToAndCall` | `diamondCut` |
| `_authorizeUpgrade` hook | removed |
| `Ownable2StepUpgradeable` | ownership in `LibDiamond` |
| `__gap[N]` slot budget | append-only `AppStorage` struct |
| `Deploy.s.sol` / `DeployTestnet.s.sol` | `DiamondDeploy.s.sol` |
| `Upgrade.s.sol` | `DiamondUpgrade.s.sol` |

---

## Affected Files

| File | Change |
|------|--------|
| `packages/contracts/src/Diamond.sol` | New Diamond proxy contract; `fallback()` delegates by selector |
| `packages/contracts/src/libraries/LibDiamond.sol` | Diamond storage, selector registry, `enforceIsContractOwner`, two-step ownership transfer |
| `packages/contracts/src/libraries/LibAppStorage.sol` | New: defines `AppStorage` struct at `keccak256("taskmarket.appstorage.v1")` slot; replaces per-contract `storage` declarations |
| `packages/contracts/src/libraries/LibTaskMarket.sol` | New: shared helpers extracted from monolith (`_requireForwarder`, `_nonReentrant*`, `_buildContext`, hook dispatch) |
| `packages/contracts/src/facets/DiamondCutFacet.sol` | New: implements `diamondCut`; gated by `enforceIsContractOwner` |
| `packages/contracts/src/facets/DiamondLoupeFacet.sol` | New: `facets()`, `facetFunctionSelectors()`, `supportsInterface()` |
| `packages/contracts/src/facets/AdminFacet.sol` | New: pause, fee config, forwarder management, `transferOwnership`, `acceptOwnership`, `initialize` |
| `packages/contracts/src/facets/CoreFacet.sol` | New: task lifecycle — create, claim, select, submit, cancel, update, forfeit, refund |
| `packages/contracts/src/facets/AuctionFacet.sol` | New: `submitBid`, `selectLowestBidder`, `acceptAuction` |
| `packages/contracts/src/facets/AcceptanceFacet.sol` | New: `acceptSubmission`, `acceptSubmissions` (ranked payouts) |
| `packages/contracts/src/facets/EvaluatorFacet.sol` | New: assign, evaluate, appeal, finalizeVerdict, resolveDispute, evaluatorTimeout |
| `packages/contracts/src/facets/RatingFacet.sol` | New: `rateTask`, `IReputationRegistry` call, `WorkerStats` updates |
| `packages/contracts/src/facets/RegistryFacet.sol` | New: all view/getter functions |
| `packages/contracts/src/TaskMarket.sol` | Deleted (replaced by Diamond + facets) |
| `packages/contracts/script/DiamondDeploy.s.sol` | New deploy script; replaces `Deploy.s.sol` / `DeployTestnet.s.sol` |
| `packages/contracts/script/DiamondUpgrade.s.sol` | New upgrade script; replaces `Upgrade.s.sol` |
| `packages/contracts/abi/TaskMarket.json` | Rebuilt: 207 entries merged from all 9 facets (75 functions, 33 events, 99 errors) |
| `apps/backend/src/services/contract.ts` | Updated to target Diamond ABI and proxy address |
| `test/TaskMarket.t.sol` | Updated for Diamond deploy fixture; all 234 core tests updated |
| `test/DiamondTest.t.sol` | New: 26 Diamond-specific tests (cut, loupe, ownership) |
