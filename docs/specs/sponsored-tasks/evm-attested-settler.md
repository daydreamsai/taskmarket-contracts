# Sponsored Tasks -- EVM attested settler

## Status

Implemented in `evm/src/hooks/sponsored-task/SponsoredTaskSettler.sol` and
`evm/src/hooks/sponsored-task/RemoteSponsoredTaskHook.sol`. Not deployed. This spec covers two
standalone contracts; it does not change the Diamond, `AppStorage`, `SponsoredTasksVault`,
`SponsoredTaskFactory` or `SponsoredTaskHook`.

## Problem

A Sponsored Task vault can live on an EVM chain that does not run the Taskmarket Diamond. The task,
its verdict and its awards stay on the task chain (Base or Tempo); only the tokens are on the remote chain. The vault gates
`reserveTask`, `releaseTask` and `installSettlement` on its controller, and claims open the moment
`installSettlement` succeeds. Vaults are immutable clones, so the remote half has to be a new
controller, and the protections the Solana program already has (a claim delay, admin revoke during
it, an M-of-N settler set) have to live in that controller, not in the vault.

## Change

### Remote chain: `SponsoredTaskSettler`

One settler per remote chain, deployed first; a settler-mode `SponsoredTaskFactory` is then deployed
with the settler as its immutable controller. Every vault that factory creates is an ordinary vault
whose controller is the settler.

| Function                                                             | Who                             | Paused  | Effect                                                                                    |
| -------------------------------------------------------------------- | ------------------------------- | ------- | ----------------------------------------------------------------------------------------- |
| `reserve(ReserveRequest, bytes[])`                                   | anyone, with settler signatures | blocked | until its signed `deadline`, records the commitment and calls `vault.reserveTaskForChain` |
| `release(ReleaseRequest, bytes[])`                                   | anyone, with settler signatures | open    | calls `vault.releaseTask`; a second release is a no-op                                    |
| `settle(SettleRequest, bytes[])`                                     | anyone, with settler signatures | blocked | stores the root as pending with `settledAt`; does not touch the vault                     |
| `finalize(vault, allocationId)`                                      | anyone                          | blocked | once `block.timestamp >= settledAt + claimDelaySeconds`, calls `vault.installSettlement`  |
| `revokeSettlement(vault, allocationId)`                              | owner                           | open    | deletes a pending root; the allocation returns to reserved; its digest stays used         |
| `reopenRevokedSettlement(digest)`                                    | owner                           | open    | lets a revoked digest be submitted again; valid settler signatures are still required     |
| `pause`, `unpause`                                                   | owner                           | --      | immediate                                                                                 |
| `setSettlers(address[], uint8)` / `applySettlers` / `cancelSettlers` | owner schedules, anyone applies | --      | 48h timelock                                                                              |
| `setAuthority(address)` / `applyAuthority` / `cancelAuthority`       | owner schedules, anyone applies | --      | 48h timelock                                                                              |
| `setClaimDelay(uint64)` / `applyClaimDelay` / `cancelClaimDelay`     | owner                           | --      | a raise is immediate; a reduction waits 48h                                               |

Per-allocation state, keyed by `(vault, allocationId)`: `None`, `Reserved`, `Pending`, `Settled`,
`Released`. `release` requires `Reserved`, so a pending root must be revoked before its allocation
can be released.

### Signed messages

EIP-712 domain: `{ name: "Taskmarket Sponsored Settler", version: "1", chainId: <remote
chain>, verifyingContract: <settler> }`.

```text
Reserve(address vault,bytes32 vaultId,bytes32 allocationId,uint256 taskChainId,bytes32 taskId,
        uint64 commitmentNonce,address manager,uint256 grossAmount,uint64 epoch,uint16 feeBps,
        address feeRecipient,bytes32 termsHash,uint64 deadline)
Release(address vault,bytes32 allocationId,uint256 taskChainId,bytes32 taskId,
        uint64 commitmentNonce)
Settle(address vault,bytes32 allocationId,uint256 taskChainId,bytes32 taskId,
       uint64 commitmentNonce,uint64 epoch,bytes32 rewardsRoot,uint32 leafCount,
       uint256 sponsoredTaskTotal,uint256 feeTotal,uint256 distributedGross)
```

`Settle` is the field-for-field EVM form of the Solana settle authorization (program, vault, task
chain id, task id, nonce, root, totals). `Reserve` carries what `vault.reserveTask` needs plus
the task and commitment nonce; `Release` carries only the identifiers.

`Reserve` also carries a `deadline` (unix seconds, from rev031). `reserve` reverts with
`ReserveExpired(deadline)` once `block.timestamp > deadline`, before anything else. The settlers
check that the task is still open when they sign; without a bound, the signatures of a reserve
whose relay failed (they are in its reverted calldata, and in the signer's store) could be
submitted much later for a task that has since been cancelled, holding the amount in the vault and
the same amount of the manager's cap until the settlers sign a release. The Solana program's
`reserve` has the same bound. The backend signer sets the deadline to the earlier of one reserve
lifetime after signing (one hour by default) and the task's release deadline less ten minutes, and
re-signs a reserve that misses it while the task is still open. `release` and `settle` carry no
deadline: a late release only returns funds, and a settle is bound to the reserved allocation's
commitment and can be revoked during the claim delay. A settler deployed before rev031 verifies the
`Reserve` without `deadline`; it is not upgradeable, so it keeps that format for the vaults it
controls (see the rev031 revision doc).

From rev031 the settler reserves with `vault.reserveTaskForChain(..., taskChainId, ...)`, passing the
signed `taskChainId`, so the vault charges the manager's allowance for that task chain only (see
`signed-vault-actions-and-signed-funding.md`, "Manager allowances keyed by task chain"). The vaults
it controls are the ones its own factory created, all from rev031.

Every field is a static type, so the struct hash is `keccak256(abi.encode(TYPEHASH, request))`. The
settler exposes `reserveDigest`, `releaseDigest` and `settleDigest` so a signer can check its
digest against the chain.

### Allocation id and award leaves

```text
allocationId = keccak256(abi.encode(uint256 taskChainId, bytes32 taskId))
```

`reserve` rejects any other value, and stores the request's `taskId` as the allocation's task. One
task therefore maps to one allocation per vault, as the Solana reservation account is derived
from `(task_chain_id, task_id)`.

Award leaves use the shared EVM leaf format (`../sponsored-tasks/event-and-error-vocabulary.md`,
section 4) with the remote vault's `vaultId`, the reservation `epoch`, this `allocationId`,
the task's `taskId` and the task chain award's worker address.

### Authorization

With no authority set, each signature must recover to a current settler, signers must be in
strictly ascending address order (which also rejects a repeated signer), and at least `threshold`
must be present. The set launches 1-of-1 and holds at most 16 keys. One EVM settler key may serve
every EVM remote chain; the domain's `chainId` and `verifyingContract` keep each signature on one
settler. The EVM set is separate from the Solana Ed25519 set.

`authority` is a pluggable authorizer (`ISponsoredTaskSettlerAuthority.isAuthorized(digest,
authorization)`), for a message-bridge receiver later. While one is set it alone decides; setting
it back to `address(0)` returns to the built-in settler set. The current authority is what a client
reads to show the vault's trust tier.

### Base: `RemoteSponsoredTaskHook`

An opt-in ERC-8195 hook, separate from `SponsoredTaskHook`. It calls no vault and moves no project
tokens and moves no token at all: creating a remote task charges no fee. The one-time fee is paid
when the remote vault is created, by the settler-mode factory.

- `checkFund` decodes `FundingRequest { remoteChainId, vault, vaultId, token, grossAmount,
commitmentNonce, epoch, feeBps, feeRecipient, taskTermsHash }`, checks the task terms hash as
  `SponsoredTaskHook` does, rejects a reused `(remoteChainId, vault, commitmentNonce)`, and emits
  `RemoteSponsoredTaskCommitted` with the allocation id above.
- `checkComplete` commits the verdict's awards digest. Above `MAX_AWARDS` (8) the commitment is
  marked unsettleable instead of reverting, and the settler releases it.
- `onCancel`, `onExpire` and the permissionless `finalizeRelease` emit `TerminalReleaseCommitted`.
- The permissionless `finalizeSettlement(taskId, awards)` checks the awards against the commitment,
  computes the root with `SponsoredTaskSettlement.calculate` using the remote ids, and emits one
  `SponsoredTaskEntitlement` per leaf and `SettlementPrepared`. That root is exactly the root the
  settlers sign and the remote vault verifies.
- `reconcile` repairs a missed callback from Taskmarket's terminal state, as on the local hook.
- `reservationReleaseAfter(taskId)` is the task's expiry plus `RESERVATION_RELEASE_GRACE`
  (7 days): the time after which the keeper releases a reservation that has no settlement. From
  rev031 it reverts `ReleaseHeldForLiveSubmissions` while the task is still open with live work (a
  Bounty or Benchmark submission not rejected, or another mode's undecided delivery), since the
  task can still be accepted then.

## Reasoning

**Claim delay in the controller.** The vault opens claims at `installSettlement` and cannot change.
A root installed on a 1-of-1 key's word alone could be drained in the same block, so `settle` only
records it and `finalize` installs it after the delay. During the delay the root watcher, which
rebuilds the expected root from the task chain entitlement events, can flag a mismatch and the owner can
revoke. The cost is a second relayed transaction per settlement, and the vault shows the allocation
as reserved until `finalize`; readers use the settler's `allocationSettlement` to show "settling".
The delay defaults to 3600 seconds and never drops to zero, so the watcher always has a window.

**Revoke without a pause.** On Solana a revoke undoes vault accounting and so requires a pause. Here
nothing in the vault has changed before `finalize`, so revoke only deletes the pending record and
needs no pause. Each accepted settle digest is recorded, so a revoked root's signatures can never be
replayed; the settlers sign a corrected root, which starts a new delay.

**Signed messages, not a sender check.** Signatures let the relayer, not the settler key, submit
and pay gas, and let the threshold rise from 1-of-1 to M-of-N without a contract change.

**Rotation leaves pending roots alone.** Signatures were checked when a root was stored. A rotation
takes effect for new authorizations only; a pending root that should not finalize is revoked on its
own.

**Timelock.** Settler-set changes, authority swaps and claim-delay reductions each wait 48 hours,
so a compromised owner key cannot swap in its own signer and settle at once. Pause, revoke and
raising the delay only reduce what can happen and act immediately.

**Caps.** The only caps are the manager caps a sponsor sets on the vault, as on Solana. A settler
can never reserve more than a manager's remaining allowance or the vault's available balance.

**Replay.** Across chains, by the EIP-712 domain. On the same chain, by the per-allocation state
machine, the stored commitment nonce, the used-digest record and the vault's own allocation state.
On Base, a commitment nonce can fund only one task per remote vault.

**The same creation fee as hook mode.** The settler-mode factory takes the same one-time vault
creation fee as a hook-mode factory, from the vault creator, in the vault-creation transaction on
the remote chain, straight to the fee recipient, never refunded. A remote task, like a hook-mode
task, costs no fee.

**A separate Base hook.** The live `SponsoredTaskHook` is the controller of every Base-local vault.
Adding a non-token path to it would put every Base vault behind a new upgrade; a separate hook
leaves it untouched.

## Deployment

`script/DeploySponsoredTaskSettler.s.sol` deploys, on the remote chain, the registry, the fee
policy, the settler and a factory whose controller is the settler, and hands every owner role to
the admin contract. The factory's creation fee is fixed at deployment and has no owner.
`script/DeployRemoteSponsoredTaskHook.s.sol` deploys, on each task chain, the remote hook behind an ERC-1967
proxy owned by the admin contract. Neither script registers a Diamond default hook.
