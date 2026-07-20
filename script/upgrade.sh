#!/usr/bin/env bash
# Diamond upgrade orchestrator -- run via `make upgrade <testnet|mainnet> [revNNN]`.
#
# With no revision argument, applies every not-yet-applied upgrade step in sequence:
#   1. If the diamond has never had diamondVersion tracked (pre-rev011), runs the legacy
#      DiamondFullUpgrade.s.sol bootstrap first (it auto-detects and migrates from whichever
#      historical selector state the diamond is actually in, then sets diamondVersion to 11).
#   2. Then applies every script/upgrades/RevNNNUpgrade.s.sol whose target revision is greater
#      than the diamond's current diamondVersion, in ascending order.
#
# With an explicit revision argument (e.g. "rev012"), runs only that one step's script directly
# -- useful for a controlled single-step apply. Each step script asserts its own precondition
# (the diamond must be at the expected prior version) and reverts rather than silently
# re-applying or skipping ahead.
#
# Adding a new revision requires no changes to this script or the Makefile: drop a new
# script/upgrades/RevNNNUpgrade.s.sol file (contract name RevNNNUpgrade) and it is picked up
# automatically on the next `make upgrade` run.
set -euo pipefail

NETWORK="$1"
REV="${2:-}"

if [ "$NETWORK" = "testnet" ]; then
  RPC_URL="base_sepolia"
  DIAMOND="${FORGE_DIAMOND_ADDRESS_TESTNET:?FORGE_DIAMOND_ADDRESS_TESTNET not set}"
elif [ "$NETWORK" = "mainnet" ]; then
  RPC_URL="base"
  DIAMOND="${FORGE_DIAMOND_ADDRESS_MAINNET:?FORGE_DIAMOND_ADDRESS_MAINNET not set}"
else
  echo "Usage: script/upgrade.sh <testnet|mainnet> [revNNN]" >&2
  exit 1
fi

run_script() {
  forge script "$1" --rpc-url "$RPC_URL" --broadcast --verify
}

current_version() {
  cast call "$DIAMOND" "diamondVersion()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]' || echo 0
}

# Explicit single-step target, e.g. "rev012" -> Rev012Upgrade.
if [ -n "$REV" ]; then
  NAME="$(printf '%s' "${REV:0:1}" | tr '[:lower:]' '[:upper:]')${REV:1}Upgrade"
  echo "Applying $NAME directly..."
  run_script "script/upgrades/${NAME}.s.sol:${NAME}"
  exit 0
fi

VERSION="$(current_version)"
if [ -z "$VERSION" ] || [ "$VERSION" = "0" ]; then
  echo "diamondVersion is untracked (pre-rev011) -- running legacy bootstrap..."
  run_script "script/DiamondFullUpgrade.s.sol:DiamondFullUpgrade"
  VERSION="$(current_version)"
fi

shopt -s nullglob
for f in $(printf '%s\n' script/upgrades/Rev*Upgrade.s.sol | sort); do
  NAME="$(basename "$f" .s.sol)"
  TARGET="$(printf '%s' "$NAME" | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')"
  if [ "$TARGET" -gt "$VERSION" ]; then
    echo "Applying $NAME (target rev $TARGET, current rev $VERSION)..."
    run_script "script/upgrades/${NAME}.s.sol:${NAME}"
    VERSION="$(current_version)"
  fi
done

echo "Diamond $DIAMOND is now at rev $VERSION."
