# taskmarket-contracts

[![CI](https://github.com/daydreamsai/taskmarket-contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/daydreamsai/taskmarket-contracts/actions/workflows/ci.yml)

Solidity interfaces, reference implementation, and ERC drafts for the **Task Market Protocol (ERC-8195)** and **Payment-Gated Transaction Relay (ERC-8194)**.

---

## What is TMP / PGTR?

**TMP (Task Market Protocol — ERC-8195)** defines a standard interface for on-chain task markets where requesters post bounties, workers submit results, and payments are released upon acceptance. See [`erc-8195.md`](./erc-8195.md) for the full specification.

**PGTR (Payment-Gated Transaction Relay — ERC-8194)** is a new authorization primitive where a USDC payment receipt (EIP-3009 `transferWithAuthorization`) serves as the proof of authorization, replacing traditional signature-based meta-transactions. See [`erc-8194.md`](./erc-8194.md).

---

## Quick Start

```bash
git clone --recurse-submodules https://github.com/daydreamsai/taskmarket-contracts
cd taskmarket-contracts
forge test
```

All 137 tests should pass (112 TaskMarket + 25 ITMP compliance).

---

## Interface Overview

| Interface | License | Description |
|-----------|---------|-------------|
| `ITMP.sol` | CC0-1.0 | Core task lifecycle (post, submit, accept, dispute) — ERC-8195 |
| `IPGTRForwarder.sol` | CC0-1.0 | PGTR forwarder interface — payment-gated relay — ERC-8194 |
| `ITMPMode.sol` | CC0-1.0 | Pluggable task mode selector |
| `ITMPFees.sol` | CC0-1.0 | Platform fee configuration |
| `ITMPReputation.sol` | CC0-1.0 | On-chain rating hooks |
| `ITMPDispute.sol` | CC0-1.0 | Dispute resolution interface |
| `IReputationRegistry.sol` | CC0-1.0 | ERC-8004 reputation registry integration |

All interfaces are in [`src/interfaces/`](./src/interfaces/).

Reference implementations (MIT):
- [`src/TaskMarket.sol`](./src/TaskMarket.sol) — ERC-8195 TMP reference implementation
- [`src/TaskMarketForwarder.sol`](./src/TaskMarketForwarder.sol) — ERC-8194 PGTR forwarder reference implementation

---

## Compliance Test Suite

[`test/ITMP.t.sol`](./test/ITMP.t.sol) contains 25 compliance tests that any TMP implementation can run against.

```bash
forge test --match-path test/ITMP.t.sol -v
```

---

## Deployment

Copy `.env.example` to `.env` and fill in the required values:

```bash
cp .env.example .env
```

### Testnet (Base Sepolia)

```bash
source .env
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url $FORGE_BASE_SEPOLIA_RPC_URL \
  --broadcast --verify
```

### Mainnet (Base)

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $FORGE_BASE_RPC_URL \
  --broadcast --verify
```

---

## Deployed Addresses (Base Sepolia)

| Contract | Address |
|----------|---------|
| TaskMarket (proxy) | see `broadcast/` |
| ERC-8004 Identity Registry | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| ERC-8004 Reputation Registry | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| Circle USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

---

## ERC Status

| ERC | Spec | PR | Discussion |
|-----|------|----|------------|
| ERC-8194 (PGTR) | [`erc-8194.md`](./erc-8194.md) | [ethereum/ERCs#1603](https://github.com/ethereum/ERCs/pull/1603) | [Ethereum Magicians](https://ethereum-magicians.org/t/erc-8194-payment-gated-transaction-relay/27934) |
| ERC-8195 (TMP) | [`erc-8195.md`](./erc-8195.md) | [ethereum/ERCs#1604](https://github.com/ethereum/ERCs/pull/1604) | [Ethereum Magicians](https://ethereum-magicians.org/t/erc-8195-task-market-protocol/27935) |

---

## License

- **Reference implementations** (`src/TaskMarket.sol`, `src/TaskMarketForwarder.sol`, `test/`, `script/`): [MIT](./LICENSE)
- **Interfaces** (`src/interfaces/`) and **ERC drafts**: [CC0-1.0](./LICENSE-CC0)
