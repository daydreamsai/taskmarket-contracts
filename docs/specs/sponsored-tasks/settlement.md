# Sponsored Tasks: Solana settlement

Status: Implemented by the Solana program's `settle`, `claim` and `claim_fee` instructions.

The task, its verdict and its awards live on Base. The settlers read the Base award events,
rebuild the award list with the Solana ids (see the award leaf in
[`event-and-error-vocabulary.md`](event-and-error-vocabulary.md), section 4) and sign a `settle`
that installs its Merkle root on the task's `Reservation`.

## Instruction

```text
settle(root: [u8; 32], leaf_count: u32, distributed_gross: u64, settled_total: u64, fee_total: u64)
accounts: config, vault (mut), reservation (mut, has_one vault), event authority, program,
          then the settler signers
```

| Field               | Meaning                                                                                 |
| ------------------- | --------------------------------------------------------------------------------------- |
| `root`              | sorted-pair keccak root of the award leaves; zero exactly when `settled_total` is zero  |
| `leaf_count`        | number of leaves; zero exactly when `settled_total` is zero                             |
| `settled_total`     | sum of the leaves' `netAmount` (`sponsoredTaskTotal` on EVM)                            |
| `fee_total`         | fee carved from the awarded gross, at most `distributed_gross * Config.fee_bps / 10000` |
| `distributed_gross` | `settled_total + fee_total`, at most the reservation's `amount`                         |

Checks, in order: settler threshold (`SettlerThresholdNotMet`), pause (`Paused`), vault active
(`VaultNotActive`), current epoch (`EpochMismatch`), reservation `Reserved`
(`ReservationWrongState`), `distributed_gross <= amount` (`SettlementExceedsReservation`),
`settled_total + fee_total == distributed_gross` (`InvalidSettlementTotals`), fee within
`Config.fee_bps` (`InvalidFeeBps`), and root and leaf count present exactly when there are awards
(`InvalidSettlementTotals`).

Effects mirror the EVM vault's `installSettlement`:

- the vault's `total_reserved` drops by the reservation `amount` and `total_settled` grows by
  `distributed_gross`, so `amount - distributed_gross` returns to the available balance;
- the manager's `reserved` drops by `amount` and its `spent` grows by `distributed_gross`, so the
  unawarded remainder returns to the manager's allowance as well;
- the reservation becomes `Settled` with `root`, `leaf_count`, `settled_total` and `fee_total`,
  and `settled_at` records the cluster's unix time;
- `SettlementInstalled` is emitted with `released_amount = amount - distributed_gross`.

`revoke_settlement` reverses every one of these effects exactly, so a corrected root can be
settled again after the pause lifts. It refuses a settlement with any paid leaf or a paid fee
(`SettlementHasClaims`).

## Claim

```text
claim(leaf_index: u32, worker: [u8; 20], amount: u64, proof: Vec<[u8; 32]>)
accounts: config, vault (mut), mint, vault token account (mut), reservation (mut, has_one vault),
          binding (PayoutBinding PDA of reservation.base_chain_id and worker),
          receipt (ClaimReceipt PDA, created), destination token account (mut), payer (mut, signer),
          token program, system program, event authority, program
```

Anyone may relay a claim. Checks, in order: pause (`Paused`), vault active (`VaultNotActive`),
current epoch (`EpochMismatch`), reservation `Settled` (`ReservationWrongState`), the claim
delay passed since `settled_at` (`ClaimDelayNotElapsed`),
`leaf_index < leaf_count` (`ClaimIndexOutOfBounds`), `amount > 0` (`NothingToClaim`), no receipt
for the leaf yet (`ClaimAlreadyPaid`), the proof of `award_leaf(vault, epoch, reservation,
base_task_id, leaf_index, worker, amount)` against the root (`InvalidClaimProof`), the running
claimed total within `settled_total` (`InvalidSettlementTotals`), a binding for the worker
(`PayoutNotBound`), and a destination owned by the bound payout address (Anchor
`ConstraintTokenOwner`).

The vault PDA signs a `transfer_checked` of `amount` to the destination. The reservation's
`claimed_count` and `claimed_total` and the vault's `total_claimed` grow, and
`SponsoredTaskClaimed` is emitted.

## Claim fee

```text
claim_fee()
accounts: config, fee_recipient (signer), vault (mut), mint, vault token account (mut),
          reservation (mut, has_one vault), destination token account (mut), token program,
          event authority, program
```

Open while paused, so a pause never traps fee funds. Checks: the signer is `Config.fee_recipient`
(`NotFeeRecipient`), vault active, current epoch, reservation `Settled`, the claim delay passed
(`ClaimDelayNotElapsed`), and an unpaid non-zero fee
(`NothingToClaim`). It pays `fee_total` to any token account of the vault's mint, sets
`fee_claimed`, adds the fee to `total_claimed` and emits `FeeClaimed`.

## Claim delay

`Config.claim_delay_seconds` holds how long after `settle` a root's claims and fee wait. The admin
sets it with `set_claim_delay` (open while paused; zero and values above `i64::MAX` fail with
`InvalidClaimDelay`). `init_config` stores the default of 3600 seconds, and a stored zero, which
only a `Config` written before the field existed can hold, reads as that default. The field is
appended after every earlier `Config` field so the existing layout is unchanged.

`revoke_settlement` works throughout the delay, whether or not the program is paused. It clears
`root` and `settled_at` and returns the reservation to `Reserved`, so a revoked root can never be
claimed against: a later claim fails on the reservation state, and a corrected root starts a new
delay when the settlers install it. Revoke needs no program-wide pause because it touches only
the one reservation, so revoking one bad root leaves claims on every other vault running, as the
EVM settler mode does. It stays admin-only and is refused (`SettlementHasClaims`) once a leaf or
the fee has been claimed against the root.

## Reasoning

**Settler authorization.** Settlers sign the `settle` transaction itself, as they already do for
`reserve` and `release`: their keys are passed as signer accounts after the named accounts and
counted against `Config.settlers` and `threshold`. The runtime verifies those Ed25519 signatures
before the program runs, which gives the same guarantee as an Ed25519 precompile instruction over
a settler message, with one authorization scheme for every settler-gated instruction. Any account
may pay the fee; the settler signatures authorize.

**Claim delay.** On Solana a root rests on the settler signature alone. The delay gives the root
watcher, which rebuilds the expected root from the Base award events, time to flag a root that
does not match, and the admin time to revoke it, before any token leaves the vault. An
honest award waits one delay. The delay is a `Config` setting rather than a constant so it can be
tuned once watcher latency is measured, and it never drops to zero, so a watcher always has a
window.

**Replay.** A settle cannot be applied twice: the reservation leaves `Reserved`, and a second
settle with the same or a different root fails with `ReservationWrongState`. A transaction
signature also cannot be replayed once its blockhash expires. The EVM vault returns quietly for
an identical second install; Solana rejects it so a relayer sees the conflict.

**Double claim.** Each paid leaf leaves a `ClaimReceipt` account at
`["claim", reservation, leaf_index]`. The account is created with `init_if_needed` so that a second
claim reaches the program and fails with the named `ClaimAlreadyPaid` instead of a framework
"account in use" error. Receipts outlive the claim; a root with receipts cannot be revoked, so a
receipt always refers to the root it was paid against.

**Payout.** The leaf names the worker by their Base address, so it matches the Base award. The
program pays only the token account owned by the address in the worker's `PayoutBinding`, which
the worker signed for (see [`payout-binding.md`](payout-binding.md)); the relayer cannot choose
the destination.

**Fee.** Fee terms are global in `Config` and read at settle. The fee recipient is read from
`Config` at `claim_fee`, so rotating it redirects unpaid fees. The fee is carved from the awarded
gross and counted in `total_settled` with the net awards, so it stays backed by the vault's
tokens until `claim_fee` pays it.
