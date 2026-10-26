// Shell fragments shared by the tempo.sh and upgrade.sh tests to stand in for the Tempo gas check
// (script/lib/tempo-gas.sh): a stub anvil, the cast answers the check reads from the local fork,
// and the forge simulation on that fork. TEMPO_ESTIMATES lists one node estimate (decimal) per
// transaction in the simulated run records, in order (TEMPO_TXS_PER_SIM transactions per simulation,
// all of them by default); every fork simulation is logged to $GAS_CALLS.
import {
  cpSync,
  writeFileSync,
  chmodSync,
  mkdirSync,
  symlinkSync,
  rmSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const LIB = join(dirname(fileURLToPath(import.meta.url)), "..", "lib");

export const ANVIL = `#!/usr/bin/env bash
exec sleep 30
`;

// Placed at the top of the cast stub, before any other case.
export const CAST_GAS = `
case "$1" in
  rpc)
    case "$*" in
      *eth_estimateGas*)
        n=$(( $(cat "$GAS_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GAS_COUNT"
        est="$(printf '%s' "\${TEMPO_ESTIMATES:-1000000}" | awk -v n="$n" '{ print $n }')"
        printf '"0x%x"\\n' "$est" ;;
      *) echo '"0x01"' ;;
    esac
    exit 0 ;;
  receipt) echo 1; exit 0 ;;
esac
`;

// Placed at the top of the forge stub: a simulation against the local fork writes the run record
// the check reads and is not counted as one of the script's own forge calls.
export const FORGE_GAS = `
case "$*" in
  *"--rpc-url http://127.0.0.1:"*)
    echo "$*" >> "$GAS_CALLS"
    f="$(basename "$(printf '%s' "$2" | sed 's/:.*//')")"
    d="broadcast/$f/$CHAIN_ID_REPLY/dry-run"
    mkdir -p "$d"
    txs=""
    all="\${TEMPO_ESTIMATES:-1000000}"
    k="\${TEMPO_TXS_PER_SIM:-$(printf '%s' "$all" | wc -w)}"
    for _ in $(seq 1 "$k"); do
      txs="$txs\${txs:+,}{\\"transactionType\\":\\"CALL\\",\\"contractName\\":\\"Diamond\\",\\"function\\":\\"diamondCut\\",\\"transaction\\":{\\"from\\":\\"0x01\\",\\"to\\":\\"0x02\\",\\"input\\":\\"0x1f931c1c\\"}}"
    done
    printf '{"transactions":[%s]}' "$txs" > "$d/run-latest.json"
    exit 0 ;;
esac
`;

// Copies script/lib into <dir>/script/lib and writes the anvil stub into <dir>/bin.
export function installGasStubs(dir) {
  cpSync(LIB, join(dir, "script", "lib"), { recursive: true });
  writeFileSync(join(dir, "bin", "anvil"), ANVIL);
  chmodSync(join(dir, "bin", "anvil"), 0o755);
}

// Required tools linked into <dir>/sys, so a test can run a script on a PATH without anvil or jq.
const SYS_TOOLS = [
  "bash",
  "cat",
  "tr",
  "sed",
  "grep",
  "head",
  "tail",
  "sort",
  "seq",
  "basename",
  "dirname",
  "awk",
  "mktemp",
  "sleep",
  "rm",
  "mkdir",
  "wc",
  "env",
  "jq",
  "printf",
  "date",
];
export function isolatedPath(dir, without) {
  const sys = join(dir, "sys");
  mkdirSync(sys, { recursive: true });
  for (const t of SYS_TOOLS) {
    if (without.includes(t)) continue;
    const r = spawnSync("bash", ["-c", `command -v ${t}`], {
      encoding: "utf8",
    });
    const p = r.stdout.trim();
    if (p.startsWith("/")) symlinkSync(p, join(sys, t));
  }
  if (without.includes("anvil"))
    rmSync(join(dir, "bin", "anvil"), { force: true });
  return `${join(dir, "bin")}:${sys}`;
}

export function gasEnv(dir) {
  return {
    GAS_CALLS: join(dir, "gas-calls"),
    GAS_COUNT: join(dir, "gas-count"),
    FORGE_RPC_URL_42431: "http://tempo-moderato.invalid",
    FORGE_RPC_URL_4217: "http://tempo.invalid",
    // No fixed TEMPO_GAS_FORK_PORT: tempo-gas.sh picks a free port itself and retries a busy
    // one, where a random fixed port could land on a socket the runner already has open.
  };
}
