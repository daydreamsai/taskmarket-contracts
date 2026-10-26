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
| `Vault` | `"vault", mint, sponsor, vault_id (u64 LE)` | sponsor, mint, token program, token account, status, epoch, totals (funded, reserved, settled, claimed, withdrawn, defaulted reserved and claimable), managers |
| `Reservation` | `"task", vault, base_chain_id (u64 LE), base_task_id` | epoch, Base commitment nonce, deadline, manager, amount, state, award root, settled total, claim count |
| `PayoutBinding` | `"payout", base_chain_id (u64 LE), base_agent (20 bytes)` | the Base agent's Solana payout address and the binding's nonce |

The vault's tokens sit in the associated token account owned by the `Vault` PDA. A manager is a
Base or Tempo task creator, `(chain_id, evm_address)`, with a lifetime allowance.

| Instruction | Signer | Paused | Notes |
| ----------- | ------ | ------ | ----- |
| `init_config` | program upgrade authority | - | once; names the admin and settlers |
| `set_admin` | admin | open | hands the admin role to a new key |
| `set_settlers` | admin | open | replaces the settler set and threshold |
| `pause` | admin | open | sets or clears the pause flag |
| `create_vault` | sponsor | blocked | SPL Token or Token-2022; rejects transfer-fee, transfer-hook, permanent-delegate, non-transferable and confidential-transfer mints |
| `fund` | anyone | open | `transfer_checked`, then checks the vault received the exact amount |
| `set_managers` | sponsor | open | allowance never below reserved plus spent |
| `reserve` | settler threshold | blocked | the manager's chain must be the task's chain; bounded by the manager allowance the sponsor set and the available balance |
| `release` | settler threshold | open | returns a reservation to the vault; repeating it is a no-op |
| `revoke_settlement` | admin | only while paused | resets a settled reservation with no claims to reserved and clears its root |
| `emergency_exit` | sponsor | open | takes the whole balance, defaults open reservations and unclaimed awards by advancing the epoch, and closes the vault |
| `bind_payout` | anyone (relayer) | open | creates or replaces a `PayoutBinding` from the Base agent's EIP-712 signature, checked with `secp256k1_recover`; a replacement needs a higher nonce |

Settler signatures are passed as signer accounts after the named accounts. Every state change
emits an event through `emit_cpi!`. `settle` and `claim` (blocked while paused) and `claim_fee`
(open) are not built yet.

The payout binding's EIP-712 typed data is in
`../docs/specs/sponsored-tasks/payout-binding.md`.

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

## Deploy, upgrade and verify

Every deploy, upgrade and verification uses a verifiable build (`anchor build --verifiable`, in
Anchor's pinned Docker image), so the bytes on chain can be rebuilt from the public source.
`scripts/deploy.sh` holds the steps; the make targets wrap it.

```sh
make contract solana deploy devnet          # first deploy at SOLANA_PROGRAM_KEYPAIR's address
make contract solana buffer devnet          # write the build to a buffer for an upgrade
make contract solana upgrade devnet <buffer>  # upgrade from the buffer (deployer is the authority)
make contract solana verify devnet          # compare the deployed program with the build
```

- `deploy` and `upgrade` accept `localnet` and `devnet` only. On `mainnet-beta`, `buffer` writes the
  build and hands the buffer to `SOLANA_UPGRADE_AUTHORITY` (the multisig, required there); the
  multisig executes the upgrade, then `verify` checks it.
- `deploy` refuses a program keypair whose address differs from `declare_id!`. Set the real program
  id in `declare_id!` and `Anchor.toml` in a reviewed change before the first deploy.
- `verify` is read-only: it compares `solana-verify get-executable-hash` of the build with
  `solana-verify get-program-hash` of the deployed program.
- `DRY_RUN=1` builds and prints each chain-writing command instead of running it.
- `SOLANA_RPC_URL` overrides the cluster's public endpoint; `SOLANA_PROGRAM_ID` overrides the
  `declare_id!` address for `upgrade` and `verify`.

## Keys

No keypair is committed. `declare_id!` holds a placeholder id; deployer, settler and relayer keys
come from the environment at deploy time. The deploy targets read `SOLANA_DEPLOYER_KEYPAIR` (fee
payer and upgrade authority) and `SOLANA_PROGRAM_KEYPAIR` (program id, first deploy only) as paths
to keypair files outside the repository, and refuse a path inside it.
