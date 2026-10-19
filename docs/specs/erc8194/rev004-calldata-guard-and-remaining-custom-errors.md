# ERC-8194 Revision 004 — Calldata Length Guard and Remaining Custom Errors

**Revision:** 004
**Date:** 2026-05-25
**Pairs with:** ERC-8195 rev004

## Motivation

`relay()` read the selector with `bytes4(data[:4])` without checking the length, so calldata
shorter than four bytes failed with a slice panic rather than a meaningful error. The first fix
added a string revert. The constructor's zero-address checks and `pgtrSender()` outside a call
also still reverted with strings. When ERC-8195 rev004 moved the destination to custom errors, the
forwarder followed: every revert it raises is now a custom error.

---

## Problem 1 — Short calldata panicked

```solidity
bytes4 selector = bytes4(data[:4]);
```

With `data.length < 4` the slice is out of bounds and the call reverts with a panic, which a
relayer cannot tell apart from other low-level failures.

## Problem 2 — Remaining string reverts

The constructor reverted `"Invalid USDC address"`, `"Invalid TaskMarket address"` and
`"Invalid relayer address"`, and `pgtrSender()` reverted `"No active forwarded call"`.

---

## Changes

### Change 1 — Guard the selector read

Before:

```solidity
if (block.timestamp > validBefore) revert ReceiptExpired();

bytes4 selector = bytes4(data[:4]);
```

After:

```solidity
if (block.timestamp > validBefore) revert ReceiptExpired();
if (data.length < 4) revert CalldataTooShort();

bytes4 selector = bytes4(data[:4]);
```

(Added first as `revert("Calldata too short")`, then converted to the custom error.)

### Change 2 — Custom errors everywhere

Before:

```solidity
require(_usdc != address(0), "Invalid USDC address");
require(_pgtrSenderStorage != address(0), "No active forwarded call");
```

After:

```solidity
error InvalidAddress();
error NoActiveForwardedCall();
error CalldataTooShort();

if (_usdc == address(0)) revert InvalidAddress();
if (_pgtrSenderStorage == address(0)) revert NoActiveForwardedCall();
```

The same `InvalidAddress` covers the TaskMarket and relayer arguments.

---

## Rationale

### Why not one error per constructor argument?

Construction failures happen once, at deployment, where the failing argument is obvious from the
script. One error keeps the ABI small.

### Why reject short calldata at all?

No destination function has an empty selector; a relay that cannot name a function is a relayer
bug, and failing with a named error before consuming the receipt makes it diagnosable.

---

## API Changes

- `relay()` reverts `CalldataTooShort()` for calldata under four bytes.
- The constructor reverts `InvalidAddress()`; `pgtrSender()` reverts `NoActiveForwardedCall()`.

---

## ERC-8195 Pairing

ERC-8195 rev004 (custom errors, Pausable, Ownable2Step). The forwarder's remaining string reverts
were converted in the review of that revision.

---

## Affected Files

| File | Change |
|------|--------|
| `packages/contracts/src/TaskMarketForwarder.sol` | `CalldataTooShort` guard; `InvalidAddress`, `NoActiveForwardedCall` |
| `packages/contracts/test/TaskMarketForwarder.t.sol` | Expect the custom errors |
