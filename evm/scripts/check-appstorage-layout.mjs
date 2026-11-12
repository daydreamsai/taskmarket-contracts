#!/usr/bin/env node
/**
 * Append-only check of the diamond's `AppStorage` (src/libraries/LibAppStorage.sol).
 *
 *   node scripts/check-appstorage-layout.mjs <forge-inspect.json>            compare with the snapshot
 *   node scripts/check-appstorage-layout.mjs <forge-inspect.json> --update   compare, then rewrite it
 *
 * `<forge-inspect.json>` (`-` reads stdin) is `forge inspect test/helpers/AppStorageLayout.sol:AppStorageLayout
 * storageLayout --json`. The committed snapshot is `appstorage-layout.snapshot.json` beside the
 * `src/` directory. `make contract evm storage-check` runs this.
 *
 * Rules (the diamond keeps every task's state in one fixed slot, so a moved field corrupts live state):
 *  - the `AppStorage` struct may only gain members at its end;
 *  - every other struct may only gain members at its end, and a struct that is the element of an
 *    array may not grow at all (the element stride would change);
 *  - an existing member keeps its label, slot, offset and type, so a resized static array, a
 *    changed mapping key or value, or a changed nested struct all fail;
 *  - no type that was in the snapshot may disappear.
 *
 * Compiler AST ids in type ids (`t_struct(Task)899_storage`) differ between compilers and builds,
 * so they are stripped; a static array length (`t_array(t_uint256)3_storage`) is kept.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SNAPSHOT = resolve(root, "appstorage-layout.snapshot.json");
const ROOT_TYPE = "t_struct(AppStorage)_storage";

const stripIds = (text) =>
  text.replace(/(t_(?:struct|enum|contract)\([\w.]+\))\d+/g, "$1");

export function normalize(raw) {
  const layout = JSON.parse(stripIds(raw));
  const holder = layout.storage.find((v) => v.type === ROOT_TYPE);
  if (!holder || layout.storage.length !== 1 || holder.slot !== "0") {
    throw new Error(
      `expected AppStorage as the only variable at slot 0, got ${JSON.stringify(layout.storage)}`,
    );
  }
  const types = {};
  for (const id of Object.keys(layout.types).sort()) {
    const t = layout.types[id];
    types[id] = {
      label: t.label,
      encoding: t.encoding,
      numberOfBytes: t.numberOfBytes,
      ...(t.base ? { base: t.base } : {}),
      ...(t.key ? { key: t.key } : {}),
      ...(t.value ? { value: t.value } : {}),
      ...(t.members
        ? {
            members: t.members.map((m) => ({
              label: m.label,
              slot: m.slot,
              offset: m.offset,
              type: m.type,
            })),
          }
        : {}),
    };
  }
  return { types };
}

export function compare(before, after) {
  const errors = [];
  const arrayElements = new Set();
  for (const t of Object.values(after.types)) {
    if (t.base) arrayElements.add(t.base);
  }
  for (const [id, old] of Object.entries(before.types)) {
    const cur = after.types[id];
    if (!cur) {
      errors.push(`type ${id} (${old.label}) is gone`);
      continue;
    }
    for (const k of ["label", "encoding", "base", "key", "value"]) {
      if (old[k] !== cur[k])
        errors.push(`${id}: ${k} changed from ${old[k]} to ${cur[k]}`);
    }
    if (!old.members) continue;
    const curMembers = cur.members ?? [];
    old.members.forEach((m, i) => {
      const c = curMembers[i];
      if (!c) {
        errors.push(`${id}: member ${i} (${m.label}) was removed`);
      } else if (
        c.label !== m.label ||
        c.slot !== m.slot ||
        c.offset !== m.offset ||
        c.type !== m.type
      ) {
        errors.push(
          `${id}: member ${i} changed from ${m.label} (slot ${m.slot}, offset ${m.offset}, ${m.type}) ` +
            `to ${c.label} (slot ${c.slot}, offset ${c.offset}, ${c.type})`,
        );
      }
    });
    if (curMembers.length > old.members.length && arrayElements.has(id)) {
      errors.push(
        `${id}: grew while used as an array element, which moves every later element`,
      );
    }
  }
  return errors;
}

function main() {
  const [input, flag] = process.argv.slice(2);
  if (!input) {
    console.error(
      "usage: check-appstorage-layout.mjs <forge-inspect.json> [--update]",
    );
    process.exit(2);
  }
  const after = normalize(readFileSync(input === "-" ? 0 : input, "utf8"));
  let committed = null;
  try {
    committed = readFileSync(SNAPSHOT, "utf8");
  } catch {
    // no snapshot yet
  }
  if (committed === null && flag !== "--update") {
    console.error(
      "Error: appstorage-layout.snapshot.json is missing; run with --update to create it.",
    );
    process.exit(1);
  }
  if (committed !== null) {
    const errors = compare(JSON.parse(committed), after);
    if (errors.length) {
      console.error(
        "Error: AppStorage layout is not append-only against appstorage-layout.snapshot.json:",
      );
      for (const e of errors) console.error(`  - ${e}`);
      console.error(
        "Append new fields at the END of the struct; never insert, reorder, resize or remove.",
      );
      process.exit(1);
    }
  }
  const next = `${JSON.stringify(after, null, 2)}\n`;
  if (flag === "--update") {
    writeFileSync(SNAPSHOT, next);
    console.log("appstorage-layout.snapshot.json updated");
  } else if (next !== committed) {
    console.error(
      "Error: AppStorage gained fields that are not in appstorage-layout.snapshot.json.",
    );
    console.error(
      "Run: node scripts/check-appstorage-layout.mjs <forge-inspect.json> --update, and commit it.",
    );
    process.exit(1);
  } else {
    console.log("AppStorage: layout matches the snapshot (append-only)");
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
