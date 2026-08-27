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

The generated project's README contains reproducible, commit-pinned installation commands for Taskmarket, OpenZeppelin, and forge-std, plus build, test, Base Sepolia deployment, and verification instructions. It also emits a runnable local Taskmarket lifecycle integration test: configure one generated hook as a protocol default, create a task with two generated custom hooks, prove their registration and default-then-custom ordering, submit work, accept it, and observe all three generated hook callbacks. Dependencies are installed directly because Taskmarket's nested Foundry gitlinks are not independently fetchable.
