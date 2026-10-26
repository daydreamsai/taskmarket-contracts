#!/usr/bin/env bash
# Diamond upgrade orchestrator -- run via
# `make upgrade <84532|8453|42431|4217|4663|46630> [revNNN]`.
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
# Rev024 is never applied on its own. Its step deploys today's CoreFacet, which no longer
# implements cancelTask, refundExpired, rejectSubmission and forfeitAndReopen (rev025 moved them
# to SettlementFacet), yet still routes those selectors to it; only Rev025 routes them back. So an
# explicit "rev024" argument is refused, a pending run that would end at Rev024 is refused before
# anything broadcasts, and if Rev024's cut lands but its command fails afterwards (for example on
# block-explorer verification) the run carries on to Rev025 instead of stopping in between.
#
# Adding a new revision requires no changes to this script or the Makefile: drop a new
# script/upgrades/RevNNNUpgrade.s.sol file (contract name RevNNNUpgrade) and it is picked up
# automatically on the next `make upgrade` run.
#
# Set DRY_RUN=1 (or any non-empty value other than 0 or false, such as true or yes) to simulate against live chain state without broadcasting (forge script's
# normal dry-run behavior when --broadcast is omitted). Only the first pending step is
# simulated against the live chain: a dry run never advances diamondVersion on-chain, so a later
# step would fail its own precondition check there. On Tempo the gas check below still replays
# and reports every pending step on a local fork, where each step sees the ones before it.
#
# On Tempo, before anything is broadcast, every step the run would apply is simulated in order on
# one local fork and each transaction's node estimate is checked against Tempo's 30M cap
# (script/lib/tempo-gas.sh). A step over the cap anywhere in the run refuses the whole run, so a
# refusal of Rev025 cannot land after Rev024 has broadcast.
set -euo pipefail

NETWORK="$1"
REV="${2:-}"
case "$(printf '%s' "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')" in
  ""|0|false) DRY_RUN=0 ;;
  *) DRY_RUN=1 ;;
esac

if [ "$NETWORK" = "84532" ]; then
  RPC_URL="84532"
  CHAIN_ID=84532
  DIAMOND="${FORGE_DIAMOND_ADDRESS_84532:?FORGE_DIAMOND_ADDRESS_84532 not set}"
elif [ "$NETWORK" = "8453" ]; then
  RPC_URL="8453"
  CHAIN_ID=8453
  DIAMOND="${FORGE_DIAMOND_ADDRESS_8453:?FORGE_DIAMOND_ADDRESS_8453 not set}"
elif [ "$NETWORK" = "42431" ]; then
  RPC_URL="42431"
  CHAIN_ID=42431
  DIAMOND="${FORGE_DIAMOND_ADDRESS_42431:?FORGE_DIAMOND_ADDRESS_42431 not set}"
elif [ "$NETWORK" = "4217" ]; then
  RPC_URL="4217"
  CHAIN_ID=4217
  DIAMOND="${FORGE_DIAMOND_ADDRESS_4217:?FORGE_DIAMOND_ADDRESS_4217 not set}"
elif [ "$NETWORK" = "4663" ]; then
  RPC_URL="4663"
  CHAIN_ID=4663
  DIAMOND="${FORGE_DIAMOND_ADDRESS_4663:?FORGE_DIAMOND_ADDRESS_4663 not set}"
elif [ "$NETWORK" = "46630" ]; then
  RPC_URL="46630"
  CHAIN_ID=46630
  DIAMOND="${FORGE_DIAMOND_ADDRESS_46630:?FORGE_DIAMOND_ADDRESS_46630 not set}"
else
  echo "Usage: script/upgrade.sh <84532|8453|42431|4217|4663|46630> [revNNN]" >&2
  exit 1
fi

# Tempo pays gas in a TIP-20 stablecoin and verifies through Sourcify rather than Etherscan.
NETWORK_FLAGS=()
VERIFY_FLAGS=(--verify)
BROADCAST_FLAGS=()
case "$NETWORK" in
  42431|4217)
    export FOUNDRY_PROFILE=tempo
    # shellcheck source=lib/tempo-gas.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lib/tempo-gas.sh"
    tempo_gas_require_tools || exit 1
    trap tempo_gas_fork_stop EXIT
    NETWORK_FLAGS=(--tempo.fee-token "${FORGE_FEE_TOKEN:?FORGE_FEE_TOKEN (or FORGE_FEE_TOKEN_TEMPO_*) not set}")
    VERIFY_FLAGS=(--verify --verifier sourcify --verifier-url https://contracts.tempo.xyz)
    # --slow sends each transaction only once the one before it is mined: a diamondCut whose
    # gas is estimated before its facets exist runs out of gas.
    BROADCAST_FLAGS=(--slow)
    ;;
esac

# Refuse to run any step when the RPC answers for a different chain than the network named.
ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
  echo "Refusing to run: $RPC_URL reports chain ID '${ACTUAL_CHAIN_ID:-unreadable}', expected $CHAIN_ID for $NETWORK." >&2
  echo "Check the RPC URL behind the $RPC_URL alias in foundry.toml before retrying." >&2
  exit 1
fi

# Tempo: tempo_check_steps replays every given step in order on one local fork before anything
# broadcasts and records each step's gas multiplier in STEP_MULTIPLIER (same order as its
# arguments). It exits the run if any step fails the check.
STEP_NAMES=()
STEP_MULTIPLIER=()
tempo_check_steps() {
  local name summary=""
  tempo_gas_fork_start "$(tempo_rpc_url "$RPC_URL")" || exit 1
  for name in "$@"; do
    if ! tempo_gas_check "script/upgrades/${name}.s.sol:${name}" ${NETWORK_FLAGS[@]+"${NETWORK_FLAGS[@]}"}; then
      tempo_gas_fork_stop
      echo "Refusing to run: $name failed the Tempo gas check; no step of this run was broadcast." >&2
      exit 1
    fi
    STEP_NAMES+=("$name")
    STEP_MULTIPLIER+=("${TEMPO_GAS_FLAGS[1]}")
    summary="${summary}  ${name}: largest node estimate ${TEMPO_GAS_LARGEST}, multiplier ${TEMPO_GAS_FLAGS[1]}"$'\n'
  done
  tempo_gas_fork_stop
  echo "Tempo gas check passed for every step of this run, in order on one fork:"
  printf '%s' "$summary"
}

run_script() {
  local name="${1##*:}" i gas=()
  for i in ${STEP_NAMES[@]+"${!STEP_NAMES[@]}"}; do
    [ "${STEP_NAMES[$i]}" = "$name" ] && gas=(--gas-estimate-multiplier "${STEP_MULTIPLIER[$i]}")
  done
  case "$NETWORK" in
    42431|4217) [ "${#gas[@]}" -gt 0 ] || { echo "$name has no Tempo gas check result." >&2; return 1; } ;;
  esac
  if [ "$DRY_RUN" = "1" ]; then
    forge script "$1" --rpc-url "$RPC_URL" ${NETWORK_FLAGS[@]+"${NETWORK_FLAGS[@]}"} ${gas[@]+"${gas[@]}"}
  else
    forge script "$1" --rpc-url "$RPC_URL" ${NETWORK_FLAGS[@]+"${NETWORK_FLAGS[@]}"} ${gas[@]+"${gas[@]}"} --broadcast ${BROADCAST_FLAGS[@]+"${BROADCAST_FLAGS[@]}"} "${VERIFY_FLAGS[@]}"
  fi
}

# Reads diamondVersion, retrying a failed or malformed read. Prints the version and succeeds, or
# fails without printing anything: a read that never succeeded says nothing about the diamond, so
# no caller may treat it as "0" or "not landed".
VERSION_READ_ATTEMPTS="${UPGRADE_VERSION_READ_ATTEMPTS:-5}"
VERSION_READ_DELAY="${UPGRADE_VERSION_READ_DELAY:-3}"
read_version_once() {
  local out
  out="$(cast call "$DIAMOND" "diamondVersion()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null)" || return 1
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  case "$out" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$out"
}
current_version() {
  local attempt v
  for attempt in $(seq 1 "$VERSION_READ_ATTEMPTS"); do
    if v="$(read_version_once)"; then
      printf '%s\n' "$v"
      return 0
    fi
    [ "$attempt" -lt "$VERSION_READ_ATTEMPTS" ] && sleep "$VERSION_READ_DELAY"
  done
  return 1
}
# Reads diamondVersion until it shows at least $1, so a node that has not caught up with a cut
# that just landed is not mistaken for one that never landed. Prints the last successful read
# (empty when every read failed); succeeds only once the version reached $1.
version_reaching() {
  local want="$1" attempt v last=""
  for attempt in $(seq 1 "$VERSION_READ_ATTEMPTS"); do
    if v="$(read_version_once)"; then
      last="$v"
      if [ "$v" -ge "$want" ]; then
        printf '%s\n' "$v"
        return 0
      fi
    fi
    [ "$attempt" -lt "$VERSION_READ_ATTEMPTS" ] && sleep "$VERSION_READ_DELAY"
  done
  printf '%s\n' "$last"
  return 1
}
recovery_hint() {
  echo "Read it by hand before doing anything else:" >&2
  echo "  cast call $DIAMOND 'diamondVersion()(uint256)' --rpc-url $RPC_URL" >&2
  echo "then resume with 'make upgrade $NETWORK' (no revision argument): it applies every step" >&2
  echo "above the version the diamond actually holds, Rev025 included." >&2
}

# Explicit single-step target, e.g. "rev012" -> Rev012Upgrade.
if [ -n "$REV" ]; then
  if [ "$(printf '%s' "$REV" | tr '[:upper:]' '[:lower:]')" = "rev024" ]; then
    echo "Refusing to apply rev024 on its own: it leaves cancelTask, refundExpired, rejectSubmission" >&2
    echo "and forfeitAndReopen routed to a CoreFacet that lacks them until Rev025 lands. Run" >&2
    echo "'make upgrade $NETWORK' with no revision argument to apply Rev024 and Rev025 in one run." >&2
    exit 1
  fi
  NAME="$(printf '%s' "${REV:0:1}" | tr '[:lower:]' '[:upper:]')${REV:1}Upgrade"
  case "$NETWORK" in 42431|4217) tempo_check_steps "$NAME" ;; esac
  echo "Applying $NAME directly..."
  run_script "script/upgrades/${NAME}.s.sol:${NAME}"
  exit 0
fi

if ! VERSION="$(current_version)"; then
  echo "diamondVersion could not be read for $DIAMOND on $RPC_URL after $VERSION_READ_ATTEMPTS attempts;" >&2
  echo "nothing was applied." >&2
  recovery_hint
  exit 1
fi
if [ "$VERSION" = "0" ]; then
  echo "diamondVersion reads 0 for $DIAMOND on $RPC_URL." >&2
  echo "No automated migration exists for an untracked (pre-rev011) diamond -- the cut would have" >&2
  echo "to be reconstructed by hand. Check the address and the network before doing anything else." >&2
  exit 1
fi

shopt -s nullglob
PENDING=()
for f in $(printf '%s\n' script/upgrades/Rev*Upgrade.s.sol | sort); do
  NAME="$(basename "$f" .s.sol)"
  TARGET="$(printf '%s' "$NAME" | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')"
  if [ "$TARGET" -gt "$VERSION" ]; then
    PENDING+=("$NAME")
  fi
done

# Refuse, before anything broadcasts, a run whose last step would be Rev024.
if [ "${#PENDING[@]}" -gt 0 ] && [ "${PENDING[${#PENDING[@]}-1]}" = "Rev024Upgrade" ]; then
  echo "Refusing to run: Rev024Upgrade would be the last step, but Rev024 must always be followed by" >&2
  echo "Rev025Upgrade in the same run (script/upgrades/Rev025Upgrade.s.sol is missing)." >&2
  exit 1
fi

case "$NETWORK" in
  42431|4217) [ "${#PENDING[@]}" -gt 0 ] && tempo_check_steps "${PENDING[@]}" ;;
esac

for NAME in ${PENDING[@]+"${PENDING[@]}"}; do
  TARGET="$(printf '%s' "$NAME" | grep -oE '[0-9]+' | head -1 | sed 's/^0*//')"
  if [ "$TARGET" -gt "$VERSION" ]; then
    echo "Applying $NAME (target rev $TARGET, current rev $VERSION)..."
    if [ "$NAME" = "Rev024Upgrade" ] && [ "$DRY_RUN" != "1" ]; then
      if ! run_script "script/upgrades/${NAME}.s.sol:${NAME}"; then
        if LANDED="$(version_reaching 24)"; then
          echo "Rev024Upgrade's cut landed but the command failed afterwards (likely verification);" >&2
          echo "continuing to Rev025Upgrade. Verify the Rev024 contracts by hand afterwards." >&2
        elif [ -z "$LANDED" ]; then
          echo "Rev024Upgrade failed and diamondVersion could not be read afterwards, so whether its" >&2
          echo "cut landed is unknown. If it did, the diamond is half-cut until Rev025 lands." >&2
          recovery_hint
          exit 1
        else
          echo "Rev024Upgrade failed and diamondVersion still reads $LANDED after $VERSION_READ_ATTEMPTS reads;" >&2
          echo "its cut most likely did not land, but a lagging node can show the same." >&2
          recovery_hint
          exit 1
        fi
      fi
    else
      run_script "script/upgrades/${NAME}.s.sol:${NAME}"
    fi
    if [ "$DRY_RUN" = "1" ]; then
      case "$NETWORK" in
        42431|4217) echo "Dry run: every pending step passed the gas check on a local fork (above); only the first ($NAME) was simulated against the live chain." ;;
        *) echo "Dry run: stopping after the first pending step ($NAME) -- later steps can't be simulated until this one actually broadcasts." ;;
      esac
      exit 0
    fi
    if ! VERSION="$(version_reaching "$TARGET")"; then
      echo "$NAME succeeded, but diamondVersion reads '${VERSION:-unreadable}' instead of $TARGET;" >&2
      echo "stopping rather than running the next step against a stale version." >&2
      recovery_hint
      exit 1
    fi
  fi
done

echo "Diamond $DIAMOND is now at rev $VERSION."
