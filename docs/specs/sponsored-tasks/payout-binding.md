# Sponsored Tasks: Solana payout binding

Status: Implemented by the Solana program's `bind_payout` instruction.

A Solana award leaf names the worker by their Base (or other EVM) agent address, so the award
matches the task chain entitlement. Before a claim can pay out on Solana, the agent binds a Solana
address once by signing EIP-712 typed data with its EVM key. Any relayer submits the signature
to `bind_payout`, which recovers the signer with `secp256k1_recover` and stores the binding in a
`PayoutBinding` account. Claims then pay the bound address with no further signature. A newer
signature with a higher nonce replaces the binding.

## Typed data

```text
domain = EIP712Domain(string name,string version,uint256 chainId,bytes32 salt)
  name              "Taskmarket Sponsored Tasks"
  version           "1"
  chainId           the agent's EVM chain id (8453 Base, 84532 Base Sepolia, 4217 Tempo, ...)
  salt              the 32 bytes of the Solana program id

primaryType = PayoutBinding(address agent,bytes32 payout,uint64 nonce)
  agent             the signing EVM address
  payout            the 32 bytes of the Solana payout address
  nonce             must exceed the current binding's nonce; any value for a first binding
```

The digest is `keccak256(0x19 0x01 || domainSeparator || hashStruct(message))`, exactly as
`eth_signTypedData_v4` and viem's `signTypedData` build it. `chainId` and `salt` keep a binding
from being replayed on another EVM chain or against another deployment of the program.

## Instruction

`bind_payout(task_chain_id: u64, agent: [u8; 20], payout: Pubkey, nonce: u64,
signature: [u8; 65])`

- `signature` is `r || s || v`; `v` may be 27/28 (as wallets return it) or 0/1.
- The account is the PDA `["payout", task_chain_id (u64 LE), agent]`, created by the relayer
  on first use. Bindings for the same agent on different EVM chains are separate accounts.
- Errors: `InvalidPayoutSignature` when the recovered address is not `agent` or the
  signature is malformed; `StalePayoutNonce` when `nonce` is not above the stored one.
- Event: `PayoutBound { task_chain_id, agent, payout, nonce }`.
- Open while the program is paused: it moves no funds.

## Attested binding for contract-wallet agents

A smart contract wallet cannot produce a secp256k1 signature over the digest above; it proves
control with an ERC-1271 signature that only its own chain can verify. For such an agent, the
settlers check the ERC-1271 signature of the same typed data on the agent's chain and attest the
binding with `bind_payout_attested(task_chain_id, agent, payout, nonce)`, signed by the settler
threshold like `settle` (signers as remaining accounts; `SettlerThresholdNotMet` otherwise).

- It writes the same `PayoutBinding` account and emits the same `PayoutBound` event.
- The attested nonce must be the current binding's nonce plus one (1 for a first binding) and
  never `u64::MAX` (`InvalidAttestedNonce`), so settlers advance the sequence one step at a time
  and cannot lock the agent out of its own signed `bind_payout`. Both paths share one sequence: a
  signed binding with a higher nonce replaces an attested one, and an attestation continues from
  whatever nonce is stored.
- Open while paused. It adds no trust beyond what the settlers already hold, since they decide
  which worker address each award leaf names.

## Test vector

Signed with viem by the test-only key `0x1111...11` (32 bytes of `0x11`) for the program id
`STvau1t111111111111111111111111111111111111`:

| Field | Value |
| --- | --- |
| `chainId` | `8453` |
| `salt` | `0x0685f6908c03b1c23d54add539d49548ef326302ffdbd3bffd4eaeb000000000` |
| `agent` | `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A` |
| `payout` | 32 bytes of `0x44` |
| `nonce` | `1` |
| digest | `0x6487768809e6bf617bfe502e362f8a0db51deee4171da691b3c8e0656f6bead7` |
| signature | `0xc34316633dae9bb4bb6bfb6041beea4144899cabe846c87d4230fcbd6611c34529b26459c488220b34abd0db636c1d3edb83f5596bc7e6451e1251a90ab727821b` |

The program's LiteSVM tests (`tests/payout.rs`) bind with this exact signature.
