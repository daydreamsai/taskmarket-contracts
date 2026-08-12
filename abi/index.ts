// The generated files under ./generated/ and the .json files beside them are both
// written by `make build contracts` (packages/contracts/scripts/generate-abi.ts).
// Do not edit either by hand -- CI's `make contract abi-check` fails if they drift
// from the contract sources. The backend indexer reads its event definitions from
// here rather than hand-transcribing them
// (apps/backend/src/services/indexer-abi-events.ts).
//
// These re-export the `as const` TypeScript bindings, not the .json files. The
// distinction is the whole point: a JSON import widens every string to `string`, so
// an event's name and parameter types carry nothing the type system can check, while
// an `as const` literal preserves all of it. That is what makes a removed or renamed
// event a compile error at the consumer rather than a silent runtime miss.
// The .json copies remain for non-TypeScript tooling.
export { TaskMarketABI } from './generated/TaskMarket';
export { EpochBudgetABI } from './generated/EpochBudget';
export { RewardVaultABI } from './generated/RewardVault';
export { TaskTokenRewardHookABI } from './generated/TaskTokenRewardHook';
export { TaskMarketForwarderABI } from './generated/TaskMarketForwarder';
