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
| Tempo Mainnet            | 4217     | `evm/`    | Live                                 |
| Solana                   | -        | `solana/` | Program in development, not deployed |

### Base Mainnet (8453)

| Contract                       | Address                                      |
| ------------------------------ | -------------------------------------------- |
| Sponsored Task hook V2 (proxy) | `0xcE88BC99Ac344b11BF9188E363d5BDE2668E5C9E` |
| Vault factory V2               | `0xbEe8cd936ac296cC4fe37D0cd9dc0d49A670949F` |
| Registry                       | `0x39E87f9FBA70705F68a5d11839DBA1362473ed71` |
| Fee policy                     | `0xf3D7cBF5E9CE43840d5E264ae3eE3aA2AC1d1764` |
| USDC                           | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Taskmarket Diamond             | `0xDDc6cC3e4D11c1f3527B867C7DAD4ED9869C33f7` |

### Base Sepolia (84532)

| Contract                       | Address                                      |
| ------------------------------ | -------------------------------------------- |
| Sponsored Task hook V2 (proxy) | `0xD4273066d07fB24Eb9D994032B2bcFAe459428D7` |
| Vault factory V2               | `0xBba8233513A7e665FbCE91837d0492D4753f7A2e` |
| Registry                       | `0x871f75350D59878f3d9d26E743ec220E706F7613` |
| Fee policy                     | `0xb42e8297d5FdBCC2c07Ec69D79CF8f46FB1c0374` |
| USDC                           | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Taskmarket Diamond             | `0x0A24E9c3b9E31B8258329e187470ACc16497Cec7` |

### Tempo Testnet (42431)

Rewards and the vault creation fee use OUSD (6 decimals) instead of USDC, and gas is paid in a TIP-20 fee
token rather than a native coin.

| Contract                       | Address                                      |
| ------------------------------ | -------------------------------------------- |
| Sponsored Task hook V2 (proxy) | `0x801cE5C3949B4cAaD219a03a1d81B0a98e38baA8` |
| Vault factory V2               | `0xF0890Bb690594066AcCc67E7d99DBF040ff75735` |
| Registry                       | `0x06AB8249E0352B82E8B42d3e14ABBd4FA14Fa716` |
| Fee policy                     | `0x199354b8Bdb4757C1F5B81866e6cf2A503AB7af5` |
| OUSD                           | `0x20c0000000000000000000006a37da5c996874be` |

### Tempo Mainnet (4217)

Rewards and the vault creation fee use OUSD (6 decimals) instead of USDC, and gas is paid in a TIP-20 fee
token rather than a native coin.

| Contract                       | Address                                      |
| ------------------------------ | -------------------------------------------- |
| Sponsored Task hook V2 (proxy) | `0xb41e7DaF2d40C237ea47360E5Ba251168Ab5928b` |
| Vault factory V2               | `0xb894c0d4976E3F8d40e02fc76F1F095037c244DA` |
| Registry                       | `0xC4B7Db89F05488235bF265cb8A49276288DF5353` |
| Fee policy                     | `0x27299141dc9e7e14b168f6b0e3fc8791cc26a0cc` |
| OUSD                           | `0x20c0000000000000000000006a37da5c996874be` |
| Taskmarket Diamond             | `0xF4f4a00011B080EbC1E599A765D8bCE7557B97e7` |

The vault factories are `SponsoredTaskFactoryV2` (`IMPLEMENTATION_VERSION` 3), each controlled by the chain's
V2 hook. The V2 factory each one replaced stays authorized (Base `0xA9B325C4BAA21ea9E3f07Ba8F8CB794A99485E59`,
Base Sepolia `0xE8a4Be1Ab96554D0119DCC8440a86601B75B8b42`, Tempo Mainnet
`0x75A2A1d6302f77687aBBe7D25B7e1f318Dab9C78`, Tempo Testnet `0xAb9efEf4F36cf06657cE065C94EB2183e7A1fb69`), so its
vaults keep working. Vaults from an earlier factory have no `sweepExited`.

Read current owners and fee settings on-chain (`owner()`, `feeAmount()`, `feeTerms()`); they can
change after deployment.
