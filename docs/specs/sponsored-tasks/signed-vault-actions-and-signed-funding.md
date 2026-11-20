# Sponsored Tasks -- Signed vault owner actions and signed funding

## Status

Implemented in `evm/src/hooks/sponsored-task/SponsoredTasksVaultV2.sol` and
`evm/src/hooks/sponsored-task/SponsoredTaskFactoryV2.sol`. This spec covers two contracts. It does
not change the Diamond, `AppStorage`, `SponsoredTaskHook`, `SponsoredTaskRegistry` or any
deployed vault.

The original vault and factory (v1) have been removed from the source. No v1 vault was ever used,
and keeping two vault models meant a deploy script could still produce a stack whose owner actions
are not gasless. `SponsoredTasksVaultV2` now holds the whole vault, with its storage layout,
EIP-712 domain, functions and events unchanged, so the v2 contracts already deployed match it.

## Problem

Every owner action on a vault (`configureManager`, `withdrawAvailable`, `emergencyExitVault`) is
gated on `msg.sender`, and `fund` and the factory's creation fee pull from `msg.sender` after an
`approve`. Whoever sends the transaction pays its gas, so a sponsor needs the chain's gas
token before they can do anything. A third party (a relayer) that pays the gas cannot act for the
owner without a way to carry the owner's authority in the call itself.

An EIP-7702 delegation keeps `msg.sender` equal to the owner and needs no contract change, but
only an EOA that can sign an authorization can use it. Browser wallets mostly cannot yet, and a
contract wallet such as a Safe has no EOA key to delegate.

Vaults are immutable minimal clones, so new entry points need a new implementation and a new
factory.

## Change

### `SponsoredTasksVaultV2` (cloned by `SponsoredTaskFactoryV2`)

Inherits the v1 vault unchanged and adds:

| Function                                                                           | Who signs                                           | Effect                                                                            |
| ---------------------------------------------------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------- |
| `configureManagerBySig(manager, cap, active, deadline, signature)`                 | current `owner()`                                   | same as `configureManager`                                                        |
| `withdrawAvailableBySig(recipient, amount, deadline, signature)`                   | current `owner()`                                   | same as `withdrawAvailable`; `AvailableWithdrawn` names the owner                 |
| `emergencyExitVaultBySig(recipient, deadline, signature)`                          | current `owner()`                                   | same as `emergencyExitVault`; `VaultEmergencyExited` names the owner              |
| `cancelOwnerSignatures()`                                                          | owner, as `msg.sender`                              | advances `ownerNonce`, revoking every outstanding signed action                   |
| `fundWithAuthorization(funder, amount, validAfter, validBefore, nonce, signature)` | `funder`, as an EIP-3009 `ReceiveWithAuthorization` | same accounting as `fund`: `totalFunded += amount`, `VaultFunded(funder, amount)` |

Signed owner actions are EIP-712 typed data in the vault's own domain (`SponsoredTasksVault`,
version `1`, the vault as `verifyingContract`):

```text
ConfigureManager(bytes32 vaultId,address manager,uint256 cap,bool active,uint256 nonce,uint256 deadline)
WithdrawAvailable(bytes32 vaultId,address recipient,uint256 amount,uint256 nonce,uint256 deadline)
EmergencyExitVault(bytes32 vaultId,address recipient,uint256 nonce,uint256 deadline)
```

Rules, each a revert:

- `block.timestamp > deadline`: `OwnerSignatureExpired`.
- The signature is not the current owner's for the current `ownerNonce`: `InvalidOwnerSignature`.
  It is checked with `SignatureChecker.isValidSignatureNow`: ECDSA for an EOA owner, ERC-1271
  `isValidSignature` for a contract owner such as a Safe.
- The vault is not active: `VaultNotActive`, as for the v1 functions.

A used signature advances `ownerNonce` and emits `OwnerSignatureUsed(owner, nonce)`, so it cannot be
replayed. The domain names the vault and the chain, so a signature cannot be used on another vault
or chain. A signature from a previous owner stops working when ownership moves.

Completing an ownership transfer (`acceptOwnership`) also advances `ownerNonce` and emits
`OwnerSignatureUsed(previousOwner, nonce)`. Checking the signer against the current owner alone is
not enough: if ownership moved A to B and back to A without the nonce advancing, every unexpired
signature A made before the first transfer would become valid again, including a withdrawal A
prepared before handing the vault over. Advancing the nonce on each transfer revokes those
signatures for good. `transferOwnership` only records a pending owner, so it changes nothing until
the transfer is accepted; outstanding signatures stay valid while a transfer is pending. Setting the
first owner at initialization leaves the nonce at zero.

`fundWithAuthorization` calls the token's `receiveWithAuthorization(funder, vault, amount,
validAfter, validBefore, nonce, signature)`, the bytes-signature form that USDC v2.2 implements,
which also takes ERC-1271 signatures. The token refuses the call unless the vault is the payee, so
an authorization cannot be redirected, and the token's own nonce stops a replay. The vault keeps the
v1 exact-amount checks (`TokenSenderAmountMismatch`, `TokenTransferAmountMismatch`). Only a token
that implements EIP-3009 supports it; any other project token still funds with `approve` and
`fund`.

### Manager allowances keyed by task chain (rev031, `VAULT_VERSION` 3)

A remote (settler-mode) vault funds tasks from more than one task chain. Until rev031 a vault kept
one allowance per manager address, so whoever controls that address on any task chain could create
tasks there that spend it. For an EOA manager that is the same key everywhere, but a contract-wallet
manager (a Safe whose owners were changed on one chain only, a counterfactual wallet that someone
else deploys first on another chain, a factory that is a different contract elsewhere) can be
controlled by a different party on each chain, who could then reserve up to the manager's remaining
cap and award the sponsor's tokens to accounts it controls. The Solana program already keys
managers by `(chain_id, evm_address)`.

From rev031 the vault keys each manager account by `(taskChainId, manager)`, and each allocation
records the task chain its reservation charged, so its release and settlement refund and spend the
same account. Every v2 entry point keeps its signature and acts on `block.chainid`, the vault's own
chain, which is the only task chain a hook-mode vault serves: `configureManager`,
`configureManagerBySig` (its typehash is unchanged), `reserveTask`, `managerAccount` and
`managerRemaining`. The chain-scoped entry points name the task chain:

| Function                                                                                | Who                       | Effect                                                         |
| --------------------------------------------------------------------------------------- | ------------------------- | -------------------------------------------------------------- |
| `configureManagerForChain(taskChainId, manager, cap, active)`                           | owner                     | sets the manager's allowance for tasks from `taskChainId`      |
| `configureManagerForChainBySig(taskChainId, manager, cap, active, deadline, signature)` | current `owner()`, signed | same, with the same owner nonce, deadline and ERC-1271 rules   |
| `reserveTaskForChain(allocationId, taskChainId, taskId, manager, ...)`                  | controller (the settler)  | `reserveTask`, charging the allowance for `taskChainId`        |
| `managerAccountForChain(taskChainId, manager)`, `managerRemainingForChain(...)`         | view                      | the account and what it may still reserve, for that task chain |

```text
ConfigureManagerForChain(bytes32 vaultId,uint256 taskChainId,address manager,uint256 cap,bool active,uint256 nonce,uint256 deadline)
```

`ManagerConfiguredForChain(taskChainId, manager, cap, reserved, spent, active)` carries the chain;
`configureManager` still emits `ManagerConfigured`. A zero task chain reverts `TaskChainRequired`.
`SponsoredTaskSettler` calls `reserveTaskForChain` with the `taskChainId` of the signed `Reserve`,
which it already carried, so the signed message gains no field for this. A sponsor can give one
manager different caps on Base and Tempo. The vault reports `VAULT_VERSION` 3 and its factory
`IMPLEMENTATION_VERSION` 3, so clients tell these vaults from earlier ones by version; every v2
signed action works on both.

Vaults created before rev031 keep the address-only key for life. For them a remote vault serving
more than one task chain should only have managers that are EOAs, or contract wallets with the same
owners on every task chain; an owner who wants the chain-bound key withdraws and creates a new
vault.

### Exited vaults: sweep and the recorded exit amount

The emergency exit is one-shot and accepts a short delivery (a token that charges a transfer fee),
and afterwards every other path is closed: `withdrawAvailable` and `fund` need an active vault.
Tokens an inexact exit left behind, or tokens sent to the vault after it exited, would be locked for
good. `sweepExited(recipient)` lets the owner (as `msg.sender`) send the whole balance of an exited
vault to `recipient`, with the exit's transfer check, and emits
`ExitedVaultSwept(vaultId, owner, recipient, amount)`. An exited vault owes nothing (every
reservation and unclaimed award defaulted when its epoch advanced), so its whole balance is the
owner's. It reverts with `VaultNotExited` on an active vault, and with `ZeroAddress` for a zero
recipient. It has no signed variant.

`totalWithdrawn`, the value `emergencyExitVault` returns and `VaultEmergencyExited.amountWithdrawn`
record what the recipient received, not the balance before a token's fee. `sweepExited` adds what it
delivers to `totalWithdrawn` the same way.

Vaults are clones of a fixed implementation, so this reaches only vaults cloned from an
implementation deployed after the change, behind a new factory; existing vaults keep their code.

The Solana program has the same gap and the same fix: `sweep_exited`, sponsor-only and open while
paused, moves an exited vault's token balance to the sponsor's token account, adds it to
`total_withdrawn` and emits `ExitedVaultSwept { vault, sponsor, recipient, amount }`
(`VaultNotExited` on an active vault). A Solana mint cannot charge a transfer fee (`create_vault`
rejects the extension), so its exit already records what arrived.

### `SponsoredTaskFactoryV2`

`IMPLEMENTATION_VERSION = 2` (3 from rev031, the vaults keyed by task chain); it clones
`SponsoredTasksVaultV2` and registers each vault with the
existing `SponsoredTaskRegistry`, once the registry owner has authorized it with `setFactory`.
`VaultCreated` has the same signature as v1, so one ABI reads both factories.

| Function                                                             | Effect                                                                                                                                   |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `createVault(token, vaultOwner, userSalt)`                           | as v1: the caller is the creator                                                                                                         |
| `createVaultBySig(token, vaultOwner, userSalt, deadline, signature)` | the owner is the creator: the vault gets the address `createVault` from the owner would give it, and `VaultCreated.creator` is the owner |

`createVaultBySig` checks an EIP-712 signature (domain `SponsoredTaskFactory`, version `2`) by the
owner, with ERC-1271 for contract owners, over
`CreateVault(address token,address vaultOwner,bytes32 userSalt,uint256 nonce,uint256 deadline)`.
The nonce is `createNonces[vaultOwner]`. Errors: `CreateSignatureExpired`, `InvalidCreateSignature`.

### Signed create with the creation fee

`createVaultBySigWithFeeAuthorization(token, vaultOwner, userSalt, deadline, signature,
feeAuthorization)` is `createVaultBySig` with the factory's one-time creation fee paid by the
owner's EIP-3009 `receiveWithAuthorization` to the factory, which forwards it to the fee recipient
in the same call. The authorization's nonce must be `feeAuthorizationNonce(vaultOwner, nonce) =
keccak256(chainId, factory, vaultOwner, nonce)` for the create nonce being used, so it pays for that
one signed create and no other. `createVaultBySig` takes the fee from the owner's allowance instead.

## Who pays and who holds funds

A relayer that submits any of these calls pays only the gas. It cannot change any signed field.
Every token movement is authorized by the account whose tokens move and goes to the vault or
recipient that account signed for. No contract here holds funds for a relayer, and a relayer's
balance is never part of a vault's accounting.

## Redirecting recipients

Every outgoing transfer checks the named recipient's balance, as in v1: claims, fee claims and
signed withdrawals need it to rise by exactly the amount, and the emergency exit needs it to rise.
A token whose receive policy delivers to another address than the one named (a Tempo TIP-20
receive policy or a forwarding address) credits the named recipient nothing, so the call reverts
with `TokenRecipientAmountMismatch` and nothing changes: no tokens leave the vault, no claim is
marked, the claim nonce is not spent and a relayed owner signature is not used up. The same
signature succeeds once the destination stops redirecting, or the signer signs again for another
destination. The vault does not try to resolve the effective recipient, because it cannot tell a
redirect from a fee and paying an address nobody signed for would break the signed-destination
rule above.

## Existing vaults

## Deployment

`make deploy-sponsored-task <chain>` (hook mode) and `make deploy-sponsored-task-settler <chain>`
(settler mode) deploy `SponsoredTaskFactoryV2` directly and authorize it in the registry. On a chain
whose registry still authorizes a v1 factory, the registry owner calls
`SponsoredTaskRegistry.setFactory(v1Factory, false)` so no v1 vault can be created again. Record the
factory in the chain registry so the backend indexes it and relays its calls.

## Tests

`evm/test/SponsoredTasksVaultV2.t.sol` and `SponsoredTaskFactoryV2.t.sol` cover:

- replay, deadline, wrong signer and changed signed fields;
- cross-vault replay, a signer who is no longer the owner, and cancellation;
- ERC-1271 owners and funders;
- funding accounting and events, with the funder recorded and never the relayer;
- signed create addresses and events;
- the creation fee: paid once by allowance or by an authorization tied to one signed create, refused without it, never refunded, and fixed when the factory is deployed; when the fee recipient itself pays by allowance nothing moves, and the create goes through without an approval;
- the unchanged v1 entry points;
- a redirecting recipient on `claim`, `claimTo`, `claimFee`, `withdrawAvailableBySig` and
  `emergencyExitVaultBySig`: each reverts, keeps its nonce and succeeds unchanged once the redirect
  is removed.
