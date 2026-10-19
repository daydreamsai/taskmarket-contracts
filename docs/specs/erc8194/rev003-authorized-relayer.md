# ERC-8194 Revision 003 — relay() Restricted to the Authorized Relayer

**Revision:** 003
**Date:** 2026-03-17
**Pairs with:** ERC-8195 baseline draft (before rev001)

## Motivation

In rev001 and rev002 anyone could call `relay()`. The forwarder pulls the payment from
`msg.sender`, so a caller paid for its own relay, but the caller also chose `pgtrSenderAddr`
freely. Any address could therefore act on TaskMarket as any other address, paying only the
operation's price. This revision binds `relay()` to one immutable relayer address, the relay
server that verifies the X402 payment off-chain before relaying.

---

## Problem 1 — Anyone could choose the acting principal

```solidity
function relay(address pgtrSenderAddr, uint256 paymentAmount, ...) external nonReentrant {
    if (block.timestamp > validBefore) revert ReceiptExpired();
    // no check on msg.sender
```

TaskMarket trusts the forwarder's `pgtrSender()`. Since the caller supplied it, a stranger could
call `submitWork`, `cancelTask` or `acceptSubmission` (which carry no payment) as the worker or
requester of any task. The receipt hash prevents replay of a receipt, not the forging of a new one.

---

## Changes

### Change 1 — Immutable authorized relayer

Before:

```solidity
constructor(address _usdc, address _taskMarket) {
```

After:

```solidity
address public immutable authorizedRelayer;
error UnauthorizedRelayer();

constructor(address _usdc, address _taskMarket, address _authorizedRelayer) {
    require(_authorizedRelayer != address(0), "Invalid relayer address");
    // ...
    authorizedRelayer = _authorizedRelayer;
}
```

### Change 2 — Check the caller first

Before:

```solidity
) external nonReentrant {
    if (block.timestamp > validBefore) revert ReceiptExpired();
```

After:

```solidity
) external nonReentrant {
    if (msg.sender != authorizedRelayer) revert UnauthorizedRelayer();
    if (block.timestamp > validBefore) revert ReceiptExpired();
```

---

## Rationale

### Why not verify a payer signature on-chain?

The point of PGTR is that the principal needs no private key; payment is the authorization. The
relay server verifies the payment, so the forwarder trusts the relay server, not a signature.

### Why not an owner-managed set of relayers?

A mutable set adds an owner key that can add a relayer and act as anyone. An immutable address
keeps the forwarder free of admin state; rotating the relayer means deploying a new forwarder.

---

## API Changes

- Constructor gains `address authorizedRelayer`; deployment scripts pass the relay server address.
- New public getter `authorizedRelayer()`.
- `relay()` reverts `UnauthorizedRelayer()` for any other caller.

---

## ERC-8195 Pairing

None directly; before ERC-8195 rev001. The destination's trust in `pgtrSender()` from rev001
depends on this check to mean anything.

---

## Affected Files

| File | Change |
|------|--------|
| `packages/contracts/src/TaskMarketForwarder.sol` | `authorizedRelayer`, `UnauthorizedRelayer`, caller check |
| `packages/contracts/test/TaskMarketForwarder.t.sol` | Constructor argument; unauthorized-caller test |
