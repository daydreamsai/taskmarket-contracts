#!/usr/bin/env node
// Reads the log of a Foundry run of test/HookGasMeasurement.t.sol at trace verbosity (-vvvv) and
// reports, for each hook label (`GAS_*`) and each callback called on it, the number of calls and
// the min / median / max of the gas Foundry prints for that call frame.
//
// Usage: node tools/hook-gas/trace-gas.mjs <forge-log> [--json]
//
// The frame gas is what the callee consumed, including its own sub-calls, and excludes the
// caller-side call cost (the account access charge). Frames that revert are skipped. The median
// of an even count is the mean of the two middle values, rounded down.
//
// Forge prices storage with Ethereum rules. Tempo charges 250,000 gas for a slot that goes from
// zero to nonzero, against 20,000. The test logs, after each test, how many such slots each
// callback frame created (`GASSLOTS <label> <callback> <count>`); the Tempo figure is the frame gas
// plus 230,000 per such slot. It is derived from the measurement, not a Tempo execution.

import { readFileSync } from "node:fs";

export const TEMPO_NEW_SLOT_SURCHARGE = 250_000 - 20_000;

const FRAME = /^(.*?)(├─|└─) \[(\d+)\] (GAS_[A-Z0-9_]+)::(\w+)\(/;
const SLOTS = /^\s*GASSLOTS (GAS_[A-Z0-9_]+) (\w+) (\d+)/;
const CALLBACKS = new Set([
  "beforeCreate",
  "beforeClaim",
  "beforeSelectWorker",
  "beforeSubmitProof",
  "beforeAcceptAuction",
  "beforeSubmitWork",
  "beforeEvaluate",
  "beforeAccept",
  "afterComplete",
  "afterCancel",
  "afterExpire",
  "afterForfeit",
  "onCall",
]);
const TEST_HEADER = /^\[(PASS|FAIL)[^\]]*\] (test\w+)/;

// A frame's own result line is a direct child: its branch marker sits 4 columns right of the
// frame line's, as "└─ ← [Return]". Only "[Return]" and "[Stop]" count as completed; a revert or
// an out-of-gas frame is not a cost the callback has when it succeeds.
function frameCompleted(lines, index, column) {
  for (let j = index + 1; j < lines.length; j += 1) {
    if (lines[j].startsWith("└─ ← [", column + 4)) {
      return /← \[(Return|Stop)\]/.test(lines[j]);
    }
  }
  return false;
}

// A proxy frame prints as "fallback"; the callback is named on its delegatecall child.
function resolveName(lines, index, fn) {
  if (fn !== "fallback") return fn;
  const child = /\[\d+\] \w+::(\w+)\(.*\[delegatecall\]/.exec(
    lines[index + 1] ?? "",
  );
  return child ? child[1] : fn;
}

export function parseTrace(text) {
  const lines = text.split("\n");
  const frames = [];
  const slots = [];
  let skipped = 0;
  let test = "";
  for (let i = 0; i < lines.length; i += 1) {
    const header = TEST_HEADER.exec(lines[i]);
    if (header) {
      test = header[2];
      continue;
    }
    const slot = SLOTS.exec(lines[i]);
    if (slot) {
      slots.push({ test, label: slot[1], fn: slot[2], slots: Number(slot[3]) });
      continue;
    }
    const m = FRAME.exec(lines[i]);
    if (!m) continue;
    const [, prefix, , gas, label, rawFn] = m;
    const fn = resolveName(lines, i, rawFn);
    if (!frameCompleted(lines, i, prefix.length)) {
      skipped += 1;
      continue;
    }
    frames.push({ test, label, fn, gas: Number(gas) });
  }
  return { frames, slots, skipped };
}

// Pairs each successful frame with the new-slot count logged for it, in order within its test.
export function pair({ frames, slots }) {
  const queues = new Map();
  for (const s of slots) {
    const key = `${s.test}|${s.label}|${s.fn}`;
    if (!queues.has(key)) queues.set(key, []);
    queues.get(key).push(s.slots);
  }
  const unmatched = [];
  const paired = frames.map((f) => {
    const queue = queues.get(`${f.test}|${f.label}|${f.fn}`);
    if (!queue || queue.length === 0) {
      unmatched.push(f);
      return { ...f, newSlots: 0 };
    }
    return { ...f, newSlots: queue.shift() };
  });
  const leftover = [...queues.values()].reduce((n, q) => n + q.length, 0);
  return { paired, unmatched, leftover };
}

export function summarize(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  const median =
    sorted.length % 2
      ? sorted[mid]
      : Math.floor((sorted[mid - 1] + sorted[mid]) / 2);
  return {
    calls: sorted.length,
    min: sorted[0],
    median,
    max: sorted[sorted.length - 1],
  };
}

export function report(text) {
  const parsed = parseTrace(text);
  const { paired, unmatched, leftover } = pair(parsed);
  const summary = {};
  for (const f of paired) {
    const entry = ((summary[f.label] ??= {})[f.fn] ??= { eth: [], tempo: [] });
    entry.eth.push(f.gas);
    entry.tempo.push(f.gas + f.newSlots * TEMPO_NEW_SLOT_SURCHARGE);
  }
  const out = {};
  for (const [label, fns] of Object.entries(summary)) {
    out[label] = Object.fromEntries(
      Object.entries(fns).map(([fn, v]) => [
        fn,
        { ethereum: summarize(v.eth), tempo: summarize(v.tempo) },
      ]),
    );
  }
  return {
    skippedRevertedFrames: parsed.skipped,
    callbackFramesWithoutSlotCount: unmatched.filter((f) => CALLBACKS.has(f.fn))
      .length,
    slotCountsWithoutFrame: leftover,
    summary: out,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [path, flag] = process.argv.slice(2);
  if (!path) {
    console.error("usage: trace-gas.mjs <forge-log> [--json]");
    process.exit(2);
  }
  const result = report(readFileSync(path, "utf8"));
  if (flag === "--json") {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(
      `reverted frames skipped: ${result.skippedRevertedFrames}; callback frames without slot count: ${result.callbackFramesWithoutSlotCount}; slot counts without frame: ${result.slotCountsWithoutFrame}`,
    );
    for (const [label, fns] of Object.entries(result.summary)) {
      console.log(label);
      for (const [fn, s] of Object.entries(fns)) {
        console.log(
          `  ${fn.padEnd(20)} calls=${s.ethereum.calls} eth(min/med/max)=${s.ethereum.min}/${s.ethereum.median}/${s.ethereum.max} tempo(min/med/max)=${s.tempo.min}/${s.tempo.median}/${s.tempo.max}`,
        );
      }
    }
  }
}
