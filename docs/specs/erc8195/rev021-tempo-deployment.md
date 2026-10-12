# Tempo deployment tooling

## Status

Implemented (tooling only).

## Scope

The Taskmarket diamond deploys to Tempo mainnet (chain 4217) and the Tempo Moderato testnet (chain
42431) from the same sources as Base. No contract under `src/` changes, and no new revision is cut:
a fresh Tempo diamond seeds `diamondVersion` from `LibRevision.CURRENT_REVISION`, exactly as a fresh
Base diamond does. The file name keeps the revision the work was planned against (rev021); the
revision a Tempo diamond reports is whatever `CURRENT_REVISION` is when it is deployed.

What changes is the deploy and upgrade tooling, which only knew Base and Base Sepolia.

## Problem

1. `foundry.toml` had no Tempo RPC aliases, and forge builds ordinary Ethereum transactions unless
   told that the target is a Tempo network.
2. Tempo has no native gas token. Every transaction pays its fee in a TIP-20 stablecoin chosen by
   the sender, so a deploy or upgrade has to name that token.
3. Tempo explorers verify through Sourcify at `https://contracts.tempo.xyz`, not an Etherscan API,
   and there is no Basescan-style "is this a proxy" endpoint to call after a deploy.
4. The RevNNN upgrade scripts chose their diamond with
   `block.chainid == 8453 ? FORGE_DIAMOND_ADDRESS_MAINNET : FORGE_DIAMOND_ADDRESS_TESTNET`. Any
   chain that is not Base mainnet, Tempo included, fell through to the Base Sepolia diamond address.
   Pointed at a Tempo RPC, a step script would read and cut whatever sat at that address on Tempo.

## Change

- `foundry.toml` adds `tempo` and `tempo_moderato` RPC aliases (`FORGE_TEMPO_RPC_URL`,
  `FORGE_TEMPO_MODERATO_RPC_URL`) and a `tempo` profile that sets `network = "tempo"`. The Make
  targets and `script/upgrade.sh` select the profile with `FOUNDRY_PROFILE=tempo`; it inherits
  every other setting from the default profile, so the bytecode is the same.
- `make deploy`, `make upgrade` and `make upgrade-accept-pinning` accept `tempo-testnet`
  (Moderato) and `tempo-mainnet`. They read `FORGE_*_TEMPO_TESTNET` / `FORGE_*_TEMPO_MAINNET`
  inputs, pass `--tempo.fee-token` from `FORGE_FEE_TOKEN_TEMPO_*`, and verify with
  `--verifier sourcify --verifier-url https://contracts.tempo.xyz`. The Basescan proxy
  verification step is skipped on Tempo.
- The DREAMS reward-hook targets (`deploy-reward-hook`, `swap-reward-hook`,
  `upgrade-reward-hook`) refuse Tempo networks. The DREAMS token and its reward vault exist on
  Base only.
- `script/lib/DeployTarget.sol` maps 8453, 84532, 4217 and 42431 to their diamond env vars and
  reverts `UnknownDeployTarget(chainId)` for any other chain. Rev022, Rev023 and
  `DiamondUpgradeAcceptPinning` use it, and every later step script must. Steps before rev022 keep
  the old ternary: a Tempo diamond is born at a later revision, so `upgrade.sh` never selects them
  there.
- `DeployForwarder.s.sol` reads `FORGE_USDC_TOKEN_ADDRESS`, falling back to `USDC_TOKEN_ADDRESS`,
  so it takes the same per-network input as `DiamondDeploy.s.sol`.
- `create-taskmarket-hook` accepts `--network <base-sepolia|tempo-moderato>`.

## Settlement token

On Tempo the diamond's `usdcToken` is OUSD (Open USD), a TIP-20 stablecoin native to Tempo, at
`0x20c0000000000000000000006a37da5c996874be` on both mainnet and Moderato, with 6 decimals. It is
passed as `FORGE_USDC_TOKEN_ADDRESS_TEMPO_*`. The diamond treats it as any 6-decimal ERC-20; the
contract name `usdcToken` is historical.
