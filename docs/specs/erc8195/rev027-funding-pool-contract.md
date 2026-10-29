# Rev027 -- The funding pool as a separate upgradeable contract

## Status

Draft; not implemented and not deployed on any chain. This replaces the in-Diamond funding pool
described in `rev027-taskmarket-projects.md` before the rev027 cut: the pool facet and its storage
are removed from the Diamond and the pool becomes its own contract that the Diamond calls. Share
pricing, the opening budget, the 365-day cap and the creator-chosen task grace are unchanged from
that document.

## Motivation

The pool holds backers' money. Inside the Diamond it shares one token balance and one blast radius
with every task's escrow, its fields stay in the append-only `AppStorage` for the life of the
Diamond, and its refund path takes bytes from `SettlementFacet`, which has about 372 of 24,576 bytes
free. Rev027 is not cut anywhere, so moving the pool costs a rebuild and a review but no migration.

## Problem 1 -- backers' money sits beside all task escrow

A bug in any facet can reach the pool's balance. The pool has no accounting of its own to catch it.

## Problem 2 -- the pool's storage is permanent

Fields released in `AppStorage` cannot be removed or reused, even after the pool is retired.

## Problem 3 -- no way to fix the pool without a Diamond cut

A fix to the pool's share logic changes a facet that serves every other function.

## Changes

### The pool contract

One contract for all projects, deployed behind a UUPS proxy. It keeps, per pool id:
`token`, `module`, `closesAt`, `closed`, `available`, `outstanding`, `funded`, `claimed`, `totalShares`
and the share epoch; per backer: `shares` and `claimed`. Pool ids are
`keccak256(abi.encode(module, key))`; a project's pool id is `projectPoolId`, unchanged.

The pool also keeps `totalLiabilities`, the sum of `available` over all its pools, and ends every
state-changing call with `token.balanceOf(pool) >= totalLiabilities`.

### Interface

Backers and other contracts, callable by anyone:

- `fund(poolId, amount, onBehalfOf)`: pulls `amount` from the caller with `transferFrom`, credits
  `onBehalfOf` (the caller if zero) with shares at the pool's current value. Reverts for a backer that
  is the Diamond or the pool. Stopped by the pool's pause.
- `claim(poolId, backer) returns (amount)`: pays `backer` its share of a settled pool's pot. The money
  always goes to `backer`. Stopped by the pool's pause.
- Views: `getPool`, `sharesOf`, `claimable`.

Manager only (the Diamond):

- `open(poolId, token, module, closesAt)`, `credit(poolId, funder, backer, amount)` for the opening
  budget and for funding relayed through the Diamond, `spend(poolId, amount)`, `refund(poolId, amount)`,
  `finish(poolId, amount)` and `close(poolId)`.
- `spend` transfers `amount` of tokens from the pool to the Diamond. `refund` is called after the
  Diamond has transferred `amount` to the pool, and books it. `finish` takes only the pool-funded part
  of a task's draw from `outstanding` (the Claim worker's stake is not pool money).
- `spend` and `refund` are never paused and revert only for an unknown pool, a caller that is not the
  manager, or `spend` above `available`.

### Ownership, pause and upgrade

- The pool's owner is whoever owns the Diamond at that moment, read from the Diamond on each owner-only
  call. There is no separate owner to keep in sync.
- The owner can pause and unpause. Pause stops `fund` and `claim`; it never stops `spend`, `refund`,
  `finish`, `close` or `credit` called by the manager, so settlement cannot be blocked.
- The owner can upgrade the implementation (UUPS, owner-only upgrade function). The implementation
  disables its initializers in its constructor, keeps its state in namespaced storage, and a test
  upgrades it and checks the upgrade function and the stored state survive.
- The manager is the Diamond, set at initialisation and not changeable.

### Token

The Diamond's payment token only, one per chain. No fee-on-transfer or rebasing tokens. `open` reverts
for any other token.

### The Diamond side

- The Diamond stores the pool address once, at initialisation. There is no setter.
- `FundingPoolFacet`, `LibFundingPool`, `AppStorage.fundingPools` and `AppStorage.poolBackings` are
  removed. `ProjectFacet` and `LibProject` call the pool.
- A thin `fund(poolId, amount, onBehalfOf)` entry: when called by the trusted forwarder it checks the
  reported payment, transfers it to the pool and calls the pool's `credit`. A thin `claim(poolId,
  backer)` entry forwards to the pool's `claim`, so the backend keeps one relay target and one gas
  accounting path. Neither entry holds tokens after the call.
- `createProject`: the budget arrives through the forwarder into the Diamond, which transfers it to the
  pool and calls `open` and `credit` for the owner.
- `payRequester` for a project task transfers the amount to the pool and calls `refund`; for any other
  task it transfers to the requester as before. `LibEscrow` sees the transfer as an ordinary payout, so
  its balance-delta check needs no special case.
- Draws: `createProjectTask` and `drawTopUp` call `spend`, and the Diamond books the received tokens as
  the task's escrow in the same transaction. The Diamond emits `ProjectPoolDrawn(projectId, taskId,
  amount)`, so the indexer needs no receipt read.
- The Diamond's `taskPoolDraws` is the source of truth for what each task holds of the pool's money. The
  pool trusts its manager; an invariant test and a monitor check that the pool's `outstanding` equals the
  sum of `taskPoolDraws` over a project's tasks.

### Events

The pool emits `PoolOpened`, `PoolFunded`, `PoolSpent`, `PoolRefunded`, `PoolClosed` and `PoolClaimed`
with their current signatures. The Diamond keeps the project events and adds `ProjectPoolDrawn`.

## Rationale

- One pool for all projects keeps one address to index and one implementation to upgrade; a pool per
  project would run the same code in every clone and would not contain a logic bug.
- Passthrough entries on the Diamond keep the relayed write path unchanged: the forwarder pays into and
  calls only the Diamond.
- `claim` stays pausable so there is one pause behaviour for everything that moves backers' money out or
  in; `spend` and `refund` are never paused because a settlement must not depend on pool state.
- The Diamond is the source of truth for draws because it already owns task ids and the grant caps; the
  pool needs no knowledge of tasks.
- Reading the owner from the Diamond means one authority governs both the cut and the pool.

## Upgrade

Rev027 is not cut anywhere, so there is no migration. Deploy the pool implementation and proxy with the
Diamond as manager, cut the facets without `FundingPoolFacet`, then initialise the Diamond with the pool
address. Later pool upgrades go through the proxy and need no Diamond cut.

## Trade-offs

- A second contract and a trust boundary to maintain: custody crossings on `spend` and `refund`, the
  manager check, the pass-through entries and reentrancy.
- The upgrade authority can change the code that holds backers' money. It is the authority that can
  already cut the Diamond, so no new key exists.
- Pause stops `claim`, so while paused backers cannot take their share out.
- USDC can blacklist an address. If the pool address were blacklisted, claims and refunds into it would
  fail. The Diamond has the same exposure for its escrow today; the pool concentrates it. This is
  accepted, and the monitor checks the pool's token balance.
- `SettlementFacet` gains an estimated 200 to 600 bytes, not measured.

## Tests

- The existing funding-pool tests, ported to the pool's interface: shares at current value, the opening
  budget, the zero-value case, claims and rounding, the 365-day cap and the share epoch.
- Invariants: `balanceOf(pool) >= totalLiabilities` after every call; total claims never exceed the pot;
  the pool's `outstanding` equals the sum of the Diamond's task draws.
- Fuzz of the `spend`, `refund`, `finish`, `fund` and `claim` sequence across several projects.
- Manager checks: every manager-only function reverts for any other caller; `fund` reverts for the
  Diamond and the pool as backer.
- Pause: `fund` and `claim` revert while paused; `spend`, `refund`, `finish` and `close` still work.
- Upgrade: the implementation upgrades, the stored state and the upgrade function survive, and the
  initializer cannot be called again.
- Boundary: a refund from every `SettlementFacet` payout path of a project task reaches the pool; a
  project task top-up draws from it; relayed and direct funding both credit the backer.

## Affected Files

- `packages/contracts/evm/src/` pool contract and interface (new), `ProjectFacet`, `LibProject`,
  `SettlementFacet` payout sites, `LibEscrow`, `LibAppStorage`; `FundingPoolFacet` and `LibFundingPool`
  removed.
- `packages/contracts/evm/script/` deploy and rev027 upgrade scripts, `FacetSelectors`.
- `packages/contracts/evm/abi/generated/` regenerated ABIs.
