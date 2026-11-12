# create-taskmarket-hook

## 1.0.0

### Major Changes

- 97f3211: Every project `create-taskmarket-hook` generates is now a Task Hook V2 hook. The `--hook-version` flag is removed: passing it is an error, because V1 hooks are retired and the Taskmarket diamond no longer attaches or calls them. The generated project extends `BaseTMPHookV2`, declares its callbacks in `hookCapabilities()`, and includes unit tests plus a runnable local lifecycle test that attaches two hooks to a task, submits work, accepts it, and checks each hook's `afterComplete` callback. Projects generated earlier with `--hook-version 1` should be rewritten as V2 hooks before they are used on new tasks.

  The generated `remappings.txt` points `@taskmarket/contracts/` at the `evm/` folder of the Taskmarket contracts repository, where the pinned commit keeps its sources, so the project compiles after `forge install`.

## 0.3.1

### Patch Changes

- 7374091: New hook projects are Task Hook V2 hooks by default, scaffolded against a `taskmarket-contracts` commit that includes the rev028 `ITMPHookV2` interface and `BaseTMPHookV2`. Pass `--hook-version 1` to generate a V1 hook for tasks created before rev028.

## 0.3.0

### Minor Changes

- 40cfca9: Add a Task Hook V2 template. `--hook-version 2` generates a project on `BaseTMPHookV2` that declares its callbacks in `hookCapabilities()` and includes unit tests for the `ITMPHookV2` interface, the capability declaration and the diamond-only caller check. Without the flag, the scaffolder generates the `ITMPHook` project. The generated lifecycle test runs a V1 hook on a diamond at revision rev027; from rev028 on, new tasks accept only Task Hook V2 hooks, and V1 hooks serve the tasks created before that revision.

## 0.2.2

### Patch Changes

- 12c96e4: The package's repository link now points at its folder in the `taskmarket-contracts` repository, `evm/packages/create-taskmarket-hook`, where the EVM contracts and their tools live. Scaffolded projects are unchanged.
- 1ad0a83: The generated lifecycle test now also creates its task against Taskmarket contracts whose `createTask` takes version 2 settlement terms (with an accept window for a reserved worker), so it keeps compiling and passing when the pinned contracts move to that version.

## 0.2.1

### Patch Changes

- edd9d15: The generated lifecycle test now creates its task through whichever `createTask` the pinned Taskmarket contracts declare, so it keeps compiling and passing against contracts that take settlement terms in `createTask` and no longer accept the stake-config form.

## 0.2.0

### Minor Changes

- 3033b5e: Add `--network <base-sepolia|tempo-moderato>`. `tempo-moderato` generates a hook project that deploys to the Tempo Moderato testnet: a `foundry.toml` with a `tempo` profile and `tempo_moderato` RPC alias, an `.env.example` naming the TIP-20 fee token that pays for gas, and README steps that deploy with `--tempo.fee-token` and verify through Sourcify at `contracts.tempo.xyz`. The default stays `base-sepolia`.
