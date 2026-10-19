// Tests for script/tempo.sh's DRY_RUN handling and the deploy-forwarder constructor check, run
// with stub `forge` and `cast` binaries so no network or compilation is involved. Each case copies
// tempo.sh into a temporary directory, puts the stubs first on PATH, and reads back what forge was
// asked to do.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  copyFileSync,
  readFileSync,
  chmodSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const TEMPO_SH = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "tempo.sh",
);

const KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const DEPLOYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const USDC = "0x20c0000000000000000000000000000000000000";
const DIAMOND = "0x1111111111111111111111111111111111111111";
const RELAYER = "0x2222222222222222222222222222222222222222";
const FORWARDER = "0x3333333333333333333333333333333333333333";
const OTHER = "0x4444444444444444444444444444444444444444";

// forge records its arguments, echoes the inputs it was given the way DeployForwarderV2's
// console.log does, and writes a run record whose creation transaction encodes SIM_USDC,
// SIM_MARKET and SIM_RELAYER (defaulting to the exported inputs) -- the record is what tempo.sh
// must read. NO_RECORD skips writing it.
const FORGE = `#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$2" in *DeployForwarderV2*) ;; *) exit 0 ;; esac
dir="broadcast/DeployForwarderV2.s.sol/42431"
case " $* " in *" --broadcast "*) ;; *) dir="$dir/dry-run" ;; esac
pad() { printf '000000000000000000000000%s' "$(printf '%s' "$1" | sed 's/^0x//')"; }
input="0x6080$(pad "\${SIM_USDC:-$FORGE_USDC_TOKEN_ADDRESS}")$(pad "\${SIM_MARKET:-$CONTRACT_ADDRESS}")$(pad "\${SIM_RELAYER:-$FORGE_SERVER_ADDRESS}")"
if [ -z "\${NO_RECORD:-}" ]; then
  mkdir -p "$dir"
  printf '{"transactions":[{"transactionType":"CREATE","contractName":"TaskMarketForwarderV2","contractAddress":"%s","transaction":{"input":"%s"}}]}' "$SIM_FORWARDER" "$input" > "$dir/run-latest.json"
fi
echo "Forwarder v2 (FORWARDER_ADDRESS once trusted): $SIM_FORWARDER"
echo "  USDC: $FORGE_USDC_TOKEN_ADDRESS"
echo "  TaskMarket: $CONTRACT_ADDRESS"
echo "  Authorized relayer: $FORGE_SERVER_ADDRESS"
`;
const CAST = `#!/usr/bin/env bash
case "$*" in
  wallet\\ address*) echo "${DEPLOYER}" ;;
  *owner\\(\\)*) echo "${DEPLOYER}" ;;
  *usdc\\(\\)*) echo "$FORGE_USDC_TOKEN_ADDRESS" ;;
  *taskMarket\\(\\)*) echo "$CONTRACT_ADDRESS" ;;
  *authorizedRelayer\\(\\)*) echo "$FORGE_SERVER_ADDRESS" ;;
  *isTrustedForwarder*) echo true ;;
  *) exit 1 ;;
esac
`;

function run({ action = "deploy", env = {}, stale = false }) {
  const dir = mkdtempSync(join(tmpdir(), "tempo-sh-"));
  mkdirSync(join(dir, "script"));
  mkdirSync(join(dir, "bin"));
  copyFileSync(TEMPO_SH, join(dir, "script", "tempo.sh"));
  writeFileSync(join(dir, "bin", "forge"), FORGE);
  writeFileSync(join(dir, "bin", "cast"), CAST);
  chmodSync(join(dir, "bin", "forge"), 0o755);
  chmodSync(join(dir, "bin", "cast"), 0o755);
  if (stale) {
    for (const sub of ["", "/dry-run"]) {
      const d = join(dir, `broadcast/DeployForwarderV2.s.sol/42431${sub}`);
      mkdirSync(d, { recursive: true });
      writeFileSync(
        join(d, "run-latest.json"),
        JSON.stringify({
          transactions: [
            {
              transactionType: "CREATE",
              contractName: "TaskMarketForwarderV2",
              contractAddress: FORWARDER,
              transaction: {
                input: `0x6080${[USDC, DIAMOND, RELAYER].map((a) => a.slice(2).padStart(64, "0")).join("")}`,
              },
            },
          ],
        }),
      );
    }
  }
  const calls = join(dir, "calls");
  const base = { ...process.env };
  delete base.DRY_RUN;
  const r = spawnSync("bash", ["script/tempo.sh", action, "tempo-testnet"], {
    cwd: dir,
    encoding: "utf8",
    env: {
      ...base,
      PATH: `${join(dir, "bin")}:${process.env.PATH}`,
      CALLS: calls,
      SIM_FORWARDER: FORWARDER,
      FORGE_DEV_PRIVATE_KEY_TEMPO_TESTNET: KEY,
      FORGE_FEE_TOKEN_TEMPO_TESTNET: USDC,
      FORGE_USDC_TOKEN_ADDRESS_TEMPO_TESTNET: USDC,
      FORGE_FEE_RECIPIENT_ADDRESS_TEMPO_TESTNET: OTHER,
      FORGE_DEFAULT_PLATFORM_FEE_BPS_TEMPO_TESTNET: "500",
      FORGE_MIN_FEEDBACK_GAS_TEMPO_TESTNET: "100000",
      FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET: DIAMOND,
      FORGE_SERVER_ADDRESS_TEMPO_TESTNET: RELAYER,
      ...env,
    },
  });
  let forgeCalls = [];
  try {
    forgeCalls = readFileSync(calls, "utf8").trim().split("\n");
  } catch {}
  return { ...r, forgeCalls, out: r.stdout + r.stderr };
}

const broadcasts = (r) => r.forgeCalls.some((c) => / --broadcast( |$)/.test(c));

for (const value of ["1", "true", "yes", "TRUE", "on"]) {
  test(`DRY_RUN=${value} simulates without broadcasting`, () => {
    const r = run({ env: { DRY_RUN: value } });
    assert.equal(r.status, 0, r.out);
    assert.equal(r.forgeCalls.length, 1, r.out);
    assert.equal(broadcasts(r), false, r.forgeCalls.join("\n"));
    assert.match(r.stdout, /DRY RUN \(no broadcast\)/);
  });
}

for (const value of [undefined, "", "0", "false", "FALSE"]) {
  test(`DRY_RUN=${JSON.stringify(value)} broadcasts`, () => {
    const env = value === undefined ? {} : { DRY_RUN: value };
    const r = run({ env });
    assert.equal(r.status, 0, r.out);
    assert.equal(broadcasts(r), true, r.forgeCalls.join("\n"));
    assert.doesNotMatch(r.stdout, /DRY RUN/);
  });
}

test("deploy-forwarder dry run passes when the simulated creation matches the inputs", () => {
  const r = run({ action: "deploy-forwarder", env: { DRY_RUN: "1" } });
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /decoded from the creation transaction/);
  assert.match(r.stdout, /DRY RUN: skipping addForwarder/);
  assert.equal(broadcasts(r), false);
});

for (const [name, override] of [
  ["usdc()", { SIM_USDC: OTHER }],
  ["taskMarket()", { SIM_MARKET: OTHER }],
  ["authorizedRelayer()", { SIM_RELAYER: OTHER }],
]) {
  test(`deploy-forwarder dry run fails when the simulated ${name} differs from the input`, () => {
    // The script's console.log still echoes the exported inputs, so only a check that reads the
    // creation transaction can catch this.
    const r = run({
      action: "deploy-forwarder",
      env: { DRY_RUN: "1", ...override },
    });
    assert.notEqual(r.status, 0, r.out);
    assert.match(
      r.stderr,
      new RegExp(`Forwarder ${name.replace(/[()]/g, "\\$&")} is ${OTHER}`, "i"),
    );
  });
}

test("deploy-forwarder does not accept a run record left by an earlier run", () => {
  const r = run({
    action: "deploy-forwarder",
    env: { DRY_RUN: "1", NO_RECORD: "1" },
    stale: true,
  });
  assert.notEqual(r.status, 0, r.out);
  assert.match(r.stderr, /No forge run record/);
});

test("deploy-forwarder broadcast checks the record, then the chain, then trusts the forwarder", () => {
  const r = run({ action: "deploy-forwarder", env: { DRY_RUN: "false" } });
  assert.equal(r.status, 0, r.out);
  assert.match(r.stdout, /isTrustedForwarder\(.*\) = true/);
  assert.ok(r.forgeCalls.some((c) => c.includes("AddForwarder")));
});
