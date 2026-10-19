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
name="$(printf '%s' "$2" | sed 's/.*://')"
echo "$name" >> "$CALLS"
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

function run({ steps, version, args = [], env = {}, network = "testnet" }) {
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
  const state = join(dir, "state");
  const calls = join(dir, "calls");
  writeFileSync(state, `${version}\n`);
  const res = spawnSync("bash", ["script/upgrade.sh", network, ...args], {
    cwd: dir,
    encoding: "utf8",
    env: {
      PATH: `${join(dir, "bin")}:${process.env.PATH}`,
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
      ...env,
    },
  });
  const ran = existsSync(calls)
    ? readFileSync(calls, "utf8").trim().split("\n")
    : [];
  return {
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
