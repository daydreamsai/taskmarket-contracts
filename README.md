# Taskmarket contracts

Smart contracts for Taskmarket, grouped by chain family.

| Folder    | Contents                                                                                 | Previously at       |
| --------- | ---------------------------------------------------------------------------------------- | ------------------- |
| `evm/`    | EVM contracts (Foundry): the Diamond, facets, hooks, forwarders, ABIs, scripts and tests | the repository root |
| `cairo/`  | Starknet contracts (Cairo), when they land                                               | not yet published   |
| `solana/` | Solana programs, when they land                                                          | not yet published   |
| `docs/`   | Chain-neutral protocol specs, revision docs and security notes                           | `docs/` (unchanged) |

Each family folder is its own tool root: run Foundry commands from `evm/`.

Clone with `git clone --recursive`, or run `git submodule update --init --recursive` after
cloning: the Foundry libraries under `evm/lib/` are git submodules.

## Sponsored Tasks deployments by chain

Sponsored Tasks (the `SponsoredTaskHook` extension, see
[`docs/extensions/ext-003-sponsored-task-hook.md`](docs/extensions/ext-003-sponsored-task-hook.md))
have one canonical deployment per chain, each working with the Taskmarket Diamond on that chain.
Vaults are clones: find them with the factory's `vaultCount()` and `vaultAt(index)`.

| Chain                    | Chain id | Family    | Status                               |
| ------------------------ | -------- | --------- | ------------------------------------ |
| Base Mainnet             | 8453     | `evm/`    | Live                                 |
| Base Sepolia             | 84532    | `evm/`    | Live (testnet)                       |
| Tempo Testnet (Moderato) | 42431    | `evm/`    | Live (testnet)                       |
| Tempo Mainnet            | 4217     | `evm/`    | Not deployed                         |
| Solana                   | -        | `solana/` | Program in development, not deployed |

### Base Mainnet (8453)

| Contract                    | Address                                      |
| --------------------------- | -------------------------------------------- |
| Sponsored Task hook (proxy) | `0x6031aFC2df6a03B08826aa75F90D3890B825618b` |
| Vault factory               | `0x92076c62558b4f77Bddd3ca8E00271128AfeD818` |
| Registry                    | `0xd622e5f875c33e08708CC1E14b0e71870ba5b398` |
| Fee policy                  | `0x31dB23CBf958f1286521b3dE2A0Ee6940380a7fb` |
| USDC                        | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Taskmarket Diamond          | `0xDDc6cC3e4D11c1f3527B867C7DAD4ED9869C33f7` |

### Base Sepolia (84532)

| Contract                    | Address                                      |
| --------------------------- | -------------------------------------------- |
| Sponsored Task hook (proxy) | `0x3BACEAAb845CC195f00cbC4929CC2a8e4B82E46B` |
| Vault factory               | `0xec2b7e70edB7738199549A4e45c2d34EA2B9b929` |
| Registry                    | `0x871f75350D59878f3d9d26E743ec220E706F7613` |
| Fee policy                  | `0xb42e8297d5FdBCC2c07Ec69D79CF8f46FB1c0374` |
| USDC                        | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Taskmarket Diamond          | `0x0A24E9c3b9E31B8258329e187470ACc16497Cec7` |

### Tempo Testnet (42431)

Rewards and the vault creation fee use OUSD (6 decimals) instead of USDC, and gas is paid in a TIP-20 fee
token rather than a native coin.

| Contract                    | Address                                      |
| --------------------------- | -------------------------------------------- |
| Sponsored Task hook (proxy) | `0x9af5D54B90FCd88F22a190d055a7A98f5aB43CcF` |
| Vault factory               | `0x942F2bF7105eC73797B2530Ba00D293330fBD613` |
| Registry                    | `0x06AB8249E0352B82E8B42d3e14ABBd4FA14Fa716` |
| Fee policy                  | `0x199354b8Bdb4757C1F5B81866e6cf2A503AB7af5` |
| OUSD                        | `0x20c0000000000000000000006a37da5c996874be` |

Read current owners and fee settings on-chain (`owner()`, `feeAmount()`, `feeTerms()`); they can
change after deployment.
