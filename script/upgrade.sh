#!/usr/bin/env bash
# Diamond upgrade orchestrator -- run via
# `make upgrade <testnet|mainnet|tempo-testnet|tempo-mainnet> [revNNN]`.
#
# With no revision argument, applies every script/upgrades/RevNNNUpgrade.s.sol whose target
# revision is greater than the diamond's current diamondVersion, in ascending order.
#
# A freshly deployed diamond seeds diamondVersion from LibRevision.CURRENT_REVISION, so it is
# already at the current revision and this script correctly finds nothing pending. Rev020 removed
# the pre-rev011 bootstrap that used to run when diamondVersion read 0: no such diamond exists,
# and one that did would now have to be cut forward by hand.
#
# With an explicit revision argument (e.g. "rev012"), runs only that one step's script directly
# -- useful for a controlled single-step apply. Each step script asserts its own precondition
# (the diamond must be at the expected prior version) and reverts rather than silently
# re-applying or skipping ahead.
#
# Adding a new revision requires no changes to this script or the Makefile: drop a new
# script/upgrades/RevNNNUpgrade.s.sol file (contract name RevNNNUpgrade) and it is picked up
# automatically on the next `make upgrade` run.
#
# Set DRY_RUN=1 to simulate against live chain state without broadcasting (forge script's
# normal dry-run behavior when --broadcast is omitted). Only the first pending step is
# simulated: a dry run never actually advances diamondVersion on-chain, so any step after the
# first would simulate against the same pre-upgrade state and fail its own precondition check
# -- each step can only be meaningfully previewed once the one before it has actually broadcast.
set -euo pipefail

NETWORK="$1"
REV="${2:-}"
DRY_RUN="${DRY_RUN:-0}"

if [ "$NETWORK" = "testnet" ]; then
  RPC_URL="base_sepolia"
  DIAMOND="${FORGE_DIAMOND_ADDRESS_TESTNET:?FORGE_DIAMOND_ADDRESS_TESTNET not set}"
elif [ "$NETWORK" = "mainnet" ]; then
  RPC_URL="base"
  DIAMOND="${FORGE_DIAMOND_ADDRESS_MAINNET:?FORGE_DIAMOND_ADDRESS_MAINNET not set}"
elif [ "$NETWORK" = "tempo-testnet" ]; then
  RPC_URL="tempo_moderato"
  DIAMOND="${FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET:?FORGE_DIAMOND_ADDRESS_TEMPO_TESTNET not set}"
elif [ "$NETWORK" = "tempo-mainnet" ]; then
  RPC_URL="tempo"
  DIAMOND="${FORGE_DIAMOND_ADDRESS_TEMPO_MAINNET:?FORGE_DIAMOND_ADDRESS_TEMPO_MAINNET not set}"
else
  echo "Usage: script/upgrade.sh <testnet|mainnet|tempo-testnet|tempo-mainnet> [revNNN]" >&2
  exit 1
fi

# Tempo pays gas in a TIP-20 stablecoin and verifies through Sourcify rather than Etherscan.
NETWORK_FLAGS=()
VERIFY_FLAGS=(--verify)
case "$NETWORK" in
  tempo-*)
    export FOUNDRY_PROFILE=tempo
    NETWORK_FLAGS=(--tempo.fee-token "${FORGE_FEE_TOKEN:?FORGE_FEE_TOKEN (or FORGE_FEE_TOKEN_TEMPO_*) not set}")
    VERIFY_FLAGS=(--verify --verifier sourcify --verifier-url https://contracts.tempo.xyz)
    ;;
esac

run_script() {
  if [ "$DRY_RUN" = "1" ]; then
    forge script "$1" --rpc-url "$RPC_URL" ${NETWORK_FLAGS[@]+"${NETWORK_FLAGS[@]}"}
  else
    forge script "$1" --rpc-url "$RPC_URL" ${NETWORK_FLAGS[@]+"${NETWORK_FLAGS[@]}"} --broadcast "${VERIFY_FLAGS[@]}"
  fi
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
  echo "diamondVersion reads 0, or could not be read, for $DIAMOND on $RPC_URL." >&2
  echo "No automated migration exists for an untracked (pre-rev011) diamond -- the cut would have" >&2
  echo "to be reconstructed by hand. Check the address and the network before doing anything else." >&2
  exit 1
fi

shopt -s nullglob
for f in $(printf '%s\n' script/upgrades/Rev*Upgrade.s.sol | sort); do
  NAME="$(basename "$f" .s.sol)"
  TARGET="$(printf '%s' "$NAME" | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')"
  if [ "$TARGET" -gt "$VERSION" ]; then
    echo "Applying $NAME (target rev $TARGET, current rev $VERSION)..."
    run_script "script/upgrades/${NAME}.s.sol:${NAME}"
    if [ "$DRY_RUN" = "1" ]; then
      echo "Dry run: stopping after the first pending step ($NAME) -- later steps can't be simulated until this one actually broadcasts."
      exit 0
    fi
    VERSION="$(current_version)"
  fi
done

echo "Diamond $DIAMOND is now at rev $VERSION."
