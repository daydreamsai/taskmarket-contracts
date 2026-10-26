#!/usr/bin/env tsx
/**
 * Asserts that every existing slot in storage-layout.before.json appears at the
 * same slot index in storage-layout.after.json — appending new state is fine,
 * reordering or removing existing state is not (UUPS upgrade hazard).
 *
 * Internal Solidity type IDs (e.g. `t_struct(Task)4574_storage`) are stripped
 * before comparison because they change on every recompile without affecting
 * actual storage layout.
 *
 * Run via:  cd packages/contracts && tsx scripts/verify-storage-layout.ts
 */
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

type StorageEntry = { slot: string; label: string; type: string; offset: number };
type StorageLayout = { storage: StorageEntry[] };

const root = dirname(fileURLToPath(import.meta.url));
const before: StorageLayout = JSON.parse(
  readFileSync(resolve(root, '..', 'storage-layout.before.json'), 'utf8')
);
const after: StorageLayout = JSON.parse(
  readFileSync(resolve(root, '..', 'storage-layout.after.json'), 'utf8')
);

function normaliseType(t: string): string {
  // Drop internal struct/contract type IDs that vary across compiles.
  // `t_struct(Task)4574_storage` → `t_struct(Task)_storage`
  return t.replace(/(\(\w+\))\d+_storage/g, '$1_storage');
}

function keyOf(entry: StorageEntry): string {
  return `slot=${entry.slot}|offset=${entry.offset}|label=${entry.label}|type=${normaliseType(
    entry.type
  )}`;
}

// `__gap` is intentionally consumable — it can shrink and move as we append
// new state variables. Compare its size separately.
const beforeNonGap = before.storage.filter((e) => e.label !== '__gap');
const afterNonGap = after.storage.filter((e) => e.label !== '__gap');
const beforeKeys = new Set(beforeNonGap.map(keyOf));
const afterKeys = new Set(afterNonGap.map(keyOf));

const missing = [...beforeKeys].filter((k) => !afterKeys.has(k));
const added = [...afterKeys].filter((k) => !beforeKeys.has(k));

function gapSize(layout: StorageLayout): number {
  const gap = layout.storage.find((e) => e.label === '__gap');
  if (!gap) return 0;
  const m = gap.type.match(/t_array\(t_uint256\)(\d+)_storage/);
  return m ? Number(m[1]) : 0;
}

const beforeGap = gapSize(before);
const afterGap = gapSize(after);
if (afterGap > beforeGap) {
  console.error(`__gap grew from ${beforeGap} to ${afterGap} — that should be impossible.`);
  process.exit(1);
}

if (missing.length > 0) {
  console.error('Storage layout drift — these slots from BEFORE are missing or moved in AFTER:');
  for (const k of missing) console.error('  -', k);
  process.exit(1);
}

console.log(`Storage layout verified: ${beforeKeys.size} existing slots unchanged.`);
console.log(`__gap: ${beforeGap} → ${afterGap} (${beforeGap - afterGap} slots consumed).`);
if (added.length > 0) {
  console.log(`New slots appended: ${added.length}`);
  for (const k of added) console.log('  +', k);
}
