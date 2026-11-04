# Rev028 -- Task Hook V2, the settlement record and the dispute check-hook context

## Status

Implemented; not deployed on any chain. The rollout (chains, order, timing) is not part of this
revision. The payout gate hook must not be deployed on a chain until this revision's cut is live
there.

## Problem

- **Check hooks cannot see a dispute resolution.** `resolveDispute` pays through `_payAwards`, which
  set `task.status = Accepted` before it ran the `checkComplete` hooks, and the hook context reads
  `currentState` from `task.status`. A hook that must never hold a dispute resolver's ruling (the
  payout gate) could not tell it from an ordinary accept.
- **V1 is policy and observation only.** `ITMPHook` has six `check*` callbacks returning `bool` and
  four best-effort `on*` callbacks. A hook can veto or observe, but cannot change a settlement
  result.
- **The lifecycle is incomplete.** Assigning an evaluator, updating a task, pitches, proofs, bids,
  rejecting a submission, appeals, cancel and rating have no callback.
- **One blob for every hook.** All hooks on a task share one creation-time `hookData`.
- **No capability or version negotiation**, and **behaviour can change silently** behind a stored
  hook address.
- **Accounting hooks guess.** Callbacks do not carry the amounts that moved, and a swallowed `on*`
  failure leaves an accounting hook wrong with no way to recover from diamond state.
- **Defaults can crowd out requesters.** Protocol default hooks share the eight slots.

## Change

### Scope rule: new tasks are V2-only

Every task created after the cut is a V2 task: `taskHookVersion[taskId] = 2`, fixed at creation.
Tasks created before the cut read `0` and keep their stored `taskHooks` array and exact V1 dispatch
(callbacks, context, stipend, failure behaviour) until they are terminal. Nothing migrates them.
`defaultHooks` (V1) is no longer applied to new tasks; V2 defaults live in `defaultHooksV2`.

Every `createTask` overload keeps its selector. For a V2 task, `HookConfig.contracts` holds the
requester's V2 hooks and `HookConfig.data` is empty or `abi.encode(bytes[] configs)`, one
configuration per requester hook (a length mismatch reverts `HookIncompatible(index, 5)`). A hook
that implements only the V1 `ITMPHook` interface reverts `HookV1Retired(index)`.

### Dispute resolution check-hook context

On the `resolveDispute` path only, the context a check hook sees has
`currentState == TaskStatus.Disputed`:

- V1 tasks: the `TaskContext` passed to `checkComplete`. Every other field is built as before, at the
  same point (after the status write and award bookkeeping).
- V2 tasks: the `TaskContextV2` passed to `beforeAccept`. On this path `beforeAccept` is called best
  effort: its veto (a revert, out of gas, or a wrong return) is ignored and reported in
  `HookCallFailedV2`, so no hook can hold a ruling. A transforming hook's valid result still
  applies.

Unchanged: the evaluator accept path and finalize after expiry still show the status the diamond
wrote; `onComplete` (V1) and `afterComplete` (V2) see the settled `Accepted` status on every path.
The `ITMPHook` ABI and the `TaskContext` layout are unchanged. `checkComplete` with
`ctx.currentState == Disputed` means the call settles a dispute. A V1 hook that required
`currentState == Accepted` in `checkComplete` would now revert dispute resolutions; the reference,
reward and Sponsored Task hooks in this repository do not check it.

### Storage

Appended to `AppStorage` after `fundingPool`, in this order. No existing field moves, is renamed or
is reused.

```solidity
mapping(bytes32 => uint8) taskHookVersion;                       // 0 = V1, 2 = V2
mapping(bytes32 => ITMPHookV2.Attachment[]) taskHooksV2;         // defaults first, then requester hooks
ITMPHookV2.Attachment[] defaultHooksV2;                          // at most MAX_DEFAULT_HOOKS_V2
mapping(uint8 => uint256) hookCapabilityGas;                     // zero reads as GAS_FLOOR
mapping(bytes32 => mapping(uint8 => uint64)) hookCallSeq;        // next after-callback seq per hook
mapping(bytes32 => ITMPHookV2.SettlementAmounts) taskSettlements; // the settlement record
uint16 maxHookFeeBps;                                            // zero: no hook fee may be taken
```

Every field reads zero as its correct default, so the cut needs no initializer.

### Attachment and attach

```solidity
struct Attachment {
    address hook;
    uint32 capabilities;     // declared flags, masked to the bits this revision defines
    uint16 minDiamondVersion;
    bool transforming;       // holds bit 26 or 27; at most one per task
    bytes32 configHash;      // keccak256 of this hook's configuration bytes
    bytes32 codehash;        // runtime codehash observed at attach
    uint32 callRoles;        // roles accepted on onCall (bit 30 only), pinned at attach
}
```

For each requester hook, at creation, the diamond:

1. requires code at the address and `supportsInterface(type(ITMPHookV2).interfaceId)` (50,000 gas
   cap per manifest read); a V1-only hook reverts `HookV1Retired`;
2. reads `hookCapabilities()` and `minDiamondVersion()`, requiring `minDiamondVersion <=
   diamondVersion()`;
3. masks the capabilities to the defined bits and rejects a hook left with none; a hook with bit 30
   also has `hookCallRoles()` read (manifest reason when it fails or returns zero) and pinned as
   `callRoles`;
4. records `codehash`, stores `configHash` and emits
   `HookAttached(taskId, index, hook, capabilities, codehash, configBytes)`;
5. calls `beforeCreate(taskId, ctx, configBytes, actionData)` on every hook with bit 0, in order.

A failed check reverts `HookIncompatible(index, reason)` with reason 1 interface, 2 manifest,
3 version, 4 capabilities, 5 config. A duplicate address reverts `DuplicateHookAddress`. The
configuration bytes are emitted, never stored. A protocol default is checked when the owner sets it
(`setDefaultHooksV2`) and its codehash again at each attach (`HookCodeChanged` on a mismatch); it
gets empty configuration bytes.

### Capability bits

| Bit   | Meaning                                                                   |
| ----- | ------------------------------------------------------------------------- |
| 0-15  | Before-callback for each vetoable action, bit = action id (table below)   |
| 16-20 | Reserved                                                                  |
| 21-24 | `afterComplete`, `afterCancel`, `afterExpire`, `afterForfeit`             |
| 25    | `afterAction` for every other action (the observer group)                 |
| 26    | Result power: reduce or reallocate awards among eligible workers          |
| 27    | Result power: a hook fee within `maxHookFeeBps`                           |
| 28-29 | Reserved (28 redirect, 29 separately funded value); masked off            |
| 30    | Receives calls through `callTaskHook` (`onCall`) from `hookCallRoles()`   |
| 31    | Reserved; masked off                                                      |

### Hook calls by role

A hook can need input after creation (the payout gate's late link; later, allowlists, bonds or
findings). Every Taskmarket user action is relayed and gas-paid by the backend, so a call the user's
own wallet sends to a hook is not an option, and no contract other than the diamond trusts the
forwarder. One generic entry point serves every hook and every participant:

```solidity
function callTaskHook(bytes32 taskId, address hook, bytes calldata data) external;
function taskCallerRoles(bytes32 taskId, address who) external view returns (uint32);
event TaskHookCalled(bytes32 indexed taskId, address indexed hook, address indexed caller,
    uint32 roles, bytes32 dataHash);
// on the hook (ITMPHookV2)
function hookCallRoles() external view returns (uint32);
function onCall(bytes32 taskId, TaskContextV2 ctx, address caller, uint32 roles, bytes data)
    external returns (bytes4);
```

Anyone may call `callTaskHook`, directly or through the trusted forwarder. The relay is a
convenience, never a boundary: every check is onchain. The diamond:

1. refuses while paused, and takes the reentrancy lock;
2. resolves the caller through the relayed-sender path;
3. refuses an unknown task (`TaskDoesNotExist`) and a settled one, Accepted, Cancelled or Expired
   (`TaskAlreadySettled`);
4. refuses a hook that is not one of the task's V2 attachments (`HookNotAttached`) or lacks bit 30
   (`HookCallNotDeclared`);
5. computes the caller's roles from current state and refuses a caller holding none of the pinned
   `callRoles` (`HookCallRoleRefused(roles)`), before calling the hook;
6. calls `onCall` with the action-22 gas budget (`hookCapabilityGas(22)`, else the stipend with the
   1M floor) and the codehash check of every vetoable call; a revert or wrong return reverts
   `HookRejected(index, 22, reason)`;
7. emits `TaskHookCalled` with `keccak256(data)`.

Roles are flags; one wallet can hold several:

| Flag        | Value     | Holder                                                                                          |
| ----------- | --------- | ----------------------------------------------------------------------------------------------- |
| `REQUESTER` | `1 << 0`  | `task.requester`                                                                                |
| `PROJECT`   | `1 << 1`  | the owner of the task's project, the operator that created it, or an operator with an accepted, unrevoked grant on the project |
| `WORKER`    | `1 << 2`  | `task.worker` (the claimer, selected pitcher or auction winner; cleared by a forfeit)          |
| `SUBMITTER` | `1 << 3`  | a wallet with a recorded submission: Bounty and Benchmark only (a single-worker delivery is `WORKER`) |
| `EVALUATOR` | `1 << 4`  | the task's assigned evaluator                                                                   |
| `STRANGER`  | `1 << 31` | set alone when the caller holds none of the others                                              |

Bits 5-30 are free for later roles (reserved worker, bidder, dispute resolver, awarded or rejected
worker). A reservation is no role in this revision. Hooks test the flags they need
(`BaseTMPHookV2._hasRole`) and never compare the whole set, so a new flag never breaks them. A
stranger is refused unless the hook accepts `STRANGER`.

Guidance for hook authors:

- Bound what a call may change. A hook that affects payouts should lock its changes before review
  starts, because a call and a settlement can race: whichever lands first wins, and the settled
  check above refuses only calls after the settlement.
- `SUBMITTER` is cheap on a bounty (anyone can submit), so it is a weak role; never move money on a
  submitter's input alone.
- Call data is public onchain. The event carries only its hash; the transaction does not hide it.
- `BaseTMPHookV2` declares no roles and its `onCall` reverts; override both with bit 30.

### Composition

- Order is fixed and deterministic: protocol defaults in `defaultHooksV2` order, then requester hooks
  in the order supplied. The order is stored at creation and never changes.
- At most eight hooks per task (or the chain's lower `maxHooks`). Defaults take at most two slots
  (`MAX_DEFAULT_HOOKS_V2 = 2`; `setDefaultHooksV2` reverts `TooManyDefaultHooks` above two), so a
  requester always has at least six.
- At most one attachment per task may be transforming; a second reverts
  `MultipleTransformingHooks()`. Any number of veto and observer hooks may attach.
- Before-callbacks run in order; the first veto reverts the whole action, so order affects only which
  veto is reported.

### Actions and phases

| Id | Action                   | Before (vetoable)                       | After                        |
| -- | ------------------------ | --------------------------------------- | ---------------------------- |
| 0  | Create                   | `beforeCreate` (with the hook's config) | `afterAction`                |
| 1  | AssignEvaluator          | `beforeAssignEvaluator`                 | `afterAction`                |
| 2  | Update                   | `beforeUpdate`                          | `afterAction`                |
| 3  | Claim                    | `beforeClaim`                           | `afterAction`                |
| 4  | SubmitPitch              | `beforeSubmitPitch`                     | `afterAction`                |
| 5  | SelectWorker             | `beforeSelectWorker`                    | `afterAction`                |
| 6  | SubmitProof              | `beforeSubmitProof`                     | `afterAction`                |
| 7  | SubmitBid                | `beforeSubmitBid`                       | `afterAction`                |
| 8  | AcceptAuction            | `beforeAcceptAuction`                   | `afterAction`                |
| 9  | SubmitWork               | `beforeSubmitWork`                      | `afterAction`                |
| 10 | RejectSubmission         | `beforeRejectSubmission`                | `afterAction` or `afterForfeit` |
| 11 | Evaluate                 | `beforeEvaluate` (sees the verdict)     | `afterAction`                |
| 12 | Appeal                   | `beforeAppeal`                          | `afterAction`                |
| 13 | Accept                   | `beforeAccept`, plus settlement result  | `afterComplete`              |
| 14 | Cancel                   | `beforeCancel`                          | `afterCancel`                |
| 15 | Rate                     | `beforeRate`                            | `afterAction`                |
| 16 | Forfeit                  | never                                   | `afterForfeit`               |
| 17 | Expire (refund)          | never                                   | `afterExpire`                |
| 18 | Requester and evaluator timeouts | never                           | `afterExpire` or `afterForfeit` |
| 19 | Lapsed-review settlement | never                                   | `afterComplete`              |
| 20 | Finalize after expiry    | never (`beforeAccept` best effort)      | `afterComplete`              |
| 21 | ResolveDispute           | never (`beforeAccept` best effort, `Disputed`) | `afterComplete`       |
| 22 | Hook call (`callTaskHook`) | `onCall` on the named hook only (bit 30) | none                  |

Accept covers `acceptSubmission`, `acceptSubmissions` and `finalizeVerdict` before task expiry;
there `beforeAccept` is vetoable. On every accept path, `beforeAccept`'s `ctx.currentState` is the
task's status before the accept writes `Accepted` (equal to `priorStatus`). On a dispute
resolution it is `Disputed`. Rejecting a delivery (`rejectDelivery`) runs
`beforeRejectSubmission`.

The non-vetoable exits are forfeit and reopen, release of a claim, expiry refund (`refundExpired`),
the requester and evaluator timeouts, declining or lapsing a reservation, `settleLapsedReview`,
`finalizeVerdict` after expiry and `resolveDispute`. No hook callback, revert, out-of-gas or code
change can block them: none calls a vetoable before-callback, and their after-callbacks are best
effort.

Every callback receives `taskId` and a `TaskContextV2` (actor, requester, worker, evaluator,
dispute resolver, payment token, reward, evaluator stake and fee, protocol fee, mode, prior status,
current status, expiry, project ID and current terms). `actor` is the authenticated caller of the
action (resolved through a trusted forwarder). `priorStatus` is the task's status before the action wrote it.
It is recorded by every action that dispatches V2 callbacks and cleared when the action ends, so a
later action in the same transaction never reads it.

### Veto and the before-call rules

A before-callback allows the action by returning its own selector as exactly one 32-byte word. Any of
the following vetoes the action and reverts `HookRejected(index, action, reason)`, where `reason`
is the hook's return or revert data (at most 256 bytes), so a rejection can be decoded: a revert, running out of
its gas budget, a different value, or return data longer or shorter than 32 bytes. `beforeAccept`
returns `(bytes4, SettlementDelta, Award[])`; only its first word is read for a non-transforming
hook.

### Per-action data

`withActionData(bytes actionData, bytes call)` cannot be nested, and cannot be called from inside an
action under way (a hook calling it mid-dispatch): both revert `ActionDataCallFailed`. It runs
`call` (any diamond action) with a delegatecall to the diamond itself, so the action sees the same caller and authenticates it as it would without the
data. `actionData` (at most `MAX_ACTION_DATA = 2048` bytes) is held in transient storage for that
call, passed unchanged to every V2 callback the action makes, never stored, and its `keccak256` is
emitted in `HookActionData(taskId, action, dataHash)`. Every other action passes empty bytes. Hooks
validate it themselves.

### Settlement results

A transforming hook's `beforeAccept` returns

```solidity
struct SettlementDelta {
    bytes4 selector;   // must equal beforeAccept's selector
    uint16 awardCount; // zero means keep the core awards; otherwise the length of the Award[] beside it
    uint16 hookFeeBps; // hook fee on the awards, from the worker side
}
```

and an `Award[]` of at most 50 entries. The return is decoded word by word without trusting its
encoding; the diamond applies it only if all of:

- `awardCount` equals the array length, and a nonzero `awardCount` needs bit 26;
- every nonzero award goes to the eligibility set: a worker who submitted a deliverable on this task
  (Bounty, Benchmark) or the locked worker (Claim, Pitch, Auction), each at most once;
- the awards total at most what the core would have paid (the award budget); the shortfall goes to
  the requester refund;
- `hookFeeBps <= maxHookFeeBps` (owner-set, default 0, at most 1000) and a nonzero fee needs bit 27;
  the protocol fee plus the hook fee is at most 100% of each award.

A result that fails any check reverts `HookResultInvalid(index)`.

A settlement result applies only on the vetoable accept path (`acceptSubmission`,
`acceptSubmissions`, and `finalizeVerdict` before expiry), and only after the hook's codehash has
matched. On dispute resolution and on a settlement after expiry, any result is ignored: the ruling
or the core settlement stands as computed. Each nonzero award is paid net of the protocol fee and the hook fee, rounded down; the hook
fee goes to the hook. Rating and appeal rights (`taskAwarded`) follow the final nonzero awards. On the verdict path,
the applied awards are written back to the stored verdict, so `getTaskVerdict` reports what was
paid. `acceptSubmission` and `acceptSubmissions` store no verdict; their payouts appear in
`TaskCompleted` and the settlement record. `acceptSubmissions` rejects a zero share
(`ZeroPayoutPerPair`) whether or not a hook result applies.
Conservation: worker payouts plus requester refund plus evaluator fee plus protocol fee plus hook fee
equal the released escrow, which `LibEscrow.release` enforces (`EscrowOverdrawn`).

The redirect and separately funded value powers are not part of this revision.

### Settlement record and callback amounts

```solidity
struct SettlementAmounts {
    uint128 workerPaid;      // net to workers
    uint128 requesterRefund; // everything paid back to the requester's side
    uint128 forfeited;       // stakes forfeited, accumulated across forfeits
    uint128 evaluatorFee;
    uint128 protocolFee;
    uint128 hookFee;
    uint16 awardCount;
    uint8 terminalStatus;
    uint40 settledAt;
    bool recorded;
}
```

- The record is written once, when a task becomes terminal after the cut. This applies to every
  task, including V1 tasks created before the cut. A task that was terminal before the cut reads
  with `recorded == false`. `forfeited` accumulates across forfeits before that.
- Amounts cover the whole task from the cut on. The payments of non-terminal transitions (a
  forfeited stake, a reject fee, a penalty) are added to the running totals when they happen, and
  the settling transition adds its own. A reward decrease through `updateTask` settles nothing and
  is not counted. A Claim worker's returned stake
  is not counted, because it was the worker's own money. A forfeited stake paid to the requester
  counts in both `forfeited` and `requesterRefund`.
- `getTaskSettlement(bytes32)` reads it. `TaskSettled(taskId, SettlementAmounts)` is emitted at the
  same write.
- `afterComplete`, `afterCancel`, `afterExpire` and `afterForfeit` receive the same struct the record
  holds (for a forfeit, the running totals with `recorded == false`), so a hook's callback stream and
  the record cannot disagree.

### Behaviour binding

Before every before-callback, and every observer after-callback of a vetoable action, the diamond
compares `hook.codehash` with the stored `codehash`. A mismatch reverts `HookCodeChanged(index)`.
Terminal after-callbacks and the best-effort `beforeAccept` skip the comparison and proceed. A
proxy's runtime codehash does not change on an implementation upgrade; a hook behind a proxy
declares its mutability policy in its manifest.

### Failure, gas and sequence numbers

- Each callback forwards the gas budget of its capability bit, `hookCapabilityGas(bit)`. An unset
  budget reads as this chain's hook gas stipend (`hookGasStipend`, rev026), so a chain that raised
  the stipend for its storage costs (Tempo) gives V2 hooks the same headroom V1 hooks have. The
  owner can set a budget per bit from 1,000,000 to 8,000,000. The diamond first requires
  `gasleft() >= budget * 64 / 63 + 100,000`. What happens when that check fails depends on the
  callback:
  - A vetoable callback reverts `InsufficientGasForHooks`.
  - A best-effort callback is skipped. This covers every terminal after-callback, the best-effort
    `beforeAccept` and the after-callbacks of non-vetoable exits. The skip is reported as
    `HookCallFailedV2` with failure class 5, and the callback's sequence number is still spent.

  So `refundExpired`, the timeouts and the other exits never revert for hook gas, whatever the
  budgets and the number of hooks.
- On a non-exit action that ends or advances a task the requester or evaluator chose to settle, the
  gas for every after-callback's budget is required before the first callback runs, and the
  action reverts `InsufficientGasForHooks` without it. That covers `acceptSubmission`,
  `acceptSubmissions`, `finalizeVerdict` before expiry, `cancelTask` and `rejectDelivery`. A gas
  estimate for the action therefore covers its after-callbacks, and they are never skipped for
  gas there.
- At most 32 bytes of return data are copied for a before-callback, 256 for an after-callback, and
  the bounded result size for the transforming hook.
- An after-callback failure is swallowed and emits
  `HookCallFailedV2(taskId, index, hook, action, phase, failureClass, revertHash, seq)`, where
  `revertHash` is the `keccak256` of at most 256 bytes of revert data. Failure classes: 1 reverted
  with data, 2 reverted empty (including out of gas), 3 rejected, 4 result invalid.
- Every after-callback receives `seq`, the next value of `hookCallSeq[taskId][index]`. It increases
  by one per after-callback whether the call succeeds, fails or is skipped, so a hook can detect a
  missed callback.
- There is no protocol-managed replay. A hook recovers from the settlement record.

### Dispatch location

All hook dispatch, V1 and V2, lives in `HookDispatchFacet`. The other facets reach it through a call
from the diamond to itself (`ITMPHookDispatch`, which reverts `NotSelf` for any other caller). The
outer action holds the reentrancy guard throughout, so a hook cannot re-enter a guarded entrypoint.
A V1 check rejection still reverts with its `HookCheck*Rejected` selector. `rateTask` now holds the
reentrancy guard as well.

### Interface

`ITMPHookV2` (`src/interfaces/ITMPHookV2.sol`) declares `hookCapabilities()`,
`minDiamondVersion()`, one `before*` function per vetoable action, the four terminal after-callbacks
`after{Complete,Cancel,Expire,Forfeit}(bytes32, TaskContextV2, SettlementAmounts, uint64 seq)` and
`afterAction(bytes32, TaskContextV2, uint8 action, bytes actionData, uint64 seq)`.
`hookCallRoles()` and `onCall` serve bit 30 (above). `BaseTMPHookV2` is a base that allows every
before-callback, ignores every after-callback and refuses calls.

The diamond side is `ITMPHooksV2`:

- Views: `getTaskHooksV2(bytes32)`, `getTaskHookVersion(bytes32)`, `getTaskSettlement(bytes32)`,
  `getDefaultHooksV2()`, `hookCapabilityGas(uint8)`, `maxHookFeeBps()` and
  `hookCallSeq(bytes32,uint8)`.
- Owner functions: `setDefaultHooksV2(address[])`, `setHookCapabilityGas(uint8,uint256)` and
  `setMaxHookFeeBps(uint16)`.
- `withActionData(bytes,bytes)`, `callTaskHook(bytes32,address,bytes)` and the view
  `taskCallerRoles(bytes32,address)`.

New errors: `HookV1Retired`, `HookIncompatible(uint8,uint8)`, `MultipleTransformingHooks`,
`HookCodeChanged(uint8)`, `HookResultInvalid(uint8)`, `HookRejected(uint8,uint8,bytes)`,
`InsufficientGasForHooks`, `TooManyDefaultHooks`, `HookCapabilityGasOutOfRange`,
`MaxHookFeeBpsOutOfRange`, `ActionDataTooLong`, `ActionDataCallFailed`, `HookNotAttached`,
`HookCallNotDeclared`, `HookCallRoleRefused(uint32)`, `TaskAlreadySettled`.

New events: `HookAttached`, `HookActionData`, `HookCallFailedV2`, `TaskSettled`, `DefaultHooksV2Set`,
`HookCapabilityGasSet`, `MaxHookFeeBpsSet`, `HookSettlementApplied`, `TaskHookCalled`.

## The payout gate hook

`PayoutGateHook` (`src/hooks/payout-gate/PayoutGateHook.sol`) is one shared V2 hook per chain. It
holds a task's payout until another task, the gating task, has paid out, so workflows compose (A
blocks B, B blocks C). A human sign-off is modelled as a gating task; the gate has no approver.

- Capabilities: bit 0 (`beforeCreate`), bit 13 (`beforeAccept`) and bit 30 (calls, accepting
  `REQUESTER` only), `0x40002001`. It is check only and has no result power.
- Configuration: `abi.encode(bytes32 gatingTaskId, uint64 deadline, bytes32[] gatesTaskIds)`, fixed
  at creation. The task's mode depends on `gatesTaskIds`:
  - **Gated task** (`gatesTaskIds` empty). The gate holds this task's payout.
    - A zero `gatingTaskId` means the gating task is linked later.
    - The deadline must be between creation + 1 hour and creation + 180 days.
    - A nonzero `gatingTaskId` must be an existing task other than the gated one.
  - **Gating task** (`gatesTaskIds` lists 1 to 16 tasks, `gatingTaskId` and `deadline` both zero).
    The new task becomes the gating task of every listed task, linked automatically at creation.
    Each listed task must satisfy all of these:
    - it carries this gate;
    - it has no gating task yet;
    - it has not settled;
    - it has the same requester as the new task.

    Otherwise creation reverts. A stranger's task can therefore never open someone else's gate. The
    gating task holds nothing itself. This mode is how a workflow creates its review task after its
    bounties: the runner need not make a later call.
- A late link is a hook call: `callTaskHook(taskId, gate, abi.encode(bytes32 gatingTaskId))`,
  relayed like any requester action. A gate-specific diamond function, a gate that trusts the
  forwarder (a forged link could point it at an attacker's own task and skip the review) and a
  public function on the gate (unreachable through the relay) were rejected. The rules:
  - Only the gated task's requester (the diamond's role check, then `onCall` checks the flag and
    that the caller is the task's requester).
  - The gating task must have the same requester as the gated task, as at creation, so a forged
    or mistaken link can only point at the requester's own task.
  - It can be called only once, and only when no gating task was set at creation.
  - It is allowed only while the gated task has not settled (not Accepted, Expired or Cancelled).
  - It rejects a self-link and an unknown task.
  - It emits `PayoutGateLinked(taskId, gatingTaskId)`, as the automatic link does.
- `gateOf(bytes32 taskId) view returns (bytes32 gatingTaskId, uint64 deadline, bool gatingPaid, bool open)`.
- `isOpen(bytes32 taskId) view returns (bool)`.
- `PayoutGateSet(taskId, gatingTaskId, deadline)` is emitted at creation.
- `beforeAccept` allows the payout when any one of these holds:
  - the gating task's settlement record (`getTaskSettlement`) shows it ended `Accepted`;
  - the deadline has passed;
  - `ctx.currentState == Disputed`.

  Otherwise it reverts `PayoutGate__Closed`, which vetoes `acceptSubmission`, `acceptSubmissions`
  and `finalizeVerdict` before expiry.
- A gating task must not have settled when it is set or linked. A task that ended before the cut has
  no settlement record and could never open the gate.
- A gating task that is rejected, cancelled, expired or stuck never opens the gate. The deadline is
  the fallback, so funds cannot be trapped. The non-vetoable exits are never held, and a dispute
  ruling passes the gate.
- A cycle (A waits for B, B waits for A) opens only at the deadlines.

Errors:

- `PayoutGate__InvalidConfig`
- `PayoutGate__DeadlineOutOfWindow(deadline, earliest, latest)`
- `PayoutGate__AlreadySet`
- `PayoutGate__UnknownTask`
- `PayoutGate__NotRequester`
- `PayoutGate__AlreadyLinked`
- `PayoutGate__InvalidGatingTask`
- `PayoutGate__TaskSettled`
- `PayoutGate__RequesterMismatch`
- `PayoutGate__NotGated`
- `PayoutGate__Closed`

Do not deploy the gate on a chain until rev028 is live there.

## The V2 Sponsored Task hook

`SponsoredTaskHookV2` (`src/hooks/sponsored-task/SponsoredTaskHookV2.sol`) is the V2 port of
`SponsoredTaskHook`, deployed beside it. The V1 hook is unchanged and keeps serving tasks created
before the cut.

- The shared logic is the same: reservation, completion commitment, release, settlement and
  reconcile.
- Its configuration is the V1 hookData unchanged: `abi.encode(uint8 1, FundingRequest)`, also built
  by `encodeHookData`.
- Capabilities: `beforeCreate` (V1 `checkFund`), `beforeEvaluate` (`checkEvaluate`), `beforeAccept`
  (`checkComplete`), and `afterComplete`, `afterCancel`, `afterExpire` and `afterForfeit` (the V1
  `on*`).
- `afterComplete` carries no verdict, so a completion not yet committed is committed from the
  diamond's stored verdict or the single award. That is the lapsed-review settlement case.
- The terms hash still includes `getTaskHooks(taskId)`. For a V2 task this returns the attachment
  addresses in dispatch order: defaults first, then requester hooks.

## The V2 cross-chain Sponsored Task hook

`RemoteSponsoredTaskHookV2` (`src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol`) is the V2 port
of `RemoteSponsoredTaskHook`, deployed beside it behind its own proxy. It has the same logic, the V1
hookData as its configuration, and the same capabilities and V1 mapping as `SponsoredTaskHookV2`.
Remote vaults are bound to the settler, not to the hook, so existing remote vaults serve it
unchanged. A local vault for `SponsoredTaskHookV2` comes from a `SponsoredTaskFactoryV2` deployed
with that hook's address.

## The V2 reward hook

`TaskTokenRewardHookV2` (`src/hooks/TaskTokenRewardHookV2.sol`) is the V2 port of the DREAMS reward
hook `TaskTokenRewardHook`. It is UUPS, behind its own proxy, and deployed beside the V1 hook, which
is unchanged.

- The reward logic is the same.
- Its configuration is empty bytes, as in V1: all configuration lives on the hook.
- Capabilities and the V1 callbacks they map to:

  | Capability             | V1 callback         |
  | ---------------------- | ------------------- |
  | `beforeCreate`         | `checkFund`         |
  | `beforeClaim`          | `checkClaim`        |
  | `beforeSelectWorker`   | `checkSelectWorker` |
  | `beforeAcceptAuction`  | `checkSelectWorker` |
  | `beforeSubmitWork`     | `checkSubmit`       |
  | `beforeAccept`         | `checkComplete`     |
  | `afterComplete`        | `onComplete`        |
  | `afterCancel`          | `onCancel`          |
  | `afterExpire`          | `onExpire`          |
  | `afterForfeit`         | `onForfeit`         |

- Its vault and epoch budget must name it as their hook.
- V1 `defaultHooks` are not applied to new tasks. To keep the reward hook on every new task, the
  owner sets it with `setDefaultHooksV2`.

## Upgrade

`Rev028Upgrade` runs four cuts, each well under Tempo's per-transaction gas cap. One 13-facet cut
needed about 29.5M of the 29.9M cap. The facet CREATEs are separate transactions.

| Cut | Contents |
| --- | --- |
| `cutOne` | Adds `HookDispatchFacet` and `HooksV2Facet`; Replaces Core and Worker |
| `cutTwo` | Replaces Auction, Settlement, Evaluator, Acceptance and Rating |
| `cutThree` | Replaces Project and Registry (Registry takes over the settlement views) |
| `cutFour` | Replaces Admin and Feedback |

- Every facet but Cut and Loupe is replaced, and every existing selector keeps its signature.
- To keep `SettlementFacet` well under the contract size limit, its seven views (`getTaskTerms`,
  `getTaskClock`, `termsBounds`, `getReservation`, `isSettling`, `MAX_SUBMISSION_WINNERS`,
  `reviewDeadline`) move to `RegistryFacet`, and `settleLapsedReview` moves to `AcceptanceFacet`.
  Their selectors are unchanged.
- The diamond is consistent after each cut. Replaced facets reach the dispatch facet added first;
  facets not yet replaced, and the moved views, keep running rev027 code.
- The version is set to 28 only after the fourth cut, so new tasks keep V1 hooks until then.
- The diamond is paused before the first cut and unpaused after the version bump, so no task moves
  while facets from both revisions serve it.
- The script is resumable. It detects the cuts already on the diamond and sends only the missing
  ones:
  - `cutOne`: the dispatch facet is routed.
  - `cutTwo`: `settleLapsedReview` is on AcceptanceFacet.
  - `cutThree`: the settlement views are on RegistryFacet.
  - `cutFour`: replace only, so it is resent unless the version is already 28.

  A rerun on a diamond that a failed run left paused unpauses it after the bump, unless
  `FORGE_KEEP_PAUSED=true`. Run it the usual way: `make upgrade <chain> rev028`.
- No initializer runs. `defaultHooksV2` starts empty, so V2 launches with no protocol default hook.
  The rollout sets none. In particular, the DREAMS reward hook is not a default in this revision, and
  nothing in rev028 depends on it.

CI checks that every contract fits EIP-170 (`make contract evm size-check`). A test estimates each
cut's Tempo gas from its new storage slots.

Verify on each chain by reading it: `facetAddress(bytes4)` for `hookAcceptV2` and for
`resolveDispute` returns the rev028 facets, and `diamondVersion()` returns 28.

## Deploying the V2 hooks

`script/DeployHooksV2.s.sol` holds one script per hook. Each refuses a diamond below rev028. The
Make targets follow the existing deploy pattern (chain ID, or `preview`; `DRY_RUN=1` simulates):

| Target | Script | Notes |
| --- | --- | --- |
| `deploy-payout-gate-hook` | `DeployPayoutGateHook` | Opt-in, one per chain |
| `deploy-sponsored-task-hook-v2` | `DeploySponsoredTaskHookV2` | Proxy plus a `SponsoredTaskFactoryV2` bound to it. It reuses the deployed registry and fee policy, and prints the `setFactory` call when the admin owns the registry |
| `deploy-remote-sponsored-task-hook-v2` | `DeployRemoteSponsoredTaskHookV2` | Proxy owned by the remote-hook admin |
| `deploy-reward-hook-v2` | `DeployRewardHookV2` | Base only, and not part of the rev028 rollout (DREAMS does not exist on Tempo). Proxy with its own vault and budget; not made a default |
| `set-default-hooks-v2` | `SetDefaultHooksV2` | Diamond owner. `FORGE_DEFAULT_HOOKS_V2` is a comma-separated list of at most two hooks. The rev028 rollout sets none |

## Known limits and trade-offs

- `checkComplete` (V1) and `beforeAccept` (V2) report `Disputed` on the dispute path while
  `onComplete` and `afterComplete` report `Accepted`. Hook authors must treat `Disputed` there as a
  settlement in progress.
- An upgradable hook behind a proxy keeps the same codehash across implementation upgrades. Only its
  declared policy describes that.
- Non-terminal after-callbacks have no record to reconcile against.
- Redirect and separately funded value are reserved, not specified.
- The settlement record costs one more storage write per terminal transition. Hook dispatch adds one
  internal call per hooked action.

## Verification

Covered by `test/TaskHookV2.t.sol` and `test/Rev028Upgrade.t.sol`:

- V2 attach and its rejections.
- Veto and allow on the vetoable actions.
- The non-vetoable exits with hooks that revert.
- Composition limits.
- Settlement results, both valid and invalid.
- The settlement record and callback amounts on terminal paths.
- Sequence numbers.
- The dispute context on V1 and V2.
- The payout gate end to end.
- The upgrade, with a pre-cut V1 task keeping V1 dispatch.

## Security fixes in this release

Rev028 also carries the fixes from an external security review of the contracts. Each entry states
the rule and the reason. They are grouped by the area they touch.

### Expiry and time bounds

- **One rule for every expiry extension.** Reopen, reserved acceptance, evaluator review, revision
  request, appeal, `evaluate` and `submitWork` all raise `expiryTime` through one helper. A project
  task's expiry never exceeds the project end date plus the task grace period, and is not raised at
  all once the project's pool has settled. The step itself still happens and only the extension is
  clamped, because reverting an accept, appeal or reopen would strand escrow and workers. The one
  exception is `requestRevision`: it reverts `RevisionsExhausted` when the revision window would run
  past the clamped expiry, because the worker could not deliver the revision before the task expires.
  `updateTask` keeps its explicit revert.
- **Task duration is capped at one year at creation.** Every later addition to `expiryTime` is a
  bounded window (review, appeal, reopen, resolution), so the sums built from it cannot overflow and
  freeze settlement.
- **`appealWindow` has an upper bound,** the `termsBounds` maximum window (30 days by default).
  Without it an evaluator verdict could hold escrow in `Appealing` for years.
- **An auction's bid deadline must be before the task's expiry,** at creation and when the task is
  updated. Bidding past expiry cannot select a winner.

### Deliverables

- **A zero deliverable hash is rejected** in `submitWork`. A zero hash on a revision resubmission
  erased the delivery and reset the review clock, and the settlement guards read a zero hash as
  undelivered.

### Documentation corrections

Interface and NatSpec text now matches the code for `acceptSubmissions` (duplicate winners are
rejected), `assignEvaluator` (the stake arrives with the forwarded payment, there is no `transferFrom`
pull), `claimTo` (nonces are sequential per worker and an out-of-order relay reverts), `finalizeVerdict`
(a REJECT pays the evaluator fee, refunds the requester and cancels terminally), the review library
comments, and the forwarder's replay key (it includes `validBefore`; the relayer must keep nonces unique
per operation). The rev026 reconciliation procedure is written into the rev026 spec.

### Deploy scripts

- The sponsored-task guard timelock deploy script treats an unset or zero `TIMELOCK_ADMIN` as no
  standing admin, rejects the deployer as admin, logs the admin, and verifies the role assignments
  after deployment.
- The sponsored-task, payout and reward hooks deployed by the scripts range-check basis-point and
  small-integer settings at full width before narrowing them, so an out-of-range value reverts instead of
  wrapping into range. A remote hook deploy refuses a diamond address with no code.

### Evaluator stake, hooks and settlement

- **An evaluator that never had a deliverable to act on gets its stake back.** When a task expires with
  nothing delivered (Claim, Pitch, Auction, Bounty or Benchmark, claimed or not), the evaluator stake
  returns to the requester, as it already did when a reservation lapsed. Forfeiture to the fee recipient
  stays for a delivered task whose evaluator failed to act, through `evaluatorTimeout`. Forfeiting a
  stake from a party that could not have acted punishes the wrong side.
- **A hook cannot overrule a dispute resolution.** A V2 task's `beforeAccept` is best effort on a
  resolution. A legacy V1 task's check hooks are still shown the `Disputed` state on a resolution, so a
  gate can release it, but their rejection no longer blocks the ruling. Otherwise the party the
  worker is escaping from could decide the dispute.
- **A task whose hooks can veto delivery cannot forbid release.** `releaseClaim` ignores
  `ReleaseAllowed.Disallowed` when a V1 hook is attached (every V1 hook has `checkSubmit`) or a V2 hook
  declares the `beforeSubmitWork` capability. Without a veto power over delivery the term holds. The
  worker could otherwise neither deliver nor leave and would forfeit the stake at expiry.
- **Expiry refunds never depend on hook gas.** V2 exit callbacks are skipped with a failure event when
  a full stipend is not left. A V1 task's expiry callbacks behave the same way after the first hook,
  which is guaranteed one full stipend. A permissionless caller can therefore cause later exit hooks to
  be skipped by supplying little gas, so hooks must reconcile from the settlement record.
- **The sponsored-task hooks check the award count first.** An oversized verdict releases the
  sponsorship (or marks it unsettleable) before the payout pool is read, so it cannot spend the hook's
  gas stipend first.

### Funding pool

- **A refund leaves outstanding in the same call that books it as available.** Hooks run before the
  escrow release, so a refund left in both would be seen twice and shares priced against the doubled
  value. When the refund includes money that was never drawn from the pool (a forfeited worker stake),
  outstanding reads low until release; the total over the task's life is correct.
- **Direct `FundingPool.fund` reverts while the diamond is settling.** Payouts to workers also leave
  outstanding only at release, so shares priced inside a settlement hook use a stale value. The
  diamond's own `creditFunding` and `creditOpening` are unaffected.
- **Dust resets the share generation.** The pool starts a new generation when its value is zero or the
  supply per unit of value passes 1e30, so a pool drained to one base unit cannot make the next mint
  overflow and block funding. The dust stays in the pool.

### Sponsored tasks and the reward hook

- **A project task charges the allowance of whoever created it,** not the requester of record. The
  creator is recorded for the predicted task id before the hooks run. The requester of record is kept
  separately for the callbacks.
- **The sponsorship commitment covers the settlement policy.** The terms hash is two hashes combined:
  the task terms and the settlement terms (penalty destination, review, decision, resolution and accept
  windows, release and revision terms, reject outcome and fee).
- **The remote reserve is signed over the vault id,** and the settler requires the vault's own id to
  match. The settler accepts only vaults its registry lists. An owner can reopen a revoked settle digest;
  settlement still needs the settler threshold of signatures.
- **A verdict finalized after expiry skips `checkComplete`,** so `reconcile` commits a stored evaluator
  verdict for any mode.
- **The DREAMS emission cap is per task and cumulative.** `EpochBudget` checks a running total per task
  id, so a task with several winners cannot emit more than the cap. A reservation records the vault and
  budget it was made on, so replacing either cannot retarget an outstanding release. `setVault` requires
  a vault that pays the hook's token. A bonus that converts to zero tokens reserves nothing and
  consumes no budget, in the reservation and in both bounty loops.
- **Hook upgrade authority moves in two steps and cannot be renounced.** Vault owner signatures can be
  cancelled up to a chosen nonce, within a bounded jump. The forwarder checks at construction that its
  destination has code and that the diamond escrows its token.

### Facets and entrypoints

- **An evaluator is a term of a reservation.** `assignEvaluator` reverts while a reservation is pending.
  A worker whose stake is forfeited is barred from the task, as after a release or a rejection.
- **Acting parties cannot deal with themselves.** On a project task the requester of record, the
  operator and the owner cannot be the evaluator, the dispute resolver, the reserved worker, or the
  worker through claim, selection, bid or submit. Delegated acceptance credits the requester of record and
  flags an award to any acting party as a self-award.
- **A worker named several times in one verdict completes the task once,** on the evaluator path and for
  hook-transformed awards.
- **A relayed call that books nothing must carry no payment.** Every relayed non-funding entrypoint,
  `callTaskHook` included, and the permissionless ones when relayed, reject a nonzero forwarder payment.
  The diamond refuses native ETH.
- **Updating a task keeps its bounds.** An expiry set by `updateTask` is held to the same one-year cap
  as at creation, and an auction's bid deadline stays before its expiry.
- **Grants are forwarder-only,** and `acceptGrant` takes the hash of the grant terms the operator read,
  so terms the owner replaces afterwards cannot be accepted by mistake. Its selector changed, so the
  upgrade adds the new selector and removes the old one.
- **Stake terms apply only to Claim tasks,** the only mode that collects a worker stake.
- **`diamondCut` with init calldata and no init address reverts,** and `selectWorker` rejects the zero
  address. The claim release grace boundary is computed without multiplying the raw span.
