# create-taskmarket-hook

Dependency-free Node.js scaffolder for a secure, Foundry-based Taskmarket hook.

After npm publication:

```sh
npx create-taskmarket-hook <project-name> --taskmarket <address>
```

From a source checkout, run this from the package directory:

```sh
node bin/create-taskmarket-hook.mjs <project-name> --taskmarket <address>
```

The generated project is a Task Hook V2 hook (`ITMPHookV2`, rev028 and later): it extends
`BaseTMPHookV2`, declares its callbacks in `hookCapabilities()` and ships unit tests for the
interface, the capability declaration and the diamond-only caller check, plus a runnable local
lifecycle test. V1 hooks (`ITMPHook`, `BaseTMPHook`) are retired: the diamond refuses to attach
them, so there is no V1 template and no `--hook-version` flag.

`--network <base-sepolia|tempo-moderato>` picks the deploy target and defaults to `base-sepolia`.
`tempo-moderato` generates a `foundry.toml` with a `tempo` profile and a `tempo_moderato` RPC
alias, an `.env.example` that names the TIP-20 fee token (Tempo has no native gas token), and
README deploy steps that verify through Sourcify at `https://contracts.tempo.xyz`.

The generated project's README contains reproducible, commit-pinned installation commands for Taskmarket, OpenZeppelin, and forge-std, plus build, test, deployment, and verification instructions for the chosen network. The project also emits a runnable local Taskmarket lifecycle integration test: create a task with two generated hooks, prove their `HookAttached` events and attachment order, submit work, accept it, and observe both generated `afterComplete` callbacks. Dependencies are installed directly because Taskmarket's nested Foundry gitlinks are not independently fetchable.
