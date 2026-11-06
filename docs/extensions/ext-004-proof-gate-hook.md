# EXT-004: Proof Gate Hook

`ProofGateHook` (`evm/src/hooks/proof-gate/ProofGateHook.sol`) is an example Task Hook V2 hook. It
lets only allowlisted workers submit benchmark proof entries. It is a standalone, opt-in hook that
is deployed on its own with `make deploy-proof-gate-hook <chain>`. It is not part of any diamond
revision, adds no facet function and changes no `AppStorage`.

## Requirement

The task's diamond must dispatch Task Hook V2 (`diamondVersion()` of 28 or later). Tasks created
before V2 dispatch keep V1 dispatch, which has no `submitProof` check, so their proof entries stay
ungated. The deploy script refuses a diamond below that version.

## How it works

`WorkerFacet.submitProof` runs the V2 `beforeSubmitProof` check after its own validation and before
the proof hash is pushed. A hook that reverts there rejects the call with
`HookRejected(index, A_SUBMIT_PROOF)`, so nothing is recorded and nothing is paid.

`beforeSubmitProof` and `beforeSubmitWork` are separate callbacks. Proof entries never reach
`beforeSubmitWork`, which runs when a result is anchored through `submitWork`. The hook therefore
needs no count of passed proofs and no skip logic at anchoring, and the diamond stores nothing for
it. The hook declares capability bits 0 (before create) and 6 (before submit proof) only. A hook
that wants both gates declares both bits.

## Configuration and allowlist

- At creation the task attaches the hook with `abi.encode(address[] allowed)`, or an empty
  configuration for an empty allowlist. At most 64 workers (`MAX_ALLOWED`) and no zero address. Under the Diamond's default callback gas of 1,000,000, `beforeCreate` runs out of gas past about 40 workers (40 measured at 930,073 gas), so a task that names more than about 40 is refused at creation.
- The task's requester, recorded at creation, adds more workers later with `allow(taskId, worker)`.
  Anyone else is refused with `ProofGate__NotRequester`.
- A worker not on the list is refused with `ProofGate__WorkerNotAllowed(worker)`. After the requester
  allows that worker, the same entry can be submitted again.
- The list only grows. Once a worker is allowed, the task cannot revoke them.
- A second create for the same task id reverts with `ProofGate__AlreadySet`.

## Testing

- `evm/test/ProofGateHook.t.sol`: the block, the pass, retry, adding workers and access control.
- `evm/test/DeployProofGateHook.t.sol`: the deploy script and its diamond version check.
- `make smoke proof-gate` (and `make smoke proof-gate local-tempo`) runs it end to end against a
  local stack with the hook deployed by the stack setup.
