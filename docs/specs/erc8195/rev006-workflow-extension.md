# ERC-8195 Revision 006 — Workflow Extension (ITMPWorkflow)

## Motivation

ERC-8195 models tasks as independent, flat escrow units. This breaks when agents subcontract:
if Agent A hires Agent B and B delegates part of the work to Agent C, the chain is two
unrelated tasks with no on-chain connection. Settlement does not propagate. B must manually
call `acceptSubmission` on Task A-B after C completes Task B-C. Between those two events B
is exposed — A's task could expire, or B could be under-capitalised to front C's reward.

The delegation relationship is also invisible to the protocol. A has no on-chain visibility
into C's involvement, cannot rate C, and ERC-8004 reputation lands only on B regardless of
who did the work.

The `ITMPHook.onComplete` callback cannot solve this. The `nonReentrant` guard blocks any
re-entrant call back into the same Diamond, so a hook on Task B-C cannot synchronously trigger
`acceptSubmission` on Task A-B within the same call stack.

Rev006 adds `ITMPWorkflow`, an optional extension interface that records delegation graphs
on-chain and enables atomic batch settlement authorised by the root requester alone.

## Interface

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface ITMPWorkflow is IERC165 {

    // ─── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new workflow is created.
    event WorkflowCreated(
        bytes32 indexed workflowId,
        bytes32 indexed rootTaskId,
        address         creator
    );

    /// @notice Emitted when a task is linked into a workflow.
    event TaskLinked(
        bytes32 indexed workflowId,
        bytes32 indexed taskId,
        bytes32 indexed parentTaskId,
        address         worker,
        uint256         depth
    );

    /// @notice Emitted when a workflow is settled atomically.
    event WorkflowSettled(
        bytes32 indexed workflowId,
        address         requester,
        uint256         taskCount,
        uint256         totalPaid
    );

    // ─── Mutating Functions ─────────────────────────────────────────────────────

    /// @notice Create a workflow rooted at an existing task.
    ///         Caller must be the requester on rootTaskId.
    function createWorkflow(bytes32 rootTaskId) external returns (bytes32 workflowId);

    /// @notice Link a task into the workflow as a child of parentTaskId.
    ///         Caller must be the current worker on parentTaskId.
    ///         Depth must not exceed MAX_WORKFLOW_DEPTH.
    ///         Sum of child rewards must not exceed the parent task's reward.
    function addWorkflowTask(
        bytes32 workflowId,
        bytes32 taskId,
        bytes32 parentTaskId
    ) external;

    /// @notice Atomically settle all tasks in the workflow.
    ///         The root requester signs the distribution manifest off-chain (EIP-712).
    ///         The contract calls acceptSubmission on each task in topological order
    ///         and verifies the signature before executing any transfer.
    ///         Reverts if any acceptSubmission call reverts — full atomicity.
    function settleWorkflow(
        bytes32           workflowId,
        address[] calldata workers,
        uint256[] calldata amounts,
        bytes32[] calldata deliverables,
        bytes     calldata requesterSig
    ) external;

    // ─── View Functions ─────────────────────────────────────────────────────────

    /// @notice Returns top-level workflow metadata.
    function getWorkflow(bytes32 workflowId) external view returns (
        bytes32 rootTaskId,
        address creator,
        uint256 taskCount,
        bool    settled
    );

    /// @notice Returns the position of a task within a workflow.
    function getWorkflowTask(bytes32 workflowId, bytes32 taskId) external view returns (
        bytes32 parentTaskId,
        address worker,
        uint256 depth
    );

    /// @notice Maximum allowed delegation depth. Implementation-defined; MUST be at least 2.
    function maxWorkflowDepth() external pure returns (uint256);
}
```

## Settlement: Requester-Only Authorization

Workers do not co-sign `settleWorkflow`. They consented to their terms when they accepted
their individual tasks — that consent is already recorded on-chain. Only the root requester
signs the final distribution manifest (EIP-712), which is the same party who would call
`acceptSubmission` in the non-workflow case.

Requiring all parties to co-sign would impose a coordination problem that worsens with chain
depth. In automated agent pipelines no agent is reliably online at settlement time, and
chasing signatures across multiple agents is worse than the manual per-task approach it
replaces.

### EIP-712 Domain and TypeHash

```solidity
bytes32 constant WORKFLOW_SETTLEMENT_TYPEHASH = keccak256(
    "WorkflowSettlement(bytes32 workflowId,address[] workers,uint256[] amounts,bytes32[] deliverables,uint256 nonce)"
);
```

The domain separator uses the standard EIP-712 fields (`name`, `version`, `chainId`,
`verifyingContract`). A per-requester nonce prevents replay. The contract MUST reject a
signature whose nonce does not equal the current requester nonce and MUST increment it on
successful settlement.

## AppStorage Additions

New fields appended at the END of the `AppStorage` struct (offsets 23+):

| Offset | Field | Type |
|--------|-------|------|
| 23 | workflows | `mapping(bytes32 => WorkflowRecord)` |
| 24 | workflowTasks | `mapping(bytes32 => mapping(bytes32 => WorkflowTaskRecord))` |
| 25 | workflowSettlementNonces | `mapping(address => uint256)` |

```solidity
struct WorkflowRecord {
    bytes32 rootTaskId;
    address creator;
    uint256 taskCount;
    bool    settled;
}

struct WorkflowTaskRecord {
    bytes32 parentTaskId;
    address worker;
    uint256 depth;
}
```

`workflowId` is generated as:

```solidity
workflowId = keccak256(abi.encode(block.chainid, address(this), rootTaskId, creator));
```

## New Facet: WorkflowFacet

All `ITMPWorkflow` logic lives in a new `WorkflowFacet`. Added to the Diamond via
`diamondCut` with action `Add`. No existing facet is modified.

`DiamondLoupeFacet.supportsInterface` is updated to advertise `type(ITMPWorkflow).interfaceId`.

Selectors added:

| Function | Selector |
|----------|----------|
| `createWorkflow(bytes32)` | computed |
| `addWorkflowTask(bytes32,bytes32,bytes32)` | computed |
| `settleWorkflow(bytes32,address[],uint256[],bytes32[],bytes)` | computed |
| `getWorkflow(bytes32)` | computed |
| `getWorkflowTask(bytes32,bytes32)` | computed |
| `maxWorkflowDepth()` | computed |

## Constraints Enforced On-chain

- `createWorkflow`: caller must equal `task.requester` on `rootTaskId`.
- `addWorkflowTask`: caller must equal `task.worker` on `parentTaskId`; `depth` of child
  must not exceed `maxWorkflowDepth()`; sum of all child rewards registered under a parent
  must not exceed that parent task's reward (checked at link time against task storage).
- `settleWorkflow`: EIP-712 signature must recover to `task.requester` on the root task;
  nonce must match; `workers.length == amounts.length == deliverables.length`; sum of
  `amounts` must equal root task reward minus platform fee; workflow must not be already
  settled.
- Topological ordering of `workers`/`amounts`/`deliverables` is the caller's responsibility;
  the contract does not sort. Out-of-order arrays that cause an `acceptSubmission` revert
  roll back the entire settlement.

## Capital Exposure

Workers still front child rewards during execution. `ITMPWorkflow` does not split the parent
escrow into child escrows — settlement is atomic at the end, not during the run. This is the
intentional trade-off: no protocol changes to the core task lifecycle, at the cost of
capital exposure during workflow execution.

For use cases where workers cannot front child rewards, the on-chain workflow approach
(escrow splitting, `Delegating` state, `parentTaskId` in `createTask`) remains the correct
design. `ITMPWorkflow` is the right choice for trusted, reputation-staked agent ecosystems
where capital exposure is acceptable and fast iteration matters more than protocol guarantees
during execution.

## ERC-165 Update

`DiamondLoupeFacet.supportsInterface` additions:

| Interface | Added in |
|-----------|----------|
| `ITMPWorkflow` | Rev006 |

## Upgrade Script

```bash
make upgrade testnet   # deploys WorkflowFacet, adds selectors via diamondCut
make upgrade mainnet
```

`DiamondUpgrade.s.sol` is extended to deploy `WorkflowFacet` and issue a single `diamondCut`
with action `Add` for all six selectors. No existing facet is replaced. No initializer is
required — all new AppStorage fields zero-initialise by default.

## Changes from Rev005

| Before | After |
|--------|-------|
| No workflow concept | `ITMPWorkflow` optional extension |
| 9 facets | 10 facets (+ WorkflowFacet) |
| No delegation graph on-chain | `WorkflowRecord` + `WorkflowTaskRecord` in AppStorage |
| Manual per-task `acceptSubmission` chain | Atomic `settleWorkflow` with requester EIP-712 sig |
| `AppStorage` fields 0–22 | Fields 0–25 (3 new fields appended) |
