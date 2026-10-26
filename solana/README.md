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

## Commands

```sh
make contract solana build   # anchor build: program .so and IDL under target/
make contract solana test    # build, then LiteSVM tests (cargo test)
```

Tests run the built program in LiteSVM, with no validator and no network.

## Keys

No keypair is committed. `declare_id!` holds a placeholder id; deployer, settler and relayer keys
come from the environment at deploy time.
