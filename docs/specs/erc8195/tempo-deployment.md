# Tempo deployment tooling

## Status

Implemented (tooling only).

## Scope

The Taskmarket diamond deploys to Tempo mainnet (chain 4217) and the Tempo Moderato testnet (chain
42431) from the same sources as Base. No contract under `src/` changes, and no new revision is cut:
a fresh Tempo diamond seeds `diamondVersion` from `LibRevision.CURRENT_REVISION`, exactly as a fresh
Base diamond does. The file name carries no revision number for that reason; the
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
- `make deploy-forwarder tempo-testnet|tempo-mainnet` deploys `TaskMarketForwarderV2` against an
  existing Tempo diamond and registers it with `addForwarder`. See "Forwarder" below.
- The Tempo `deploy`, `deploy-forwarder` and `upgrade` targets run through `script/tempo.sh`, which
  reads only the `_TEMPO_TESTNET` / `_TEMPO_MAINNET` inputs. See "Inputs" below.
- `create-taskmarket-hook` accepts `--network <base-sepolia|tempo-moderato>`.

## Settlement token

On Tempo the diamond's `usdcToken` is OUSD (Open USD), a TIP-20 stablecoin native to Tempo, at
`0x20c0000000000000000000006a37da5c996874be` on both mainnet and Moderato, with 6 decimals. It is
passed as `FORGE_USDC_TOKEN_ADDRESS_TEMPO_*`. The diamond treats it as any 6-decimal ERC-20; the
contract name `usdcToken` is historical.

## Gas on Tempo

Tempo caps a single transaction at 30M gas and charges far more than Ethereum for new code and new
storage. Three things follow for `DiamondDeploy.s.sol` and the Tempo Make targets:

- The diamond is created with only `DiamondCutFacet`, then each other facet is added by its own
  `diamondCut`, with `AdminFacet.initialize` running in the `AdminFacet` cut. Passing every cut to
  the constructor measured about 47M gas on Moderato. The largest single transaction is now the
  `CoreFacet` deployment, about 21M. `diamondCut` is owner-only, so nobody can act on the diamond
  between the steps. Base deploys take the same path.
- The Tempo deploy targets pass `--slow`. Forge estimates each Tempo transaction against the live
  chain when it sends it, so each `diamondCut` must be estimated after the diamond exists; without
  `--slow` it is priced as a call to an empty address and runs out of gas.
- Forge before v1.8.5 simulates contract creation with Ethereum's gas schedule and under-estimates
  a Tempo facet deployment about fivefold, so the first transaction runs out of gas. Deploy to Tempo
  with Foundry v1.8.5 or later.

## Fee token

`FORGE_FEE_TOKEN_TEMPO_*` is only the token the deployer pays gas in; the settlement token is
unaffected. Moderato's validators take fees in PathUSD
(`0x20c0000000000000000000000000000000000000`), and the OUSD/PathUSD fee AMM pool there holds too
little OUSD to convert a deploy's fees, so a deploy that pays gas in OUSD fails before its first
transaction. Moderato deploys pay gas in PathUSD.

## Inputs

The Base targets resolve each input as `${FORGE_X:-$FORGE_X_<NETWORK>}`, so an unsuffixed value wins.
That rule is unsafe on Tempo: an unsuffixed `FORGE_DEFAULT_PLATFORM_FEE_BPS` or
`FORGE_ERC8004_REPUTATION_REGISTRY` kept in `.env` for Base would silently configure a Tempo diamond
with Base's fee or Base's reputation registry. The Tempo targets therefore read only the suffixed
names and overwrite the unsuffixed ones from them before forge runs. A missing required suffixed
variable stops the target before anything is sent, naming every missing variable.

Before broadcasting, the targets print the resolved inputs: network and chain id, RPC alias, the
deployer address derived from the key (never the key), the fee token and every address and fee
the step uses. `DRY_RUN=1` runs the forge scripts without `--broadcast`.

| Target | Required (`_TEMPO_TESTNET` / `_TEMPO_MAINNET`) | Optional |
| --- | --- | --- |
| `deploy` | `FORGE_DEV_PRIVATE_KEY`, `FORGE_FEE_TOKEN`, `FORGE_USDC_TOKEN_ADDRESS`, `FORGE_FEE_RECIPIENT_ADDRESS`, `FORGE_DEFAULT_PLATFORM_FEE_BPS` | `FORGE_ERC8004_REPUTATION_REGISTRY` |
| `deploy-forwarder` | `FORGE_DEV_PRIVATE_KEY`, `FORGE_FEE_TOKEN`, `FORGE_USDC_TOKEN_ADDRESS`, `FORGE_DIAMOND_ADDRESS`, `FORGE_SERVER_ADDRESS` | |
| `upgrade` | `FORGE_DEV_PRIVATE_KEY`, `FORGE_FEE_TOKEN`, `FORGE_DIAMOND_ADDRESS` | |

## Forwarder

`DiamondDeploy.s.sol` cannot trust a forwarder that does not exist yet, so the PGTR forwarder is a
second step. `make deploy-forwarder tempo-testnet|tempo-mainnet`:

1. Reads `owner()` from `FORGE_DIAMOND_ADDRESS_TEMPO_*` and stops if the deployer is not the owner:
   `AdminFacet.addForwarder(address)` is `onlyOwner`.
2. Runs `DeployForwarderV2.s.sol` (`TaskMarketForwarderV2`, which reports the payment so relayed
   `createTask` and `updateTask` are checked against what was paid) with `FOUNDRY_PROFILE=tempo`, `--tempo.fee-token`, `--slow` and
   Sourcify verification. The constructor takes the settlement token
   (`FORGE_USDC_TOKEN_ADDRESS_TEMPO_*`), the diamond, and the authorized relayer
   (`FORGE_SERVER_ADDRESS_TEMPO_*`, the backend's server wallet). The script prints `usdc()`,
   `taskMarket()` and `authorizedRelayer()` and stops unless each equals its input; after a
   broadcast it reads them again from the deployed forwarder.
3. Runs `AddForwarder.s.sol`, which calls `addForwarder(forwarder)` on the diamond from the owner.
4. Checks `isTrustedForwarder(forwarder)` returns true and prints the address to set as the
   backend's `FORWARDER_ADDRESS_<chainId>`.

With `DRY_RUN=1` it simulates step 2 and checks the logged constructor arguments only; the simulated forwarder does not exist on chain, so
`addForwarder` is skipped.
