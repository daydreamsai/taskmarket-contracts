# ERC-8194 Revision 001 — Initial PGTR Forwarder

**Revision:** 001
**Date:** 2026-03-17
**Pairs with:** ERC-8195 baseline draft (before rev001)

## Motivation

The first draft of the standard defined a forwarder interface, `ITMPForwarder`, named after the
TaskMarket Protocol it served, and no contract implemented it. TaskMarket attributed actions to
explicit calldata parameters supplied by the backend, so the contract had no on-chain link between
the payment that authorised an action and the address the action was recorded against. This
revision renames the interface to the standalone ERC-8194 `IPGTRForwarder` and adds the reference
forwarder, `TaskMarketForwarder`, which pulls the payment, sets the acting principal and calls the
destination in one transaction.

---

## Problem 1 — The interface was tied to one destination

`ITMPForwarder` described a generic payment-gated relay but carried the name of a single
destination protocol. A destination other than TaskMarket could not implement it without implying
it was a TaskMarket deployment, and the ERC-8194 draft could not be read on its own.

## Problem 2 — No forwarder existed

Destinations had no contract to trust. Actor attribution relied on calldata the backend chose, the
payment was a separate transfer with no atomic link to the call, and nothing stopped the same
payment being presented twice.

---

## Changes

### Change 1 — Rename the interface

Before:

```solidity
/// @title ITMPForwarder
/// @notice Payment-Gated Transaction Relay (PGTR) forwarder interface.
interface ITMPForwarder is IERC165 {
```

After:

```solidity
/// @title IPGTRForwarder
/// @notice Payment-Gated Transaction Relay (PGTR) forwarder interface (ERC-8194).
interface IPGTRForwarder is IERC165 {
```

The function set is unchanged: `isPGTRForwarder()`, `pgtrSender()`, `isTrustedForwarder(address)`
and the `PaymentGatedCall` event.

### Change 2 — Add `TaskMarketForwarder`

Before: no forwarder.

After:

```solidity
contract TaskMarketForwarder is IPGTRForwarder, ReentrancyGuard {
    IERC20 public immutable usdc;
    address public immutable taskMarket;
    address private _pgtrSenderStorage;
    mapping(bytes32 => bool) public consumedReceipts;

    function relay(
        address pgtrSenderAddr,
        uint256 paymentAmount,
        uint256 validBefore,
        bytes32 receiptNonce,
        bytes calldata data
    ) external nonReentrant {
        require(block.timestamp <= validBefore, "Receipt expired");
        bytes4 selector = bytes4(data[:4]);
        bytes32 receiptHash = keccak256(abi.encode(
            block.chainid, pgtrSenderAddr, paymentAmount, receiptNonce, validBefore, taskMarket, selector
        ));
        require(!consumedReceipts[receiptHash], "Receipt already consumed");
        consumedReceipts[receiptHash] = true;
        if (paymentAmount > 0) {
            require(usdc.transferFrom(msg.sender, taskMarket, paymentAmount), "USDC transfer failed");
        }
        _pgtrSenderStorage = pgtrSenderAddr;
        (bool success, bytes memory result) = taskMarket.call(data);
        _pgtrSenderStorage = address(0);
        // bubble up the revert, then emit PaymentGatedCall
    }
}
```

`pgtrSender()` reverts outside a relayed call, `isTrustedForwarder` returns true only for the
forwarder itself, and `supportsInterface` reports `IPGTRForwarder` and `IERC165`.

---

## Rationale

### Why not keep `ITMPForwarder`?

A TaskMarket-specific name would have tied every other destination to TaskMarket. The relay is
destination-agnostic, so the interface takes the name of its own standard.

### Why not pass the actor in calldata?

Appending or passing the actor lets whoever builds the calldata choose it. Reading `pgtrSender()`
from a forwarder the destination trusts binds the actor to the transaction that carried the
payment.

### Why include `block.chainid` and the selector in the receipt hash?

Without the chain id a receipt consumed on one chain could be replayed on another; without the
selector one receipt could authorise a different function on the same destination.

### Why immutable `usdc` and `taskMarket` with no proxy?

A forwarder that can change its destination or token is a larger trust surface than one that
cannot. A change is made by deploying a new forwarder and swapping it in the destination's
`trustedForwarders` set.

---

## API Changes

- `ITMPForwarder` is renamed `IPGTRForwarder`; the interface id is unchanged because the function
  set is unchanged.
- New contract `TaskMarketForwarder(address usdc, address taskMarket)` with
  `relay(address,uint256,uint256,bytes32,bytes)` and the public `consumedReceipts` mapping.
- New errors declared: `ReceiptAlreadyConsumed`, `ReceiptExpired`, `ReceiptNotYetValid`,
  `RelayFailed`. Only `RelayFailed` is used; the others are string reverts until rev002.

---

## ERC-8195 Pairing

Pairs with the ERC-8195 baseline draft, which predates ERC-8195 rev001. In the same change the
TaskMarket contract adopted the `trustedForwarders` mapping and `_effectiveSender()`, which reads
`IPGTRForwarder(msg.sender).pgtrSender()` for a trusted caller. ERC-8195 rev002 later made the core
standard authentication-agnostic, leaving PGTR as one supported mechanism.

---

## Affected Files

| File | Change |
|------|--------|
| `packages/contracts/evm/src/interfaces/IPGTRForwarder.sol` | Renamed from `ITMPForwarder.sol` |
| `packages/contracts/src/TaskMarketForwarder.sol` | New reference forwarder |
| `packages/contracts/test/TaskMarketForwarder.t.sol` | New forwarder tests |
| `packages/contracts/docs/specs/erc8194/erc-8194.md` | Renamed from the PGTR draft |
