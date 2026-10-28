# Sponsored Tasks: shared EVM and Solana event and error vocabulary

Status: Draft for the Solana program's `settle`, `claim`, `claim_fee` and `bind_payout`
instructions. Covers the EVM contracts under `evm/src/hooks/sponsored-task/` and the Solana
program under `solana/programs/sponsored-tasks/src/` as they stand at this revision.

The EVM vault and the Solana program implement one protocol: a sponsor funds a single-token vault,
a manager reserves an amount for a task, the task's awards are installed as a Merkle root and
workers claim with a proof. This spec fixes the shared names so an indexer, the backend and
clients can read one normalized row per event regardless of chain, and so a Solana award list
hashes the same way as an EVM one.

Sections:

1. Event map
2. Error map
3. Normalized projection rows
4. Award leaf and test vector
5. Names the Solana settle and claim instructions emit

## Conventions

- **Chain.** Every row carries `chain` as a CAIP-2 string and `chainId` as a number. EVM:
  `eip155:<chainId>`. Solana uses the token-list cluster ids as its numeric id: `101`
  mainnet-beta (`solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp`), `102` testnet
  (`solana:4uhcVJyU9pJkvQyS88uRDiswHXSCkY3z`), `103` devnet
  (`solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1`). CAIP-2 is canonical; the number exists for
  numeric settings and code paths, and 101 to 103 are never used for an EVM chain.
- **bytes32 ids** (`vaultId`, `allocationId`, `taskId`, roots, leaves) are lowercase `0x`-prefixed
  64-hex-digit strings on both chains. A Solana pubkey used as an id is its 32 raw bytes in this
  form, so the projected id is byte-for-byte the value hashed into the award leaf.
- **Addresses.** EVM addresses are lowercase `0x` 40-hex strings. Solana pubkeys that are
  accounts rather than ids (sponsor, mint, payout destination, program) are base58 strings.
- **Amounts** (`uint256` on EVM, `u64` on Solana) are decimal strings in the token's base units,
  never numbers. Epochs, nonces and leaf indexes are decimal strings too; `leafIndex` may be read
  as a number because it is bounded by the award count.
- **Event position.** `txHash` is the EVM transaction hash or the Solana transaction signature
  (base58). `blockNumber` is the EVM block or the Solana slot, as a decimal string. `eventIndex`
  is the EVM log index, or on Solana the zero-based position of the `emit_cpi!` self-CPI among
  the transaction's inner instructions. `(chain, txHash, eventIndex)` is the row's unique key.
- **Contract.** `contract` is the EVM contract that emitted the log, or the Solana program id.

## 1. Event map

"EVM-only" and "Solana-only" give the reason. Task chain events remain on the task chain for a
Solana-funded task too, because the task, its verdict and its awards live there (Base or Tempo); the Solana
program only holds and pays the tokens.

### SponsoredTasksVault (EVM) and the Solana program

| EVM event | Solana event | Projection kind | Notes |
| --- | --- | --- | --- |
| `VaultInitialized(vaultId, projectToken, vaultOwner, controller, feePolicy, epoch)` | `VaultCreated { vault, sponsor, mint, token_program, vault_id, epoch }` | `vault_created` | On EVM, factory `VaultCreated` and registry `VaultRegistered` carry the same vault; the indexer merges them into one row. Solana has no controller or fee policy account: the settler set and fee terms are global in `Config`. |
| `VaultFunded(funder, amount)` | `VaultFunded { vault, funder, amount }` | `vault_funded` | |
| `AvailableWithdrawn(owner, recipient, amount)` | none | `available_withdrawn` | EVM-only. The Solana program has no partial withdrawal; a sponsor recovers funds with `emergency_exit`. |
| `ManagerConfigured(manager, cap, reserved, spent, active)` | `ManagerConfigured { vault, manager, cap, reserved, spent, active }` | `manager_configured` | Solana `manager` is `ManagerKey { chain_id, evm_address }`; on EVM the manager chain is the vault's chain. |
| `TaskReserved(allocationId, taskId, manager, epoch, grossAmount, feeBps, feeRecipient, termsHash)` | `TaskReserved { vault, reservation, task_chain_id, task_id, manager, epoch, nonce, deadline, amount }` | `task_reserved` | EVM fixes fee terms and a terms hash per allocation; Solana fee terms are global and read at settle, and Solana adds the settler `nonce` and `deadline`. |
| `TaskBound(allocationId, taskId)` | none | `task_bound` | EVM-only. On EVM a cross-chain allocation is reserved before its task id exists. A Solana reservation is created for a known `(task_chain_id, task_id)`, which are in its seeds. |
| `TaskReleased(allocationId, taskId, manager, amount)` | `TaskReleased { vault, reservation, task_chain_id, task_id, manager, amount }` | `task_released` | |
| `SettlementInstalled(allocationId, taskId, rewardsRoot, leafCount, distributedGross, sponsoredTaskTotal, feeTotal, releasedAmount)` | `SettlementInstalled` (section 5) | `settlement_installed` | Emitted by `settle`; see [`settlement.md`](settlement.md). |
| none | `SettlementRevoked { vault, reservation, root, settled_total }` | `settlement_revoked` | Solana-only. A Solana root rests on settler signatures alone, so the admin can reset an unclaimed root, without pausing the program. An EVM root comes from same-chain award events and cannot be forged by a key. |
| `SponsoredTaskClaimed(allocationId, taskId, index, worker, destination, amount)` | `SponsoredTaskClaimed` (section 5) | `reward_claimed` | Emitted by `claim`; see [`settlement.md`](settlement.md). |
| `FeeClaimed(allocationId, taskId, feeRecipient, destination, amount)` | `FeeClaimed` (section 5) | `fee_claimed` | Emitted by `claim_fee`; see [`settlement.md`](settlement.md). |
| `VaultEmergencyExited(vaultId, owner, recipient, closedEpoch, newEpoch, amountWithdrawn, affectedReserved, affectedClaimable)` | `VaultEmergencyExited { vault, sponsor, recipient, closed_epoch, new_epoch, amount_withdrawn, affected_reserved, affected_claimable }` | `vault_emergency_exited` | Same fields, same semantics: the whole balance leaves and open reservations of `closed_epoch` become defaulted. |
| none | `VaultCapSet { vault, cap }` | none | Solana-only and scheduled for removal: the vault-level cap is dropped so caps match EVM (manager caps only). Indexers ignore it. |
| none | `ConfigInitialized`, `AdminChanged`, `SettlersChanged`, `PauseSet`, `ClaimDelaySet` | `program_config` | Solana-only. One global `Config` account holds admin, settler set, threshold, pause and fee terms. On EVM these live in separate contracts (Ownable ownership, the fee policy, the diamond's pause) whose events are outside this vocabulary. |
| none | `PayoutBound` (section 5) | `payout_bound` | Solana-only. A Solana claim pays the worker's bound Solana address; an EVM claim pays the EVM worker or a signed `claimTo` destination. |

### SponsoredTaskHook (task lifecycle)

The hook runs on the chain where the task lives. Every hook event has no Solana counterpart
because a Solana vault funds tasks; the Solana settler reads these Base events to build the
award list it signs.

| EVM event | Projection kind | Notes |
| --- | --- | --- |
| `SponsoredTaskFunded(taskId, vaultId, allocationId, vault, manager, route, epoch, grossAmount, feeBps, feeRecipient, taskTermsHash)` | `task_funded` | Links the task to its vault and allocation. |
| `CompletionCommitted(taskId, allocationId, verdictType, awardsDigest, awardCount, nativePayoutPool)` | `completion_committed` | |
| `TerminalReleaseCommitted(taskId, allocationId)` | `terminal_release_committed` | |
| `ForfeitReservationRetained(taskId, allocationId, worker)` | `forfeit_retained` | |
| `SponsoredTaskEntitlement(taskId, leafIndex, worker, awardIndex, grossAmount, feeAmount, netAmount, leaf)` | `entitlement` | One per award leaf. For a Solana vault the settler takes `(leafIndex, worker, netAmount)` and rebuilds the leaf with the Solana ids (section 4); the `leaf` field here holds the EVM-packed hash and is not compared. |
| `SettlementPrepared(taskId, allocationId, rewardsRoot, leafCount, sponsoredTaskTotal, feeTotal, distributedGross, releasedGross, route)` | `settlement_prepared` | |
| `ReservationReleased(taskId, allocationId, route)` | `reservation_released` | |
| `SponsoredTaskDefaultedByOwner(taskId, vaultId, allocationId)` | `task_defaulted_by_owner` | On Solana the same row is derived (section 5). |
| `SponsoredTaskUnsettleableAwardCount(taskId, allocationId, awardCount)` | `unsettleable_award_count` | |

### Factory, registry and fee policy (EVM-only)

`SponsoredTaskFactory.VaultCreated`, `SponsoredTaskRegistry.FactoryAuthorizationUpdated` and
`VaultRegistered`, `SponsoredTaskFeePolicy.FeeTermsUpdated`, and the factory's
`CreationFeeUpdated` and `CreationFeePaid` are EVM-only. Solana vaults are created directly by
`create_vault` at a PDA, with no factory or registry. `VaultCreated` and `VaultRegistered`
feed the `vault_created` row; the rest project to EVM-specific rows outside this vocabulary.

## 2. Error map

A Solana error is the Anchor `SponsoredTasksError` variant. "Anchor" means the condition is
enforced by an account constraint or seed derivation and surfaces as a framework error.

### SponsoredTasksVault

| EVM error | Solana counterpart | Notes |
| --- | --- | --- |
| `AlreadyInitialized` | Anchor (`init` on an existing PDA) | |
| `ZeroAddress` | none | EVM-only: Solana accounts are typed and cannot be the zero address. |
| `InvalidContract(account)` | none | EVM-only: checks that a configured address has code. |
| `InvalidVaultId` | Anchor (vault seeds) | The PDA derivation binds `vault_id`. |
| `VaultNotActive` | `VaultNotActive` | |
| `OnlyController(caller)` | `SettlerThresholdNotMet` | Reserve, release and settle are authorized by settler signatures instead of a controller contract. |
| `InvalidManagerCap(minimum, provided)` | `InvalidManagerCap` | |
| `ManagerNotActive(manager)` | `ManagerNotActive` | |
| `ManagerAllowanceExceeded(manager, requested, remaining)` | `ManagerAllowanceExceeded` | |
| `AllocationIdRequired` | none | EVM-only: the Solana reservation id is a PDA, never caller-supplied. |
| `TaskIdRequired` | none | EVM-only: `task_id` is a required seed. |
| `TermsHashRequired` | none | EVM-only: Solana reservations carry no terms hash; the settler message binds the task. |
| `GrossAmountRequired` | `ZeroAmount` | |
| `AllocationAlreadyExists(allocationId)` | Anchor (`init` on an existing reservation PDA) | |
| `AllocationNotFound(allocationId)` | Anchor (account not initialized) | |
| `AllocationWrongStatus(allocationId, status)` | `ReservationWrongState` | |
| `AllocationEpochMismatch(expected, actual)` | `EpochMismatch` | |
| `TaskBindingConflict(allocationId, expected, provided)` | none | EVM-only, with `TaskBound`. |
| `FeeTermsMismatch(...)` | none | EVM-only: fee terms are not fixed per reservation on Solana. |
| `InsufficientAvailable(requested, available)` | `InsufficientAvailable` | |
| `Insolvent(balance, liabilities)` | `Overflow` | Solana totals use checked arithmetic and the token account balance; a shortfall surfaces as an overflow or a failed transfer. |
| `TokenTransferAmountMismatch`, `TokenSenderAmountMismatch`, `TokenRecipientAmountMismatch` | `TransferAmountMismatch` | |
| `InvalidSettlementTotals` | `InvalidSettlementTotals` (section 5) | |
| `SettlementExceedsAllocation(distributed, gross)` | `SettlementExceedsReservation` (section 5) | |
| `SettlementFeeTooHigh(provided, maximum)` | `InvalidFeeBps` | |
| `SettlementCommitmentRequired`, `UnexpectedSettlementCommitment` | none | EVM-only: Base settles from the hook's committed verdict; Solana settles from a settler-signed root. |
| `ConflictingSettlement(allocationId)` | `ReservationWrongState` | A second settle finds the reservation already `Settled`. |
| `ClaimExpired(deadline)` | none | EVM-only, with the `claimTo` signature path; a Solana claim pays the bound address without a per-claim signature. |
| `InvalidClaimNonce`, `InvalidClaimSignature` | `InvalidPayoutSignature`, `StalePayoutNonce` (section 5) | The Solana signature is checked once at `bind_payout`, not per claim. |
| `InvalidClaimProof` | `InvalidClaimProof` (section 5) | |
| `ClaimAlreadyPaid(allocationId, index)` | `ClaimAlreadyPaid` (section 5) | The claim receipt PDA is the guard; the program checks it first so the error is named. |
| `ClaimIndexOutOfBounds(index, leafCount)` | `ClaimIndexOutOfBounds` (section 5) | |
| `NothingToClaim` | `NothingToClaim` (section 5) | |
| `NotFeeRecipient(caller, expected)` | `NotFeeRecipient` (section 5) | |
| `OwnershipRenunciationDisabled` | none | EVM-only: Solana admin rotation always names a new admin. |

### SponsoredTaskHook and libraries (Base-only)

`ZeroAddress`, `InvalidContract`, `InvalidHookDataVersion`, `InvalidRoute`, `InvalidHookContext`,
`InvalidFundingRequest`, `WrongPaymentToken`, `AllocationAlreadyExists`, `AllocationNotFound`,
`AllocationBindingConflict`, `AllocationWrongStatus`, `VaultMismatch`, `VaultExited`,
`TaskTermsMismatch`, `TaskNotTerminal`, `VerdictNotIssued`, `VerdictCommitmentMismatch`,
`AwardsRequired` and `SettlementMismatch` (hook), `FeeBpsTooHigh`, `InvalidAwardRecipient`,
`TooManyAwards` and `ZeroPayoutPool` (`SponsoredTaskSettlement`) and `InvalidTaskContext`
(`SponsoredTaskTerms`) are task-chain-only: they guard the task lifecycle and award calculation, which
stay on the task chain for every vault chain.

### Factory, registry and fee policy (EVM-only)

`SponsoredTaskFactory` (`ZeroAddress`, `InvalidContract`, `VaultAlreadyExists`, and from
`SponsoredTaskCreationFee` `FeeTokenRequired`, `FeeRecipientRequired`, `FeeRecipientInvalid`
and `FeeTransferAmountMismatch`),
`SponsoredTaskRegistry` (`ZeroAddress`, `InvalidContract`, `UnauthorizedFactory`,
`VaultAlreadyRegistered`, `VaultIdentityMismatch`, `VaultNotActive`,
`InvalidVaultConfiguration`) and `SponsoredTaskFeePolicy` (`FeeBpsTooHigh`,
`FeeRecipientRequired`) are EVM-only for the same reason as their events. A Solana vault is created by `create_vault`, so
an already-existing vault is the Anchor `init` failure; a duplicate `vault_id` for the same mint
and sponsor is the same PDA.

### Solana errors with no EVM counterpart

| Solana error | Reason |
| --- | --- |
| `NotAdmin` | The global `Config` admin; EVM equivalents are per-contract `Ownable` reverts. |
| `NotSponsor` | Anchor `has_one` on the vault sponsor; EVM uses `OwnableUnauthorizedAccount`. |
| `InvalidSettlers`, `InvalidThreshold`, `SettlerThresholdNotMet` | Settler-set authorization exists only on Solana. |
| `InvalidFeeBps` | Fee terms are set in `Config`; EVM rejects them in the fee policy (`FeeBpsTooHigh`). |
| `Paused`, `NotPaused` | The program-wide pause, which also blocks claims; the EVM vault has no pause. No instruction returns `NotPaused` any more (`revoke_settlement` needs no pause); it keeps its code so later codes do not shift. |
| `UnsupportedMintExtension` | Token-2022 extension checks at `create_vault`. |
| `TooManyManagers` | Account size bound on the vault's manager list. |
| `ManagerChainMismatch` | A Solana manager is keyed by EVM chain; the reservation's `task_chain_id` must match it. |
| `VaultCapExceeded` | Scheduled for removal with `VaultCapSet`. |
| `DeadlineInPast` | The settler-signed reservation message carries a deadline. |
| `SettlementHasClaims` | Guard on `revoke_settlement`. |
| `InvalidClaimDelay` | `set_claim_delay` rejects zero and values above `i64::MAX`; the claim delay exists only on Solana (see [`settlement.md`](settlement.md)). |
| `ClaimDelayNotElapsed` | `claim` and `claim_fee` before `Config.claim_delay_seconds` has passed since `settle`. An EVM root comes from same-chain award events and pays at once. |
| `Overflow` | Checked arithmetic; EVM reverts with a panic. |

## 3. Normalized projection rows

Every row has the envelope fields, then the kind's fields. Field types are chain-neutral strings
as defined in Conventions; `null` marks a field that one chain does not have.

### Envelope

| Field | Type | EVM source | Solana source |
| --- | --- | --- | --- |
| `kind` | string | projection kind (section 1) | same |
| `chain` | CAIP-2 string | `eip155:<chainId>` | `solana:<genesis>` |
| `chainId` | number | EIP-155 id | 101, 102 or 103 |
| `contract` | address or base58 | emitting contract | program id |
| `txHash` | hex or base58 | transaction hash | signature |
| `blockNumber` | decimal string | block | slot |
| `eventIndex` | number | log index | inner-instruction position |
| `vaultId` | bytes32 hex | `vaultId` | vault PDA bytes |
| `vaultAddress` | address or base58 | vault contract | vault PDA base58 |

`vaultId` is the canonical vault key on both chains. On EVM it is the vault's `bytes32` id; on
Solana it is the vault PDA, because `vault_id` (u64) is only unique per `(mint, sponsor)` while
the PDA derived from `["vault", mint, sponsor, vault_id]` is unique program-wide. The u64 is kept
as `vaultIndex` on `vault_created`.

Rows that concern one reservation also carry:

| Field | Type | EVM source | Solana source |
| --- | --- | --- | --- |
| `allocationId` | bytes32 hex | `allocationId` | reservation PDA bytes |
| `taskId` | bytes32 hex | `taskId` | `task_id` |
| `taskChain` | CAIP-2 string | the vault chain, or the reservation chain for a cross-chain allocation | `eip155:<task_chain_id>` |
| `taskChainId` | number | as above | `task_chain_id` |
| `epoch` | decimal string | allocation epoch | reservation epoch |

`allocationId` is canonical for a reservation. A Solana reservation PDA is derived from
`["task", vault, task_chain_id u64 LE, task_id]`, so it is one-to-one with
`(vault, task_chain_id, task_id)`. `taskId` with `taskChainId` identifies the task and
joins to the task's hook rows.

### Kinds

| Kind | Fields after the envelope |
| --- | --- |
| `vault_created` | `owner`, `token`, `tokenProgram` (Solana; `null` on EVM), `vaultIndex` (Solana u64; `null` on EVM), `controller` (EVM; `null` on Solana), `feePolicy` (EVM; `null`), `epoch` |
| `vault_funded` | `funder`, `amount` |
| `available_withdrawn` | `owner`, `recipient`, `amount` |
| `manager_configured` | `managerChainId` (number), `managerAddress` (EVM address), `cap`, `reserved`, `spent`, `active` (boolean) |
| `task_reserved` | reservation fields, `managerChainId`, `managerAddress`, `grossAmount`, `feeBps` (number; `null` on Solana), `feeRecipient` (`null` on Solana), `termsHash` (`null` on Solana), `nonce` (`null` on EVM), `deadline` (unix seconds; `null` on EVM) |
| `task_bound` | reservation fields |
| `task_released` | reservation fields, `managerChainId`, `managerAddress`, `amount` |
| `settlement_installed` | reservation fields, `rewardsRoot`, `leafCount` (number), `distributedGross`, `sponsoredTaskTotal`, `feeTotal`, `releasedAmount` |
| `settlement_revoked` | reservation fields, `rewardsRoot`, `sponsoredTaskTotal` |
| `reward_claimed` | reservation fields, `leafIndex` (number), `worker` (EVM address), `destination` (address or base58), `amount` |
| `fee_claimed` | reservation fields, `feeRecipient`, `destination`, `amount` |
| `vault_emergency_exited` | `owner`, `recipient`, `closedEpoch`, `newEpoch`, `amountWithdrawn`, `affectedReserved`, `affectedClaimable` |
| `task_defaulted_by_owner` | reservation fields |
| `payout_bound` | `agentChainId` (number), `agentAddress` (EVM address), `payout` (base58), `nonce` |
| `program_config` | `admin`, `settlers` (array of base58), `threshold`, `paused`, `feeBps`, `feeRecipient`, `claimDelaySeconds`; each Solana config event fills the fields it carries |

Base hook kinds (`task_funded`, `completion_committed`, `entitlement` and the rest) use the EVM
event's field names in camelCase, with the envelope and reservation fields above.

## 4. Award leaf and test vector

Both chains hash award lists with keccak-256 in the EVM leaf format, as the OpenZeppelin
`StandardMerkleTree` builds it and `SponsoredTasksVault` verifies it:

```text
leaf = keccak256(keccak256(abi.encode(
  bytes32 vaultId,
  uint64  epoch,
  bytes32 allocationId,
  bytes32 taskId,
  uint256 leafIndex,
  address worker,
  uint256 netAmount
)))
node = keccak256(min(a, b) || max(a, b))
```

`abi.encode` pads every field to 32 bytes, big-endian, so the encoded leaf is 224 bytes. Leaves
are supplied in `leafIndex` order (0 to `leafCount - 1`); the tree sorts them internally, and the
proof for leaf `i` is the proof for the `i`-th value as supplied. The backend builder is
`apps/backend/src/lib/sponsored-task-vault-merkle.ts` in the private source tree.

Solana packing:

| Leaf field | Solana value |
| --- | --- |
| `vaultId` | the 32 bytes of the vault PDA, `["vault", mint, sponsor, vault_id u64 LE]` |
| `epoch` | `Reservation.epoch` (the vault epoch at reserve), as a big-endian `uint64` word |
| `allocationId` | the 32 bytes of the reservation PDA, `["task", vault, task_chain_id u64 LE, task_id]` |
| `taskId` | `task_id`, unchanged |
| `leafIndex` | the Base `SponsoredTaskEntitlement.leafIndex` |
| `worker` | the agent's EVM address from the task chain award, not a Solana address |
| `netAmount` | the task chain entitlement's `netAmount`, in the Solana mint's base units |

Reasoning: PDAs are already 32 bytes, unique program-wide and recomputable from the claim's
accounts, so the program compares `vaultId` and `allocationId` with the accounts it was passed
instead of trusting caller data. `task_chain_id` is not a separate leaf field because it is
inside the reservation PDA. The worker stays the EVM address so the leaf matches the task chain award;
`claim` maps it to a Solana destination through the worker's `PayoutBinding`. Because the ids
differ from the EVM vault's, a Solana root never equals the task chain root for the same task; a root
watcher rebuilds the expected Solana root from the task chain entitlements and compares that.

### Test vector

File: [`vectors/solana-award-leaf-v1.json`](vectors/solana-award-leaf-v1.json). It holds the
inputs, the packed fields, each leaf's ABI encoding, leaf hash and proof, and the root. Program
tests and backend tests load it from this path.

| Input | Value |
| --- | --- |
| program id | `STvau1t111111111111111111111111111111111111` |
| mint | 32 bytes of `0x11` (`29d2S7vB453rNYFdR5Ycwt7y9haRT5fwVwL9zTmBhfV2`) |
| sponsor | 32 bytes of `0x22` (`3JF3sEqM796hk5WFqA6EtmEwJQ9quALszsfJyvXNQKy3`) |
| `vault_id` | `7` |
| vault PDA | `E9fYQatdmgJtd7wMVYDztDTkXgVH6J2KCcZm16u1LSYc` |
| `epoch` | `1` |
| `task_chain_id` | `8453` |
| `task_id` | `keccak256("taskmarket.sponsored-task.vector.task")` |
| reservation PDA | `9QcksedA3wPTVVLdrNwsVBxK99T1HTHpisdYkwFq3Pku` |

Packed fields:

```text
vaultId      0xc36027d0374db9a6390cf99618bbf1fa803fb604b269f26409ff4af8843c1465
epoch        1
allocationId 0x7cea48b0f18391c5909a7b11f475e64611f2d3bbe9246cb977d0250b2523bd1a
taskId       0xcfd0f7ac183c798e09e7265d44f73b3b0449a8a0ae881fe4db8a335d25c92174
```

| `leafIndex` | `worker` | `netAmount` | leaf hash |
| --- | --- | --- | --- |
| 0 | `0x1111111111111111111111111111111111111111` | `925000000` | `0x032d3e02f02add16bb3a5835796568a22a2aaedc96b2cd2424be83c0559dbccd` |
| 1 | `0x2222222222222222222222222222222222222222` | `462500000` | `0xc29e58f4211af4bb2150170cccc0f08aa7c95aee1f13a9fdfeaccbab22ad8955` |
| 2 | `0x3333333333333333333333333333333333333333` | `1` | `0x69fb3fb10242774c564877cfa3f110e882bcc4cf921a45696ad70bbf426c577d` |

Root: `0x1d841bb4a841d4b1da8479915b600532f333721bd54730de12f1eb9bda6c79ba`.

The vector has three leaves so that one proof has a single sibling and the others two, which
exercises an unbalanced tree.

## 5. Names the Solana settle and claim instructions emit

`settle`, `claim`, `claim_fee` and `bind_payout` use these names so their rows line up with the
EVM ones. Field names are snake_case in Rust; the projection uses the camelCase names in
section 3.

| Event | Fields | Projection kind | EVM counterpart |
| --- | --- | --- | --- |
| `SettlementInstalled` | `vault`, `reservation`, `task_chain_id`, `task_id`, `epoch`, `root: [u8; 32]`, `leaf_count: u32`, `distributed_gross: u64`, `settled_total: u64` (sum of leaf `netAmount`), `fee_total: u64`, `released_amount: u64` | `settlement_installed` (`settled_total` is `sponsoredTaskTotal`) | `SponsoredTasksVault.SettlementInstalled` |
| `SponsoredTaskClaimed` | `vault`, `reservation`, `task_chain_id`, `task_id`, `leaf_index: u32`, `worker: [u8; 20]`, `destination: Pubkey`, `amount: u64` | `reward_claimed` | `SponsoredTasksVault.SponsoredTaskClaimed` |
| `FeeClaimed` | `vault`, `reservation`, `task_chain_id`, `task_id`, `fee_recipient: Pubkey`, `destination: Pubkey`, `amount: u64` | `fee_claimed` | `SponsoredTasksVault.FeeClaimed` |
| `PayoutBound` | `task_chain_id`, `agent: [u8; 20]`, `payout: Pubkey`, `nonce: u64` | `payout_bound` | none |

`distributed_gross`, `fee_total` and `released_amount` keep the EVM meaning: the reserved amount
covered by awards, the fee carved from it, and the reserved amount returned to the vault's
available balance. `fee_total` is reported at settle even if the fee is transferred later by
`claim_fee`.

`DefaultedByOwner` has no Solana event. A reservation is defaulted when the vault exits while it
is `Reserved` or `Settled` in an earlier epoch (`Reservation::effective_state`). On a Solana
`VaultEmergencyExited`, the indexer writes one `task_defaulted_by_owner` row for each open
reservation of `closed_epoch` in that vault, with the exit's envelope; the unique key for these derived rows is
`(chain, txHash, eventIndex, allocationId)`, so a reader sees the same row kind on both chains.

Errors these instructions add, named after their EVM counterparts in section 2:
`InvalidSettlementTotals`, `SettlementExceedsReservation`, `InvalidClaimProof`,
`ClaimAlreadyPaid`, `ClaimIndexOutOfBounds`, `NothingToClaim`, `NotFeeRecipient`,
`PayoutNotBound`, `ClaimDelayNotElapsed`, `InvalidPayoutSignature` and `StalePayoutNonce`. `settle` reuses
`SettlerThresholdNotMet`, `Paused`, `VaultNotActive`, `EpochMismatch` and
`ReservationWrongState`; `claim` reuses `Paused` and `EpochMismatch`.
