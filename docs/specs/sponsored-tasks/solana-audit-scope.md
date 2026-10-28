# Sponsored Tasks: Solana program audit scope

## Status

The scope for an external audit of the Sponsored Tasks Solana program before its mainnet deploy.
Findings are reported against the commit the audit task names.

## What the program does

A sponsor locks SPL Token or Token-2022 tokens in a vault. Taskmarket's settler reserves part of
the vault for a task that lives on an EVM chain (Base or Tempo), then installs a Merkle root of
that task's awards. Workers, identified by their EVM address, claim their leaf to a Solana address
they bound with an EIP-712 signature. The sponsor can take the whole remaining balance at any time
with an emergency exit.

Read first:

- [`solana/README.md`](../../../solana/README.md): accounts, seeds and the instruction table
  (signer, pause behavior, notes).
- [`settlement.md`](settlement.md): settle, claim, claim fee, the claim delay and the award leaf
  format, with test vectors in [`vectors/`](vectors/).
- [`payout-binding.md`](payout-binding.md): the EIP-712 typed data and the `bind_payout` check.
- [`event-and-error-vocabulary.md`](event-and-error-vocabulary.md): the events and errors shared
  with the EVM vault.

## In scope

`solana/programs/sponsored-tasks/src/` (`lib.rs`, `state.rs`, `events.rs`, `error.rs`): all 16
instructions, every account constraint and PDA derivation, and the helpers they call.

### Instructions and what to attack

| Instruction | Authority | Invariants to break |
| --- | --- | --- |
| `init_config` | program upgrade authority, once | Anyone other than the upgrade authority initializes `Config`; a second init; a settler set with duplicates, more than 5 keys or a threshold of 0 or above its size (`validate_settlers`); `fee_bps` above 10,000. |
| `set_admin`, `set_settlers`, `pause`, `set_claim_delay` | admin | A non-admin changes any of them; a claim delay of zero is stored. |
| `create_vault` | sponsor | A vault over a mint with a refused Token-2022 extension (below); a vault whose token account is not the `Vault` PDA's associated account; a collision between two sponsors' `vault_id`s. |
| `fund` | anyone | The vault credits more than it received (`TransferAmountMismatch` must catch every shortfall); funding an exited vault. |
| `set_managers` | sponsor | A manager's cap set below what it has reserved plus spent; more than 8 managers; a non-sponsor edits managers. |
| `reserve` | settler threshold | Reserving above the available balance or the manager's remaining allowance; a manager on another chain than the task (`ManagerChainMismatch`); a deadline in the past; two reservations for one task. |
| `release` | settler threshold | Returning funds twice; releasing a settled reservation; acting across epochs. |
| `settle` | settler threshold | A root whose totals exceed the reservation; a fee above `Config::fee_bps` of the distributed amount; inconsistent `settled_total`, `fee_total` and `distributed_gross`; a second settle; settling another vault's reservation or across an epoch. |
| `claim` | anyone (relayer) | Paying a leaf twice (`ClaimReceipt`); paying before the claim delay; paying to an address other than the worker's `PayoutBinding`; a proof that verifies against the wrong root, vault, epoch or reservation; claimed totals exceeding `settled_total`. |
| `claim_fee` | config fee recipient | Taking the fee twice, before the claim delay, or by anyone else. |
| `revoke_settlement` | admin, paused or not | Revoking a settlement after any leaf or the fee was claimed (`SettlementHasClaims`); the manager allowance or vault totals not restored exactly. |
| `bind_payout` | anyone (relayer) | A binding without the agent's valid signature; replaying an older binding (the nonce must strictly increase); a signature from another chain id or program id (the EIP-712 domain carries both). |
| `emergency_exit` | sponsor | Anyone else exits; an exit that leaves tokens behind or lets an open reservation or unclaimed award be paid afterwards (the epoch advance must default them). |

### Cross-cutting checks

- **Settler authorization.** `require_settlers` counts distinct configured keys that signed, passed
  as signer accounts after the named accounts. Try duplicates, non-settler signers, signers that
  did not actually sign, and a set rotated mid-flight (`set_settlers` while a reservation is open).
- **Award leaves and proofs.** `award_leaf` must match the EVM vault's OpenZeppelin
  `StandardMerkleTree` leaf byte for byte, and `verify_award_proof` uses sorted-pair keccak. Look
  for second-preimage tricks (an inner node presented as a leaf) and leaf-index overflow.
- **EVM signature recovery.** `recover_evm_address` accepts `v` of 0, 1, 27 or 28 and recovers
  with `secp256k1_recover`. Check malleability and the zero-address case: a replay is blocked
  only by the strictly increasing nonce.
- **Pause semantics.** Paths that add funds or return them to the sponsor stay open while paused
  (`fund`, `release`, `claim_fee`, `bind_payout`, `emergency_exit`); paths that commit or pay
  rewards are blocked (`create_vault`, `reserve`, `settle`, `claim`). Look for a path that moves
  reward funds while paused.
- **Accounting.** The vault's totals (funded, reserved, settled, claimed, withdrawn, defaulted)
  must never let `available` exceed the real token balance, under any order of instructions,
  across epochs.
- **Token-2022 extensions.** `check_mint_extensions` refuses mints with transfer fee, transfer
  hook, permanent delegate, non-transferable or confidential transfer
  (`UnsupportedMintExtension`). Freeze authority, pausable, default-frozen, metadata, metadata
  pointer and mint close authority are accepted on purpose; confirm none of them lets anyone but
  the issuer move or lock vault funds beyond what freezing already allows. Confirm the token
  program passed in is always the mint's owner.

## Off-chain trust assumptions (design review)

These run in Taskmarket's backend, which is not in this repository. Review them as stated, and
report any assumption the program relies on that they do not uphold.

- **Settler key.** One Ed25519 key per cluster, held by the backend, with the settler set 1 of 1 at
  launch. It signs `reserve`, `release` and `settle` only after the EVM task reaches a final
  outcome. A compromised settler can install a wrong root; the controls are the claim delay
  (one hour by default), the admin's `pause` and `revoke_settlement`, and rotation with
  `set_settlers`.
- **Root watcher.** An independent service checks every `settle` against the award root computed
  from the EVM chain's own events, and alerts within the claim delay so a bad root can be revoked
  before it pays.
- **Relayer fee payer.** A backend-held key pays fees and rent for `claim`, `bind_payout` and the
  gasless vault actions. It holds no vault authority: confirm no instruction trusts the fee payer.
- **Admin and upgrade authority.** Held by a multisig with a time lock before mainnet value.

## Out of scope

- The EVM contracts (`evm/`), covered separately.
- The backend, web app, CLI and Codama client, except as the trust assumptions above.
- Issuer powers of an accepted token (freezing, pausing): the program documents them as a sponsor
  and worker risk, not a defect.

## Reporting

For each finding give the instruction, a reproduction (a LiteSVM test in
`solana/programs/sponsored-tasks/tests/` is ideal, using the harness in `tests/common`), the
impact (funds lost, frozen or misdirected; authority bypassed; accounting broken) and a suggested
fix. `make contract solana test` runs the suite.
