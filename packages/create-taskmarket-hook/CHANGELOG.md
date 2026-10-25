# create-taskmarket-hook

## 0.2.1

### Patch Changes

- edd9d15: The generated lifecycle test now creates its task through whichever `createTask` the pinned Taskmarket contracts declare, so it keeps compiling and passing against contracts that take settlement terms in `createTask` and no longer accept the stake-config form.

## 0.2.0

### Minor Changes

- 3033b5e: Add `--network <base-sepolia|tempo-moderato>`. `tempo-moderato` generates a hook project that deploys to the Tempo Moderato testnet: a `foundry.toml` with a `tempo` profile and `tempo_moderato` RPC alias, an `.env.example` naming the TIP-20 fee token that pays for gas, and README steps that deploy with `--tempo.fee-token` and verify through Sourcify at `contracts.tempo.xyz`. The default stays `base-sepolia`.
