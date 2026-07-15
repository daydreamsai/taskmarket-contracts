# Disposable Anvil chain for per-PR preview environments (docs/specs/agent-preview-environments-rfc.md).
# Never used for real testnet/mainnet — those deploy to Base Sepolia/Base directly.
# --chain-id 84532: masquerade as Base Sepolia so the backend's CHAIN_ID, the X402
# network string (eip155:84532), and the facilitator's supported-network validation
# all line up without any of them learning a new chain. Safe because this chain only
# exists inside one PR environment's private network.
FROM ghcr.io/foundry-rs/foundry:latest

EXPOSE 8545

ENTRYPOINT ["anvil", "--host", "0.0.0.0", "--port", "8545", "--chain-id", "84532"]
