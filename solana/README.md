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
make contract solana lint    # cargo fmt --check and clippy -D warnings
make contract solana idl-check  # build, then diff target/idl against the committed idl/
```

Tests run the built program in LiteSVM, with no validator and no network.

CI runs all four in the `quality-solana` job (full-ci label) when this directory changes. After
changing an instruction or account, copy `target/idl/*.json` into `idl/` and commit it.

## Keys

No keypair is committed. `declare_id!` holds a placeholder id; deployer, settler and relayer keys
come from the environment at deploy time.
