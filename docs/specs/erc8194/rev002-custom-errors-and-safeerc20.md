# ERC-8194 Revision 002 — Custom Errors and SafeERC20 in relay()

**Revision:** 002
**Date:** 2026-03-17
**Pairs with:** ERC-8195 baseline draft (before rev001)

## Motivation

The rev001 forwarder declared custom errors for expiry and replay but reverted with strings, and it
moved the payment with a bare `transferFrom` wrapped in `require`. Relayers could not decode the
failure reason reliably, and the payment path assumed every token returns `bool`. This revision
makes `relay()` revert with its declared errors and moves the payment through OpenZeppelin
`SafeERC20`.

---

## Problem 1 — String reverts in relay()

`relay()` reverted with `"Receipt expired"` and `"Receipt already consumed"` while
`ReceiptExpired` and `ReceiptAlreadyConsumed` were declared and unused. A relayer had to match
strings, and the declared errors in the ABI were misleading.

## Problem 2 — Unchecked token return shapes

```solidity
require(usdc.transferFrom(msg.sender, taskMarket, paymentAmount), "USDC transfer failed");
```

A token that returns nothing on success makes the `require` decode fail, and a token that returns
`false` without reverting is only caught by the string `require`. The forwarder's payment
guarantee depended on the token's return convention.

---

## Changes

### Change 1 — Custom errors for expiry and replay

Before:

```solidity
require(block.timestamp <= validBefore, "Receipt expired");
require(!consumedReceipts[receiptHash], "Receipt already consumed");
```

After:

```solidity
if (block.timestamp > validBefore) revert ReceiptExpired();
if (consumedReceipts[receiptHash]) revert ReceiptAlreadyConsumed();
```

### Change 2 — SafeERC20

Before:

```solidity
require(usdc.transferFrom(msg.sender, taskMarket, paymentAmount), "USDC transfer failed");
```

After:

```solidity
using SafeERC20 for IERC20;
usdc.safeTransferFrom(msg.sender, taskMarket, paymentAmount);
```

---

## Rationale

### Why not keep the strings for readability?

The errors were already declared. Custom errors are cheaper, have stable selectors a relayer can
match, and the strings duplicated them.

### Why not rely on USDC returning `bool`?

USDC does, but the forwarder takes its token as a constructor argument. `SafeERC20` costs little
and keeps the atomic payment guarantee independent of the token's return convention.

---

## API Changes

- `relay()` reverts `ReceiptExpired()` and `ReceiptAlreadyConsumed()` instead of string reasons.
- A failed payment reverts with the token's own error or `SafeERC20FailedOperation(address)`
  instead of `"USDC transfer failed"`.

---

## ERC-8195 Pairing

None directly. Made the same day as rev001, before ERC-8195 rev001. ERC-8195 rev004 later made the
same string-to-custom-error change in the destination.

---

## Affected Files

| File | Change |
|------|--------|
| `packages/contracts/src/TaskMarketForwarder.sol` | Custom errors in `relay()`; `SafeERC20` payment |
| `packages/contracts/test/TaskMarketForwarder.t.sol` | Expect the custom errors |
