# Sponsored Tasks on Solana

Anchor program for Sponsored Task vaults on Solana. It mirrors the EVM vault: reserve per task,
install a Merkle root of awards, workers claim with a proof.

## Toolchain

Pinned in `toolchain.env` (read by `make contract solana ...`), `rust-toolchain.toml` and
`Anchor.toml`:

| Tool | Version |
| ---- | ------- |
| Rust | 1.97.1 |
| Anchor CLI and `anchor-lang` | 1.2.1 |
| Agave (Solana CLI and platform tools) | 4.3.2 |

Install into your home directory:

```sh
sh -c "$(curl -sSfL https://release.anza.xyz/v4.3.2/install)"
cargo install --git https://github.com/solana-foundation/anchor avm --locked
avm install 1.2.1 && avm use 1.2.1
```

## Program

Accounts, all program-derived:

| Account | Seeds | Holds |
| ------- | ----- | ----- |
| `Config` | `"config"` | admin, settler set and threshold, pause flag, fee bps and recipient |
| `Vault` | `"vault", mint, sponsor, vault_id (u64 LE)` | sponsor, mint, token program, token account, status, epoch, cap, totals (funded, reserved, settled, claimed, withdrawn, defaulted reserved and claimable), managers |
| `Reservation` | `"task", vault, base_chain_id (u64 LE), base_task_id` | epoch, Base commitment nonce, deadline, manager, amount, state, award root, settled total, claim count |

The vault's tokens sit in the associated token account owned by the `Vault` PDA. A manager is a
Base or Tempo task creator, `(chain_id, evm_address)`, with a lifetime allowance.

| Instruction | Signer | Paused | Notes |
| ----------- | ------ | ------ | ----- |
| `init_config` | program upgrade authority | - | once; names the admin and settlers |
| `set_admin` | admin | open | hands the admin role to a new key |
| `set_settlers` | admin | open | replaces the settler set and threshold |
| `pause` | admin | open | sets or clears the pause flag |
| `create_vault` | sponsor | blocked | SPL Token or Token-2022; rejects transfer-fee, transfer-hook, permanent-delegate, non-transferable and confidential-transfer mints |
| `set_caps` | admin | open | the vault's cap on outstanding reservations, in its token; a new vault's cap is zero |
| `fund` | anyone | open | `transfer_checked`, then checks the vault received the exact amount |
| `set_managers` | sponsor | open | allowance never below reserved plus spent |
| `reserve` | settler threshold | blocked | the manager's chain must be the task's chain; bounded by the vault cap, the manager allowance and the available balance |
| `release` | settler threshold | open | returns a reservation to the vault; repeating it is a no-op |
| `revoke_settlement` | admin | only while paused | resets a settled reservation with no claims to reserved and clears its root |
| `emergency_exit` | sponsor | open | takes the whole balance, defaults open reservations and unclaimed awards by advancing the epoch, and closes the vault |

Settler signatures are passed as signer accounts after the named accounts. Every state change
emits an event through `emit_cpi!`. `settle` and `claim` (blocked while paused), `claim_fee` (open)
and payout binding are not built yet.

## Commands

```sh
make contract solana build   # anchor build: program .so and IDL under target/
make contract solana test    # build, then LiteSVM tests (cargo test)
make contract solana lint    # cargo fmt --check and clippy -D warnings
make contract solana idl-check  # build, then diff target/idl against the committed idl/
```

Tests run the built program in LiteSVM, with no validator and no network.

CI runs all four in the `quality-solana` job (full-ci label) when this directory changes. After
changing an instruction or account, copy `target/idl/*.json` into `idl/` and commit it.

## Keys

No keypair is committed. `declare_id!` holds a placeholder id; deployer, settler and relayer keys
come from the environment at deploy time.
