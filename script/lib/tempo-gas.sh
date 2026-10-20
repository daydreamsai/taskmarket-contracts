# Sourced by script/tempo.sh and script/upgrade.sh on the Tempo path.
#
# Tempo rejects any transaction whose gas limit exceeds 30,000,000. Forge sets each limit at its
# --gas-estimate-multiplier (130% by default) of the node's estimate, and its own simulated gas
# can sit far below that estimate, so neither a plain dry run nor the default multiplier keeps a
# deploy under the cap. tempo_gas_preflight simulates the script against a local anvil fork of the
# chain, asks the fork's node for eth_estimateGas on every transaction in that simulation (each
# against the state the earlier ones leave; script/lib/tempo-gas-check.sh), refuses when any is
# >= TEMPO_GAS_LIMIT_MAX (29,900,000), and otherwise sets TEMPO_GAS_FLAGS to the multiplier that
# keeps every limit at or below it. Nothing is sent to the live chain.
#
# Usage: tempo_gas_preflight <forge-script-target> <upstream-rpc-url> [forge flags...]
TEMPO_GAS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPO_GAS_FLAGS=()

tempo_gas_preflight() {
  local target="$1" upstream="$2"
  shift 2
  local port="${TEMPO_GAS_FORK_PORT:-8599}"
  local fork="http://127.0.0.1:$port"
  local file="${target%%:*}"
  local log out pid rc=0
  log="$(mktemp)"
  out="$(mktemp)"

  echo "Tempo gas check: simulating $(basename "$file") on a local fork and reading node estimates..."
  anvil --fork-url "$upstream" --network tempo --auto-impersonate \
    --base-fee 0 --gas-price 0 --disable-min-priority-fee --port "$port" >"$log" 2>&1 &
  pid=$!
  _tempo_gas_run "$pid" "$target" "$fork" "$file" "$log" "$out" "$@" || rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$log" "$out"
  return "$rc"
}

_tempo_gas_run() {
  local pid="$1" target="$2" fork="$3" file="$4" log="$5" out="$6"
  shift 6
  local chain="" record i rc=0
  for i in $(seq 1 "${TEMPO_GAS_FORK_WAIT:-60}"); do
    chain="$(cast chain-id --rpc-url "$fork" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$chain" ] && break
    sleep 1
  done
  # Something else answering on the port (our anvil having exited) would be estimated against
  # the wrong state; TEMPO_GAS_FORK_PORT picks another port.
  if [ -z "$chain" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "Tempo gas check: the local fork at $fork did not start:" >&2
    tail -5 "$log" >&2
    return 1
  fi

  record="broadcast/$(basename "$file")/$chain/dry-run/run-latest.json"
  rm -f "$record"
  if ! forge script "$target" --rpc-url "$fork" "$@"; then
    echo "Tempo gas check: the simulation on the local fork failed; nothing was broadcast." >&2
    return 1
  fi
  "$TEMPO_GAS_LIB_DIR/tempo-gas-check.sh" "$record" "$fork" >"$out" || rc=$?
  cat "$out"
  [ "$rc" = "0" ] || return 1
  local multiplier
  multiplier="$(sed -n 's/^TEMPO_GAS_MULTIPLIER=//p' "$out")"
  [ -n "$multiplier" ] || { echo "Tempo gas check produced no multiplier." >&2; return 1; }
  TEMPO_GAS_FLAGS=(--gas-estimate-multiplier "$multiplier")
}

# The RPC URL behind a foundry.toml Tempo alias (anvil cannot read forge's aliases).
tempo_rpc_url() {
  case "$1" in
    tempo_moderato) printf '%s' "${FORGE_TEMPO_MODERATO_RPC_URL:?FORGE_TEMPO_MODERATO_RPC_URL not set}" ;;
    tempo) printf '%s' "${FORGE_TEMPO_RPC_URL:?FORGE_TEMPO_RPC_URL not set}" ;;
    *) echo "Unknown Tempo RPC alias $1" >&2; return 1 ;;
  esac
}
