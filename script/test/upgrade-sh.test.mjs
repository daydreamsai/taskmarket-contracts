// Tests for script/upgrade.sh's step ordering, run with stub `forge` and `cast` binaries so no
// network or compilation is involved. Each case copies upgrade.sh into a temporary directory with
// empty step files, puts the stubs first on PATH, and reads back which steps "broadcast".
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  copyFileSync,
  readFileSync,
  existsSync,
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

const UPGRADE_SH = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "upgrade.sh",
);

// cast answers each call from CAST_PLAN in turn ("fail" exits non-zero, a number is printed as a
// stale or wrong read) and, once the plan is used up, prints the version held in $STATE; forge records the step it was asked to run and, unless
// that step is listed in FAIL_BEFORE, advances $STATE to the step's target revision. A step in
// FAIL_AFTER advances the version and then exits non-zero, like a verification failure.
const CAST = `#!/usr/bin/env bash
if [ "$1" = chain-id ]; then echo "$CHAIN_ID_REPLY"; exit 0; fi
${CAST_GAS}
n=$(( $(cat "$CAST_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CAST_COUNT"
step="$(printf '%s' "$CAST_PLAN" | awk -v n="$n" '{ print $n }')"
case "$step" in
  "") cat "$STATE" ;;
  fail) exit 1 ;;
  *) echo "$step" ;;
esac
`;
const FORGE = `#!/usr/bin/env bash
${FORGE_GAS}
name="$(printf '%s' "$2" | sed 's/.*://')"
echo "$name" >> "$CALLS"
echo "$*" >> "$CALLS.args"
case " $FAIL_BEFORE " in *" $name "*) exit 1;; esac
target="$(printf '%s' "$name" | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')"
echo "$target" > "$STATE"
case " $FAIL_AFTER " in *" $name "*) exit 1;; esac
exit 0
`;

const NETWORKS = {
  testnet: ["TESTNET", "84532"],
  mainnet: ["MAINNET", "8453"],
  "tempo-testnet": ["TEMPO_TESTNET", "42431"],
  "tempo-mainnet": ["TEMPO_MAINNET", "4217"],
};

function run({
  steps,
  version,
  args = [],
  env = {},
  network = "testnet",
  without,
}) {
  const [suffix, chainId] = NETWORKS[network];
  const dir = mkdtempSync(join(tmpdir(), "upgrade-sh-"));
  mkdirSync(join(dir, "script", "upgrades"), { recursive: true });
  mkdirSync(join(dir, "bin"));
  copyFileSync(UPGRADE_SH, join(dir, "script", "upgrade.sh"));
  for (const step of steps)
    writeFileSync(join(dir, "script", "upgrades", `${step}.s.sol`), "");
  writeFileSync(join(dir, "bin", "cast"), CAST);
  writeFileSync(join(dir, "bin", "forge"), FORGE);
  chmodSync(join(dir, "bin", "cast"), 0o755);
  chmodSync(join(dir, "bin", "forge"), 0o755);
  installGasStubs(dir);
  const state = join(dir, "state");
  const calls = join(dir, "calls");
  writeFileSync(state, `${version}\n`);
  const res = spawnSync("bash", ["script/upgrade.sh", network, ...args], {
    cwd: dir,
    encoding: "utf8",
    env: {
      PATH: without
        ? isolatedPath(dir, without)
        : `${join(dir, "bin")}:${process.env.PATH}`,
      [`FORGE_DIAMOND_ADDRESS_${suffix}`]:
        "0x0000000000000000000000000000000000000001",
      FORGE_FEE_TOKEN: "0x20c0000000000000000000000000000000000000",
      CHAIN_ID_REPLY: chainId,
      STATE: state,
      CALLS: calls,
      CAST_COUNT: join(dir, "cast-count"),
      CAST_PLAN: "",
      UPGRADE_VERSION_READ_DELAY: "0",
      FAIL_BEFORE: "",
      FAIL_AFTER: "",
      ...gasEnv(dir),
      ...env,
    },
  });
  const ran = existsSync(calls)
    ? readFileSync(calls, "utf8").trim().split("\n")
    : [];
  const gasFile = join(dir, "gas-calls");
  return {
    args: existsSync(`${calls}.args`)
      ? readFileSync(`${calls}.args`, "utf8").trim().split("\n")
      : [],
    gasCalls: existsSync(gasFile)
      ? readFileSync(gasFile, "utf8").trim().split("\n")
      : [],
    status: res.status,
    stderr: res.stderr,
    stdout: res.stdout,
    ran,
    version: readFileSync(state, "utf8").trim(),
  };
}

const ALL = ["Rev023Upgrade", "Rev024Upgrade", "Rev025Upgrade"];

test("an explicit rev024 argument is refused without running anything", () => {
  for (const arg of ["rev024", "REV024"]) {
    const r = run({ steps: ALL, version: 23, args: [arg] });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /Refusing to apply rev024 on its own/);
    assert.deepEqual(r.ran, []);
  }
});

test("an explicit rev025 argument still runs that step", () => {
  const r = run({ steps: ALL, version: 24, args: ["rev025"] });
  assert.equal(r.status, 0);
  assert.deepEqual(r.ran, ["Rev025Upgrade"]);
});

test("a pending run from rev023 applies Rev024 then Rev025", () => {
  const r = run({ steps: ALL, version: 23 });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
  assert.equal(r.version, "25");
});

test("a pending run that would stop after Rev024 is refused before broadcasting", () => {
  const r = run({ steps: ["Rev023Upgrade", "Rev024Upgrade"], version: 23 });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /Rev024 must always be followed by\s+Rev025Upgrade/);
  assert.deepEqual(r.ran, []);
});

test("a failure after Rev024's cut lands still carries on to Rev025", () => {
  const r = run({
    steps: ALL,
    version: 23,
    env: { FAIL_AFTER: "Rev024Upgrade" },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
  assert.equal(r.version, "25");
});

test("a Rev024 failure before its cut lands stops without running Rev025", () => {
  const r = run({
    steps: ALL,
    version: 23,
    env: { FAIL_BEFORE: "Rev024Upgrade" },
  });
  assert.equal(r.status, 1);
  assert.deepEqual(r.ran, ["Rev024Upgrade"]);
  assert.equal(r.version, "23");
});

test("a dry run from rev023 only simulates Rev024 and broadcasts nothing", () => {
  const r = run({ steps: ALL, version: 23, env: { DRY_RUN: "1" } });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade"]);
});

for (const value of ["true", "yes", "TRUE"]) {
  test(`DRY_RUN=${value} is a dry run too`, () => {
    const r = run({ steps: ALL, version: 23, env: { DRY_RUN: value } });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.ran, ["Rev024Upgrade"]);
  });
}

for (const value of ["0", "false", ""]) {
  test(`DRY_RUN=${JSON.stringify(value)} broadcasts every pending step`, () => {
    const r = run({ steps: ALL, version: 23, env: { DRY_RUN: value } });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
  });
}

const RECOVERY = /make upgrade testnet' \(no revision argument\)/;

test("a failed first diamondVersion read is retried", () => {
  const r = run({ steps: ALL, version: 23, env: { CAST_PLAN: "fail fail" } });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
  assert.equal(r.version, "25");
});

test("an unreadable diamondVersion is not read as 0 and prints the recovery command", () => {
  const r = run({
    steps: ALL,
    version: 23,
    env: { CAST_PLAN: "fail fail fail fail fail" },
  });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /could not be read/);
  assert.doesNotMatch(r.stderr, /reads 0/);
  assert.match(r.stderr, RECOVERY);
  assert.deepEqual(r.ran, []);
});

test("a failed read after Rev024's cut lands is retried and the run carries on to Rev025", () => {
  const r = run({
    steps: ALL,
    version: 23,
    // The first read is the starting version; the read after Rev024 fails once.
    env: { FAIL_AFTER: "Rev024Upgrade", CAST_PLAN: "23 fail" },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
  assert.equal(r.version, "25");
});

test("a stale read after Rev024's cut lands is not taken as 'not landed'", () => {
  const r = run({
    steps: ALL,
    version: 23,
    env: { FAIL_AFTER: "Rev024Upgrade", CAST_PLAN: "23 23 23" },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
});

test("Rev024 failing with diamondVersion unreadable stops, never claiming the cut did not land", () => {
  const r = run({
    steps: ALL,
    version: 23,
    env: {
      FAIL_AFTER: "Rev024Upgrade",
      CAST_PLAN: "23 fail fail fail fail fail",
    },
  });
  assert.equal(r.status, 1);
  assert.doesNotMatch(r.stderr, /before its cut landed|nothing to continue/);
  assert.match(r.stderr, /whether its\s+cut landed is unknown/);
  assert.match(r.stderr, RECOVERY);
  assert.deepEqual(r.ran, ["Rev024Upgrade"]);
});

test("Rev024 failing before its cut prints the recovery command", () => {
  const r = run({
    steps: ALL,
    version: 23,
    env: { FAIL_BEFORE: "Rev024Upgrade" },
  });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /still reads 23/);
  assert.match(r.stderr, RECOVERY);
});

test("a stale read after a step that succeeded waits for the new version", () => {
  const r = run({ steps: ALL, version: 23, env: { CAST_PLAN: "23 23" } });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
  assert.match(r.stdout, /current rev 24\)/);
  assert.match(r.stdout, /now at rev 25/);
});

for (const [network, [, chainId]] of Object.entries(NETWORKS)) {
  test(`${network}: runs when the RPC reports chain ${chainId}`, () => {
    const r = run({ network, steps: ALL, version: 24 });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.ran, ["Rev025Upgrade"]);
  });

  for (const wrong of ["1", ""]) {
    test(`${network}: refuses before any step when the RPC reports chain ${JSON.stringify(wrong)}`, () => {
      for (const args of [[], ["rev025"]]) {
        const r = run({
          network,
          steps: ALL,
          version: 24,
          args,
          env: { CHAIN_ID_REPLY: wrong },
        });
        assert.equal(r.status, 1);
        assert.match(
          r.stderr,
          new RegExp(`expected ${chainId} for ${network}`),
        );
        assert.deepEqual(r.ran, []);
      }
    });
  }
}

test("tempo: a step whose node estimate reaches the 30M cap is refused before broadcasting", () => {
  // 28,387,813 is the rev025 cut's node estimate on Moderato; 29,950,000 is past the 29.9M limit.
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 24,
    env: { TEMPO_ESTIMATES: "4000000 29950000" },
  });
  assert.equal(r.status, 1, r.stdout);
  assert.deepEqual(r.ran, []);
  assert.equal(r.gasCalls.length, 1);
  assert.match(
    r.stderr,
    /tx 1 \(CALL Diamond diamondCut\): node estimate 29950000 >= 29900000/,
  );
  assert.equal(r.version, "24");
});

test("tempo: a step under the cap broadcasts with every gas limit kept under it", () => {
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 24,
    env: { TEMPO_ESTIMATES: "4000000 28387813" },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev025Upgrade"]);
  const m = r.args[0].match(/--gas-estimate-multiplier (\d+)/);
  assert.ok(m, r.args[0]);
  assert.ok(/ --broadcast/.test(r.args[0]));
  assert.ok((28387813 * Number(m[1])) / 100 <= 29900000, m[1]);
  assert.equal(m[1], "103");
});

// Forge multiplies the live node's estimate, which on Moderato ran 0.80-0.87% above the fork's
// (CoreFacet 18,336,344 live vs 18,190,805 on the fork).
test("tempo: a 23.0M fork estimate with a live estimate 0.9% higher stays under 30M", () => {
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 24,
    env: { TEMPO_ESTIMATES: "23000000" },
  });
  assert.equal(r.status, 0, r.stderr);
  const m = Number(r.args[0].match(/--gas-estimate-multiplier (\d+)/)[1]);
  const live = Math.ceil(23000000 * 1.009);
  assert.ok(Math.floor((live * m) / 100) < 30000000, String(m));
});

test("tempo: a later step over the cap is refused before the first step broadcasts", () => {
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 23,
    env: { TEMPO_TXS_PER_SIM: "1", TEMPO_ESTIMATES: "5000000 29950000" },
  });
  assert.equal(r.status, 1, r.stdout);
  assert.deepEqual(r.ran, []);
  assert.equal(r.gasCalls.length, 2);
  assert.match(r.stderr, /Rev025Upgrade/);
  assert.equal(r.version, "23");
});

test("tempo: every pending step is checked on one fork, in order, before any broadcast", () => {
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 23,
    env: { TEMPO_TXS_PER_SIM: "1", TEMPO_ESTIMATES: "5000000 28387813" },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.ran, ["Rev024Upgrade", "Rev025Upgrade"]);
  assert.equal(r.gasCalls.length, 2);
  assert.match(r.gasCalls[0], /Rev024Upgrade/);
  assert.match(r.gasCalls[1], /Rev025Upgrade/);
  // One fork for the whole run: both simulations hit the same port.
  const port = (c) => c.match(/127\.0\.0\.1:(\d+)/)[1];
  assert.equal(port(r.gasCalls[0]), port(r.gasCalls[1]));
  assert.match(r.args[0], /--gas-estimate-multiplier 130 /);
  assert.match(r.args[1], /--gas-estimate-multiplier 103 /);
});

test("tempo: a dry run from rev023 reports every pending step", () => {
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 23,
    env: {
      DRY_RUN: "1",
      TEMPO_TXS_PER_SIM: "1",
      TEMPO_ESTIMATES: "5000000 28387813",
    },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.gasCalls.length, 2);
  assert.match(
    r.stdout,
    /Rev024Upgrade: largest node estimate 5000000, multiplier 130/,
  );
  assert.match(
    r.stdout,
    /Rev025Upgrade: largest node estimate 28387813, multiplier 103/,
  );
  assert.ok(r.args.every((a) => !/ --broadcast/.test(a)));
});

for (const tool of ["anvil", "jq"]) {
  test(`tempo: a missing ${tool} is refused before anything runs`, () => {
    const r = run({
      network: "tempo-testnet",
      steps: ALL,
      version: 24,
      without: [tool],
    });
    assert.equal(r.status, 1);
    assert.match(r.stderr, new RegExp(`needs ${tool} on PATH`));
    assert.deepEqual(r.ran, []);
    assert.deepEqual(r.gasCalls, []);
  });
}

test("tempo: without TEMPO_GAS_FORK_PORT the fork uses a free port, not 8599", () => {
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 24,
    env: { TEMPO_GAS_FORK_PORT: "" },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.gasCalls[0], /127\.0\.0\.1:\d+/);
  assert.doesNotMatch(r.gasCalls[0], /:8599/);
});

test("tempo: a dry run reads node estimates and refuses one over the cap", () => {
  const r = run({
    network: "tempo-testnet",
    steps: ALL,
    version: 24,
    env: { DRY_RUN: "1", TEMPO_ESTIMATES: "30000000" },
  });
  assert.equal(r.status, 1);
  assert.deepEqual(r.ran, []);
  assert.match(r.stderr, /Refusing to broadcast/);
});

test("base networks skip the Tempo gas check", () => {
  const r = run({ network: "testnet", steps: ALL, version: 24 });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.gasCalls, []);
  assert.doesNotMatch(r.args[0], /gas-estimate-multiplier/);
});
