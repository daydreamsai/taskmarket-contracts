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
import {
  CAST_GAS,
  FORGE_GAS,
  installGasStubs,
  gasEnv,
  isolatedPath,
} from "./tempo-gas-stubs.mjs";

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
${FORGE_GAS}
echo "$*" >> "$CALLS"
case "$2" in
  *DeployForwarderV2*) ;;
  *AddForwarder*) [ -n "\${FAIL_ADD:-}" ] && exit 1; touch "$TRUSTED_FILE"; exit 0 ;;
  *) exit 0 ;;
esac
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
[ -n "\${FAIL_DEPLOY:-}" ] && exit 1
exit 0
`;
// cast answers chain-id from CHAIN_ID_REPLY, code from CODE_REPLY, and isTrustedForwarder from
// whether AddForwarder has run (or TRUSTED_FILE was seeded). ONCHAIN_USDC overrides the deployed
// forwarder's usdc().
const CAST = `#!/usr/bin/env bash
${CAST_GAS}
case "$*" in
  chain-id*) echo "$CHAIN_ID_REPLY" ;;
  code\\ *) echo "\${CODE_REPLY-0x6080}" ;;
  wallet\\ address*) echo "${DEPLOYER}" ;;
  *owner\\(\\)*) echo "${DEPLOYER}" ;;
  *usdc\\(\\)*) echo "\${ONCHAIN_USDC:-$FORGE_USDC_TOKEN_ADDRESS}" ;;
  *taskMarket\\(\\)*) echo "$CONTRACT_ADDRESS" ;;
  *authorizedRelayer\\(\\)*) echo "$FORGE_SERVER_ADDRESS" ;;
  *isTrustedForwarder*) if [ -f "$TRUSTED_FILE" ]; then echo true; else echo false; fi ;;
  *) exit 1 ;;
esac
`;

function run({
  action = "deploy",
  env = {},
  stale = false,
  without,
  network = "42431",
  trusted = false,
}) {
  const suffix = network === "4217" ? "4217" : "42431";
  const chainId = suffix;
  const dir = mkdtempSync(join(tmpdir(), "tempo-sh-"));
  mkdirSync(join(dir, "script"));
  mkdirSync(join(dir, "bin"));
  copyFileSync(TEMPO_SH, join(dir, "script", "tempo.sh"));
  writeFileSync(join(dir, "bin", "forge"), FORGE);
  writeFileSync(join(dir, "bin", "cast"), CAST);
  chmodSync(join(dir, "bin", "forge"), 0o755);
  chmodSync(join(dir, "bin", "cast"), 0o755);
  installGasStubs(dir);
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
  const trustedFile = join(dir, "trusted");
  if (trusted) writeFileSync(trustedFile, "");
  const base = { ...process.env };
  delete base.DRY_RUN;
  const r = spawnSync("bash", ["script/tempo.sh", action, network], {
    cwd: dir,
    encoding: "utf8",
    env: {
      ...base,
      PATH: without
        ? isolatedPath(dir, without)
        : `${join(dir, "bin")}:${process.env.PATH}`,
      CALLS: calls,
      TRUSTED_FILE: trustedFile,
      CHAIN_ID_REPLY: chainId,
      SIM_FORWARDER: FORWARDER,
      ...gasEnv(dir),
      [`FORGE_DEV_PRIVATE_KEY_${suffix}`]: KEY,
      [`FORGE_FEE_TOKEN_${suffix}`]: USDC,
      [`FORGE_USDC_TOKEN_ADDRESS_${suffix}`]: USDC,
      [`FORGE_FEE_RECIPIENT_ADDRESS_${suffix}`]: OTHER,
      [`FORGE_DEFAULT_PLATFORM_FEE_BPS_${suffix}`]: "500",
      [`FORGE_MIN_FEEDBACK_GAS_${suffix}`]: "100000",
      [`FORGE_HOOK_GAS_STIPEND_${suffix}`]: "7000000",
      [`FORGE_DIAMOND_ADDRESS_${suffix}`]: DIAMOND,
      [`FORGE_SERVER_ADDRESS_${suffix}`]: RELAYER,
      ...env,
    },
  });
  let forgeCalls = [];
  try {
    forgeCalls = readFileSync(calls, "utf8").trim().split("\n");
  } catch {}
  let gasCalls = [];
  try {
    gasCalls = readFileSync(join(dir, "gas-calls"), "utf8").trim().split("\n");
  } catch {}
  return { ...r, forgeCalls, gasCalls, out: r.stdout + r.stderr };
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

for (const action of ["deploy", "upgrade"]) {
  test(`${action} refuses without FORGE_HOOK_GAS_STIPEND_42431`, () => {
    const r = run({ action, env: { FORGE_HOOK_GAS_STIPEND_42431: "" } });
    assert.notEqual(r.status, 0);
    assert.match(r.out, /FORGE_HOOK_GAS_STIPEND_42431/);
    assert.equal(r.forgeCalls.filter(Boolean).length, 0, "nothing sent");
  });
}

test("a broadcast to a remote RPC sends the contracts for verification", () => {
  const r = run({});
  assert.equal(r.status, 0, r.out);
  const sent = r.forgeCalls.filter((c) => / --broadcast( |$)/.test(c));
  assert.ok(sent.length > 0, r.out);
  for (const line of sent) assert.match(line, / --verify /);
});

for (const url of ["http://127.0.0.1:8546", "http://localhost:8546"]) {
  test(`a broadcast to a local node at ${url} skips verification`, () => {
    const r = run({ env: { FORGE_RPC_URL_42431: url } });
    assert.equal(r.status, 0, r.out);
    const sent = r.forgeCalls.filter((c) => / --broadcast( |$)/.test(c));
    assert.ok(sent.length > 0, r.out);
    for (const line of sent) assert.doesNotMatch(line, / --verify /);
    assert.match(r.stdout, /Local node: skipping source verification/);
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

for (const [network, chainId] of [
  ["42431", "42431"],
  ["4217", "4217"],
]) {
  for (const action of ["deploy", "deploy-forwarder"]) {
    test(`${action} ${network} refuses when the RPC is not chain ${chainId}`, () => {
      for (const wrong of [chainId === "4217" ? "42431" : "4217", ""]) {
        const r = run({
          action,
          network,
          env: { DRY_RUN: "0", CHAIN_ID_REPLY: wrong },
        });
        assert.notEqual(r.status, 0, r.out);
        assert.match(
          r.stderr,
          new RegExp(`expected ${chainId} for ${network}`),
        );
        assert.deepEqual(r.forgeCalls, []);
      }
    });
  }

  test(`deploy ${network} runs when the RPC is chain ${chainId}`, () => {
    const r = run({ network, env: { DRY_RUN: "0" } });
    assert.equal(r.status, 0, r.out);
    assert.equal(broadcasts(r), true);
  });
}

const RESUME_HINT = new RegExp(
  `FORWARDER_ADDRESS_RESUME=${FORWARDER} make deploy-forwarder 42431`,
);
const ran = (r, name) => r.forgeCalls.some((c) => c.includes(name));

for (const [name, env] of [
  ["forge fails after the broadcast (verification)", { FAIL_DEPLOY: "1" }],
  ["the on-chain getter check fails", { ONCHAIN_USDC: OTHER }],
  ["addForwarder fails", { FAIL_ADD: "1" }],
]) {
  test(`deploy-forwarder prints the deployed address and resume command when ${name}`, () => {
    const r = run({
      action: "deploy-forwarder",
      env: { DRY_RUN: "0", ...env },
    });
    assert.notEqual(r.status, 0, r.out);
    assert.match(r.stderr, new RegExp(`deployed at ${FORWARDER}`));
    assert.match(r.stderr, RESUME_HINT);
  });
}

test("deploy-forwarder prints no resume command when nothing reached the chain", () => {
  const r = run({
    action: "deploy-forwarder",
    env: { DRY_RUN: "0", FAIL_DEPLOY: "1", CODE_REPLY: "0x" },
  });
  assert.notEqual(r.status, 0, r.out);
  assert.doesNotMatch(r.stderr, /is deployed at/);
  assert.match(r.stderr, /no forwarder code was found/);
});

test("FORWARDER_ADDRESS_RESUME skips the deploy, checks the getters, then trusts the forwarder", () => {
  const r = run({
    action: "deploy-forwarder",
    env: { DRY_RUN: "0", FORWARDER_ADDRESS_RESUME: FORWARDER },
  });
  assert.equal(r.status, 0, r.out);
  assert.equal(ran(r, "DeployForwarderV2"), false, r.forgeCalls.join("\n"));
  assert.ok(ran(r, "AddForwarder"));
  assert.match(r.stdout, /usdc\(\) = /);
  assert.match(r.stdout, /isTrustedForwarder\(.*\) = true/);
});

test("FORWARDER_ADDRESS_RESUME skips addForwarder when the diamond already trusts it", () => {
  const r = run({
    action: "deploy-forwarder",
    trusted: true,
    env: { DRY_RUN: "0", FORWARDER_ADDRESS_RESUME: FORWARDER },
  });
  assert.equal(r.status, 0, r.out);
  assert.deepEqual(r.forgeCalls, []);
  assert.match(r.stdout, /already trusts/);
});

test("FORWARDER_ADDRESS_RESUME fails the getter check without calling addForwarder", () => {
  const r = run({
    action: "deploy-forwarder",
    env: {
      DRY_RUN: "0",
      FORWARDER_ADDRESS_RESUME: FORWARDER,
      ONCHAIN_USDC: OTHER,
    },
  });
  assert.notEqual(r.status, 0, r.out);
  assert.match(r.stderr, new RegExp(`usdc\\(\\) is ${OTHER}`, "i"));
  assert.deepEqual(r.forgeCalls, []);
});

for (const [name, env, pattern] of [
  [
    "is not an address",
    { FORWARDER_ADDRESS_RESUME: "0x1234" },
    /is not an address/,
  ],
  [
    "has no code",
    { FORWARDER_ADDRESS_RESUME: FORWARDER, CODE_REPLY: "0x" },
    /No contract code/,
  ],
]) {
  test(`FORWARDER_ADDRESS_RESUME is refused when it ${name}`, () => {
    const r = run({
      action: "deploy-forwarder",
      env: { DRY_RUN: "0", ...env },
    });
    assert.notEqual(r.status, 0, r.out);
    assert.match(r.stderr, pattern);
    assert.deepEqual(r.forgeCalls, []);
  });
}

test("FORWARDER_ADDRESS_RESUME with DRY_RUN checks the getters and sends nothing", () => {
  const r = run({
    action: "deploy-forwarder",
    env: { DRY_RUN: "1", FORWARDER_ADDRESS_RESUME: FORWARDER },
  });
  assert.equal(r.status, 0, r.out);
  assert.deepEqual(r.forgeCalls, []);
  assert.match(r.stdout, /DRY RUN: skipping addForwarder/);
});

test("deploy-forwarder refuses a second deploy while an earlier forwarder is untrusted", () => {
  const r = run({
    action: "deploy-forwarder",
    stale: true,
    env: { DRY_RUN: "0" },
  });
  assert.notEqual(r.status, 0, r.out);
  assert.match(r.stderr, /Refusing to deploy a second forwarder/);
  assert.match(r.stderr, RESUME_HINT);
  assert.deepEqual(r.forgeCalls, []);
});

test("deploy-forwarder deploys again when the earlier forwarder is already trusted", () => {
  const r = run({
    action: "deploy-forwarder",
    stale: true,
    trusted: true,
    env: { DRY_RUN: "0" },
  });
  assert.equal(r.status, 0, r.out);
  assert.ok(ran(r, "DeployForwarderV2"));
});

test("deploy refuses before broadcasting when a node estimate reaches the 30M cap", () => {
  const r = run({ env: { TEMPO_ESTIMATES: "20446746 29900000 1000000" } });
  assert.equal(r.status, 1, r.out);
  assert.deepEqual(
    r.forgeCalls.filter((c) => c),
    [],
  );
  assert.equal(r.gasCalls.length, 1);
  assert.match(
    r.out,
    /tx 1 \(CALL Diamond diamondCut\): node estimate 29900000 >= 29900000/,
  );
});

test("deploy dry run refuses an estimate over the cap too", () => {
  const r = run({ env: { DRY_RUN: "1", TEMPO_ESTIMATES: "31000000" } });
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /Refusing to broadcast/);
});

test("deploy under the cap broadcasts with a multiplier that keeps every limit under it", () => {
  const r = run({ env: { TEMPO_ESTIMATES: "20446746 10399189" } });
  assert.equal(r.status, 0, r.out);
  const deploy = r.forgeCalls.find((c) => / --broadcast/.test(c));
  const m = deploy.match(/--gas-estimate-multiplier (\d+)/);
  assert.ok(m, deploy);
  assert.equal(m[1], "130");
  assert.ok((20446746 * Number(m[1])) / 100 <= 29900000);
});

test("deploy lowers the multiplier below 130 for an estimate above 23M", () => {
  const r = run({ env: { TEMPO_ESTIMATES: "28387813" } });
  assert.equal(r.status, 0, r.out);
  assert.match(r.forgeCalls.join("\n"), /--gas-estimate-multiplier 103 /);
});

test("deploy refuses an estimate whose multiplier would fall below 101", () => {
  // Under the 29.9M cap, but 29,400,000 * 100 / 29,200,000 is 100: forge would set a limit at or
  // below the estimate and the transaction could run out of gas on chain.
  const r = run({ env: { TEMPO_ESTIMATES: "5000000 29200000" } });
  assert.equal(r.status, 1, r.out);
  assert.equal(r.forgeCalls.filter((c) => / --broadcast/.test(c)).length, 0);
  assert.match(r.out, /multiplier 100, which is below the minimum 101/);
});

test("deploy accepts the largest estimate that still gets multiplier 101", () => {
  const r = run({ env: { TEMPO_ESTIMATES: "29108910" } });
  assert.equal(r.status, 0, r.out);
  assert.match(r.forgeCalls.join("\n"), /--gas-estimate-multiplier 101 /);
});

for (const tool of ["anvil", "jq"]) {
  test(`deploy refuses a missing ${tool} before anything runs`, () => {
    const r = run({ without: [tool] });
    assert.equal(r.status, 1, r.out);
    assert.match(r.out, new RegExp(`needs ${tool} on PATH`));
    assert.deepEqual(r.forgeCalls, []);
    assert.deepEqual(r.gasCalls, []);
  });
}

const SCRIPT_ACTIONS = [
  {
    action: "deploy-sponsored-task",
    target: "DeploySponsoredTask.s.sol:DeploySponsoredTask",
    verifies: true,
    env: {
      FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT_42431: OTHER,
      FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT_42431: OTHER,
      FORGE_SPONSORED_TASK_ADMIN_42431: RELAYER,
      FORGE_SPONSORED_TASK_FEE_CEILING_USDC_42431: "5000000",
    },
    required: "FORGE_SPONSORED_TASK_ADMIN_42431",
  },
  {
    action: "upgrade-sponsored-task",
    target: "UpgradeSponsoredTask.s.sol:UpgradeSponsoredTask",
    verifies: true,
    env: { FORGE_SPONSORED_TASK_HOOK_ADDRESS_42431: FORWARDER },
    required: "FORGE_SPONSORED_TASK_HOOK_ADDRESS_42431",
  },
  {
    action: "deploy-safe",
    target: "DeploySafe.s.sol:DeploySafe",
    verifies: false,
    env: {
      FORGE_SAFE_DEPLOYER_KEY_42431: KEY,
      FORGE_SAFE_OWNERS_42431: DEPLOYER,
      FORGE_SAFE_THRESHOLD_42431: "1",
    },
    required: "FORGE_SAFE_OWNERS_42431",
  },
  {
    action: "deploy-sponsored-task-timelock",
    target:
      "DeploySponsoredTaskGuardTimelock.s.sol:DeploySponsoredTaskGuardTimelock",
    verifies: false,
    env: {
      FORGE_TIMELOCK_DEPLOYER_KEY_42431: KEY,
      FORGE_TIMELOCK_SAFE_42431: OTHER,
      FORGE_TIMELOCK_MIN_DELAY_42431: "86400",
    },
    required: "FORGE_TIMELOCK_DEPLOYER_KEY_42431",
  },
];

for (const { action, target, verifies, env, required } of SCRIPT_ACTIONS) {
  test(`${action} broadcasts ${target} with the fee token${verifies ? " and Sourcify" : ""}`, () => {
    const r = run({ action, env });
    assert.equal(r.status, 0, r.out);
    const sent = r.forgeCalls.filter((c) => / --broadcast( |$)/.test(c));
    assert.equal(sent.length, 1, r.out);
    assert.match(
      sent[0],
      new RegExp(`script/${target.replace(/\./g, "\\.")} `),
    );
    assert.match(sent[0], / --tempo\.fee-token /);
    assert.match(sent[0], / --gas-estimate-multiplier /);
    if (verifies) assert.match(sent[0], / --verifier sourcify /);
    else assert.doesNotMatch(sent[0], / --verify/);
  });

  test(`${action} dry run sends nothing`, () => {
    const r = run({ action, env: { ...env, DRY_RUN: "1" } });
    assert.equal(r.status, 0, r.out);
    assert.equal(broadcasts(r), false, r.forgeCalls.join("\n"));
  });

  test(`${action} refuses before forge runs when ${required} is missing`, () => {
    const r = run({ action, env: { ...env, [required]: "" } });
    assert.notEqual(r.status, 0, r.out);
    assert.match(r.stderr, new RegExp(required));
    assert.equal(r.forgeCalls.length, 0, r.out);
  });
}
