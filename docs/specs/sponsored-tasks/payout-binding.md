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
  salt              keccak256(program id (32 bytes) || Config.cluster_id (32 bytes))

primaryType = PayoutBinding(address agent,bytes32 payout,uint64 nonce,uint64 deadline)
  agent             the signing EVM address
  payout            the 32 bytes of the Solana payout address
  nonce             must exceed the current binding's nonce and be below u64::MAX
  deadline          unix seconds; the program rejects the binding after it (u64::MAX for none)
```

The digest is `keccak256(0x19 0x01 || domainSeparator || hashStruct(message))`, exactly as
`eth_signTypedData_v4` and viem's `signTypedData` build it. `chainId` and `salt` keep a binding
from being replayed on another EVM chain, against another deployment of the program, or on another
Solana cluster that reuses the same program id: `Config.cluster_id` is set once by `init_config` to
the cluster's genesis hash (32 bytes, never zero), and a signer reads it from the `Config` account.
`deadline` bounds how long a signature stays usable by a relayer; a signer picks it, and a
signature cannot be resubmitted with a later one because the deadline is part of the digest.

## Instruction

`bind_payout(task_chain_id: u64, agent: [u8; 20], payout: Pubkey, nonce: u64, deadline: u64,
signature: [u8; 65])`; the accounts include `Config` (read for the cluster id).

- `signature` is `r || s || v`; `v` may be 27/28 (as wallets return it) or 0/1.
- The account is the PDA `["payout", task_chain_id (u64 LE), agent]`, created by the relayer
  on first use. Bindings for the same agent on different EVM chains are separate accounts.
- Errors: `InvalidPayoutSignature` when the recovered address is not `agent` or the
  signature is malformed; `StalePayoutNonce` when `nonce` is not above the stored one;
  `PayoutSignatureExpired` when the clock is past `deadline`; `InvalidPayoutNonce` when `nonce` is
  `u64::MAX`, which could never be replaced. Both binding paths refuse that nonce.
- Event: `PayoutBound { task_chain_id, agent, payout, nonce }`.
- Open while the program is paused: it moves no funds.

## Attested binding for contract-wallet agents

A smart contract wallet cannot produce a secp256k1 signature over the digest above; it proves
control with an ERC-1271 signature that only its own chain can verify. For such an agent, the
settlers check the ERC-1271 signature of the same typed data on the agent's chain and attest the
binding with `bind_payout_attested(task_chain_id, agent, payout, nonce)`, signed by the settler
threshold like `settle` (signers as remaining accounts; `SettlerThresholdNotMet` otherwise).

- It writes the same `PayoutBinding` account, but the new payout is held as pending: the account
  stores it in `pending_payout` with `pending_effective_at` set to the attestation time plus
  `Config.claim_delay`, and the event is `PayoutBindingPending { task_chain_id, agent, payout,
  nonce, effective_at }`. `claim` pays the current `payout` until the clock reaches
  `pending_effective_at` and the pending payout from then on. An agent with no earlier binding
  has no payout until then: a claim fails with `PayoutNotBound`.
- The wait matters because the settlers also decide which worker each award leaf names. Without
  it they could post a plausible root and re-point the payouts in the same breath; with it, the
  admin has a full claim delay to notice and revoke.
- An agent-signed `bind_payout` stays immediate: it sets `payout`, clears any pending attested
  change, and needs a higher nonce as before. A second attestation replaces the first pending
  one and restarts the wait.
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
| program id bytes | `0x0685f6908c03b1c23d54add539d49548ef326302ffdbd3bffd4eaeb000000000` |
| `cluster_id` | 32 bytes of `0xc1` |
| `salt` | `0xc7d7e38e3824a254223a4b22a0fe03a48f1c77b784dff1fe15e6274c0b0d9fe0` |
| `agent` | `0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A` |
| `payout` | 32 bytes of `0x44` |
| `nonce` | `1` |
| `deadline` | `4000000000` |
| digest | `0xe0688b70b12b56d8ad6bb1a5a7b30b7328ae7016450cc01cf6b514e2d56d1bfa` |
| signature | `0x94284c90b348f5c4865a2ff0c2488f1a38f375036690ec0b63811e71a5b7b9e841c3bdd815b674291a6eb281a35af4de79a0e7090ffb7c76917e2ffb911308121b` |

The program's LiteSVM tests (`tests/payout.rs`) bind with this exact signature.
