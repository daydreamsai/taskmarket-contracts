import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { compare } from "../../scripts/check-appstorage-layout.mjs";

const snapshotPath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../../appstorage-layout.snapshot.json",
);
const load = () => JSON.parse(readFileSync(snapshotPath, "utf8"));
const ROOT = "t_struct(AppStorage)_storage";
const member = (label, slot) => ({
  label,
  slot: String(slot),
  offset: 0,
  type: "t_uint256",
});

test("the unchanged layout passes", () => {
  assert.deepEqual(compare(load(), load()), []);
});

test("appending a field to AppStorage passes", () => {
  const after = load();
  const m = after.types[ROOT].members;
  m.push(member("appended", Number(m.at(-1).slot) + 1));
  assert.deepEqual(compare(load(), after), []);
});

test("inserting, reordering or removing a field fails", () => {
  const inserted = load();
  inserted.types[ROOT].members.splice(3, 0, member("inserted", 3));
  assert.notEqual(compare(load(), inserted).length, 0);

  const reordered = load();
  const m = reordered.types[ROOT].members;
  [m[1], m[2]] = [m[2], m[1]];
  assert.notEqual(compare(load(), reordered).length, 0);

  const removed = load();
  removed.types[ROOT].members.pop();
  assert.notEqual(compare(load(), removed).length, 0);
});

test("a changed type, nested struct member or resized array fails", () => {
  const retyped = load();
  retyped.types[ROOT].members[0].type = "t_uint256";
  assert.notEqual(compare(load(), retyped).length, 0);

  const nested = load();
  const structId = Object.keys(nested.types).find(
    (id) => id !== ROOT && nested.types[id].members?.length > 1,
  );
  nested.types[structId].members.splice(0, 1);
  assert.notEqual(compare(load(), nested).length, 0);

  const before = load();
  before.types["t_array(t_uint256)3_storage"] = {
    label: "uint256[3]",
    encoding: "inplace",
    numberOfBytes: "96",
    base: "t_uint256",
  };
  const after = structuredClone(before);
  delete after.types["t_array(t_uint256)3_storage"];
  after.types["t_array(t_uint256)4_storage"] = {
    ...before.types["t_array(t_uint256)3_storage"],
    label: "uint256[4]",
  };
  assert.notEqual(compare(before, after).length, 0);
});

test("a struct used as an array element may not grow", () => {
  const before = load();
  before.types.t_struct_elem = {
    label: "struct E",
    encoding: "inplace",
    numberOfBytes: "32",
    members: [member("a", 0)],
  };
  before.types["t_array(t_struct_elem)dyn_storage"] = {
    label: "struct E[]",
    encoding: "dynamic_array",
    numberOfBytes: "32",
    base: "t_struct_elem",
  };
  const after = structuredClone(before);
  after.types.t_struct_elem.members.push(member("b", 1));
  assert.equal(compare(before, after).length, 1);
});
