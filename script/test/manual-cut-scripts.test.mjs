// Every diamond cut outside script/upgrades/ must be one of a short, reviewed list. Facet upgrades
// go through the versioned RevNNNUpgrade steps, which build their selector lists from
// script/lib/FacetSelectors.sol and assert the diamond's revision. A free-standing script with
// its own hard-coded selector list goes stale the moment a revision moves a selector to another
// facet, and then routes that selector to a facet that no longer implements it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");

// DiamondDeploy cuts a fresh diamond from FacetSelectors. DiamondUpgradeAcceptPinning swaps one
// AcceptanceFacet selector it names itself.
const ALLOWED = ["DiamondDeploy.s.sol", "DiamondUpgradeAcceptPinning.s.sol"];

test("only reviewed top-level scripts call diamondCut", () => {
  const cutters = readdirSync(SCRIPT_DIR)
    .filter((f) => f.endsWith(".s.sol"))
    .filter((f) =>
      /\.diamondCut\(/.test(readFileSync(join(SCRIPT_DIR, f), "utf8")),
    )
    .sort();
  assert.deepEqual(cutters, ALLOWED);
});
