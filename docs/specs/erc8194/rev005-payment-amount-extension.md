# ERC-8194 Revision 005 — Payment Amount Extension (IPGTRPaymentForwarder)

**Revision:** 005
**Date:** 2026-10-16
**Pairs with:** ERC-8195 rev025

## Motivation

`IPGTRForwarder` tells a destination who is acting (`pgtrSender()`) but not what was paid. The
forwarder pulls `paymentAmount` into the destination before calling it, yet the destination cannot
see that amount, so any value it records from calldata (a claim stake, a reward, an evaluator
stake) is taken on trust. ERC-8195 rev025 enforces claim stakes and exact funding, which needs the
paid amount on-chain. This revision adds an optional extension interface,
`IPGTRPaymentForwarder`, with one view, `pgtrPaymentAmount()`, and a new reference forwarder,
`TaskMarketForwarderV2`, that implements it.

---

## Problem 1 — The destination could not see the payment

`claimTask(taskId, stakeAmount)` recorded `stakeAmount` from calldata. Nothing tied it to the USDC
the forwarder had moved, so a relayed claim could record a stake that was never paid, and a later
forfeit or release would pay out escrow belonging to other tasks. `createTask`, `assignEvaluator`
and `updateTask` had the same gap for the reward and evaluator stake: the market could only check
the pooled escrow balance, which other tasks' funds can satisfy.

## Problem 2 — The v1 forwarder cannot be extended in place

`TaskMarketForwarder` has no proxy and immutable `usdc`, `taskMarket` and `authorizedRelayer`.
Adding a view requires a new deployment beside it.

---

## Changes

### Change 1 — New interface `IPGTRPaymentForwarder`

Before: no interface reported the payment.

After:

```solidity
interface IPGTRPaymentForwarder is IPGTRForwarder {
    /// @notice USDC amount (6 decimals) the forwarder transferred to the destination for the
    ///         current forwarded call. MUST be set before the destination is called and reset
    ///         after it returns.
    function pgtrPaymentAmount() external view returns (uint256);
}
```

ERC-165 interface id. Solidity's `type(I).interfaceId` XORs only the functions declared in `I`,
not inherited ones, so:

| Interface | Functions | Interface id |
|-----------|-----------|--------------|
| `IPGTRPaymentForwarder` | `pgtrPaymentAmount()` = `0x03c78881` | `0x03c78881` |
| `IPGTRForwarder` | `isPGTRForwarder()` = `0xe1b0c012`, `pgtrSender()` = `0x72e774dc`, `isTrustedForwarder(address)` = `0x572b6c05` | `0xc47cd8cb` |

A conforming forwarder returns true from `supportsInterface` for both ids and for `IERC165`
(`0x01ffc9a7`). `TaskMarketForwarderV2` does; `TaskMarketForwarder` returns false for
`0x03c78881`.

### Change 2 — `TaskMarketForwarderV2` stores the amount for the call

Before (`TaskMarketForwarder.relay`):

```solidity
_pgtrSenderStorage = pgtrSenderAddr;
(bool success, bytes memory result) = taskMarket.call(data);
_pgtrSenderStorage = address(0);
```

After (`TaskMarketForwarderV2.relay`):

```solidity
if (paymentAmount > 0) {
    usdc.safeTransferFrom(msg.sender, taskMarket, paymentAmount);
}

_pgtrSenderStorage = pgtrSenderAddr;
_pgtrPaymentAmountStorage = paymentAmount;
(bool success, bytes memory result) = taskMarket.call(data);
_pgtrSenderStorage = address(0);
_pgtrPaymentAmountStorage = 0;
```

```solidity
function pgtrPaymentAmount() external view override returns (uint256) {
    if (_pgtrSenderStorage == address(0)) revert NoActiveForwardedCall();
    return _pgtrPaymentAmountStorage;
}
```

Semantics, as implemented:

- **Scope.** The value is set immediately before the destination call and reset to zero
  immediately after it, in the same frame as `pgtrSender()`. Outside a relayed call
  `pgtrPaymentAmount()` reverts `NoActiveForwardedCall`, exactly like `pgtrSender()`. `relay()` is
  `nonReentrant`, so a nested relay cannot overwrite it mid-call.
- **Value.** It is the `paymentAmount` argument of the current `relay()`, which is the amount the
  forwarder moved with `safeTransferFrom(relayer, taskMarket, paymentAmount)` in the same call
  (nothing is moved when it is zero). `safeTransferFrom` reverts on failure, so the reported amount
  is always one that arrived. The amount is also part of the consumed receipt hash.
- Everything else in `relay()` (relayer check, expiry, calldata guard, receipt hash, revert
  bubbling, `PaymentGatedCall`) is unchanged from rev004.

### Change 3 — How a destination checks it (ERC-8195 rev025)

The destination calls `pgtrPaymentAmount()` on `msg.sender` inside a `try`, after the
trusted-forwarder check:

```solidity
function _forwardedPayment() internal view returns (bool reported, uint256 paid) {
    try IPGTRPaymentForwarder(msg.sender).pgtrPaymentAmount() returns (uint256 amount) {
        return (true, amount);
    } catch {
        return (false, 0);
    }
}
```

- **`StakePaymentMismatch`** (`claimTask`): with a reporting forwarder, the payment must equal
  `stakeAmount`. With a forwarder that cannot report, only `stakeAmount == 0` is accepted. A
  stake below the task's `stakeBps` minimum also reverts `StakePaymentMismatch`.
- **`ForwardedPaymentMismatch`** (`createTask`, `assignEvaluator`, `updateTask`): with a
  reporting forwarder, the payment must equal exactly what the call escrows: `reward +
  evaluatorStake`, `evaluatorStake`, or the reward increase (zero when it does not increase).
  With a forwarder that cannot report, no exact check is made and the pre-rev025 path applies
  (evaluator stake pulled from the requester; reward increase checked against the escrow balance).

### Change 4 — Deployment beside v1

`DeployForwarderV2.s.sol` deploys `TaskMarketForwarderV2` with the same constructor as v1. The
destination trusts both between `addForwarder(v2)` and `removeForwarder(v1)`.

---

## Rationale

### Why an extension interface instead of adding the view to `IPGTRForwarder`?

Changing `IPGTRForwarder` would change its interface id and make every deployed forwarder
non-conforming. An extension leaves existing forwarders valid and lets a destination detect the
capability by ERC-165 or by a `try` call.

### Why not pass the amount in calldata to the destination?

The relayer builds the calldata, so a calldata amount is a claim, not a proof. The forwarder's
stored value is the amount it actually transferred in the same call.

### Why exact equality instead of "at least"?

An overpayment would sit in pooled escrow without belonging to any task. Equality means the market
never records escrow it did not receive and never keeps money the payer did not intend to give.

### Why a forwarder without the extension is accepted at all

During migration the destination trusts v1 and v2 together. Accepting v1 only where no payment
check applies (a zero-stake claim, and the pre-rev025 funding paths) keeps unstaked relays working
until the relay server switches to v2, without ever recording an unverified stake.

### Why v1 must not stay trusted on a rev025 diamond

A v1 forwarder reports no amount, so every call it relays skips `ForwardedPaymentMismatch`:
`createTask` trusts it to have funded the reward, `updateTask` falls back to the pooled balance
check, and evaluator stakes go back to `transferFrom` from the requester. Leaving v1 trusted keeps
open exactly the unverified-funding path rev025 closes, and any stake-required claim relayed
through it reverts. v1 is trusted only for the migration window and removed with
`removeForwarder` once the relay server uses v2.

### Why not upgrade v1 in place?

It has no proxy and immutable configuration by design (rev001). A new deployment is the upgrade
path.

---

## API Changes

- New interface `IPGTRPaymentForwarder` (interface id `0x03c78881`) extending `IPGTRForwarder`
  (`0xc47cd8cb`).
- New contract `TaskMarketForwarderV2(address usdc, address taskMarket, address authorizedRelayer)`
  with `pgtrPaymentAmount()`; `relay()` signature, errors and events are unchanged.
- Destination errors introduced by ERC-8195 rev025: `StakePaymentMismatch`,
  `ForwardedPaymentMismatch`.

---

## ERC-8195 Pairing

ERC-8195 rev025 (settlement terms, review window and claim release). Deployment order from rev025:
the relay server funds claim stakes through the relayer, then v2 is deployed and added with
`addForwarder`, the relay server switches to it, the diamond is cut, and v1 is removed with
`removeForwarder`.

---

## Affected Files

| File | Change |
|------|--------|
| `packages/contracts/src/interfaces/IPGTRPaymentForwarder.sol` | New extension interface |
| `packages/contracts/src/TaskMarketForwarderV2.sol` | New forwarder reporting `pgtrPaymentAmount()` |
| `packages/contracts/script/DeployForwarderV2.s.sol` | New deployment script |
| `packages/contracts/src/libraries/LibGuards.sol` | `_forwardedPayment`, `_requireReportedPayment`, `_requireStakePayment` |
| `packages/contracts/src/facets/CoreFacet.sol` | Payment checks in `claimTask`, `createTask`, `updateTask` |
| `packages/contracts/src/libraries/LibTaskMarket.sol` | Evaluator-stake payment check shared by `createTask` and `assignEvaluator` |
| `packages/contracts/test/TaskMarketForwarderV2.t.sol` | New forwarder and interface-id tests |
| `packages/contracts/test/mocks/MockPGTRForwarder.sol` | Mock reports a payment amount |
