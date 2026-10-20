# Sourced by script/tempo.sh and script/upgrade.sh on the Tempo path.
#
# Tempo rejects any transaction whose gas limit exceeds 30,000,000. Forge sets each limit at its
# --gas-estimate-multiplier (130% by default) of the node's estimate, and its own simulated gas
# can sit far below that estimate, so neither a plain dry run nor the default multiplier keeps a
# deploy under the cap. The functions here simulate scripts against one local anvil fork of the
# chain, ask the fork's node for eth_estimateGas on every transaction of each simulation (each
# against the state the earlier ones leave, including earlier scripts on the same fork;
# script/lib/tempo-gas-check.sh), refuse when any is >= 29,900,000, and otherwise give each script
# the multiplier that keeps its limits under the cap with room for the live node's estimate to
# run a little above the fork's. Nothing is sent to the live chain.
#
#   tempo_gas_require_tools            refuse unless anvil and jq are on PATH
#   tempo_gas_fork_start <upstream>    start the fork on a free port (TEMPO_GAS_FORK_PORT overrides)
#   tempo_gas_check <target> [flags]   simulate one script on the fork; sets TEMPO_GAS_FLAGS and
#                                      TEMPO_GAS_LARGEST
#   tempo_gas_fork_stop                stop the fork and wait until its port is free
#   tempo_gas_preflight <target> <upstream> [flags]   start, check one script, stop
TEMPO_GAS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPO_GAS_FLAGS=()
TEMPO_GAS_LARGEST=""
TEMPO_GAS_FORK_PID=""
TEMPO_GAS_FORK_URL=""
TEMPO_GAS_FORK_LOG=""
TEMPO_GAS_FORK_CHAIN=""

tempo_gas_require_tools() {
  local tool missing=0
  for tool in anvil jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "The Tempo gas check needs $tool on PATH; nothing was run." >&2
      missing=1
    fi
  done
  return "$missing"
}

# True when something accepts connections on 127.0.0.1:$1.
_tempo_gas_port_busy() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

_tempo_gas_free_port() {
  local i port
  for i in $(seq 1 50); do
    port=$((20000 + RANDOM % 40000))
    _tempo_gas_port_busy "$port" || { printf '%s' "$port"; return 0; }
  done
  echo "Tempo gas check: found no free local port for the fork." >&2
  return 1
}

tempo_gas_fork_start() {
  local upstream="$1" port i
  port="${TEMPO_GAS_FORK_PORT:-}"
  [ -n "$port" ] || port="$(_tempo_gas_free_port)" || return 1
  if _tempo_gas_port_busy "$port"; then
    echo "Tempo gas check: port $port is already in use; set TEMPO_GAS_FORK_PORT to a free one." >&2
    return 1
  fi
  TEMPO_GAS_FORK_URL="http://127.0.0.1:$port"
  TEMPO_GAS_FORK_LOG="$(mktemp)"
  anvil --fork-url "$upstream" --network tempo --auto-impersonate \
    --base-fee 0 --gas-price 0 --disable-min-priority-fee --port "$port" >"$TEMPO_GAS_FORK_LOG" 2>&1 &
  TEMPO_GAS_FORK_PID=$!
  TEMPO_GAS_FORK_CHAIN=""
  for i in $(seq 1 "${TEMPO_GAS_FORK_WAIT:-60}"); do
    kill -0 "$TEMPO_GAS_FORK_PID" 2>/dev/null || break
    TEMPO_GAS_FORK_CHAIN="$(cast chain-id --rpc-url "$TEMPO_GAS_FORK_URL" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$TEMPO_GAS_FORK_CHAIN" ] && break
    sleep 1
  done
  # Something else answering on the port (our anvil having exited) would be estimated against
  # the wrong state.
  if [ -z "$TEMPO_GAS_FORK_CHAIN" ] || ! kill -0 "$TEMPO_GAS_FORK_PID" 2>/dev/null; then
    echo "Tempo gas check: the local fork at $TEMPO_GAS_FORK_URL did not start:" >&2
    tail -5 "$TEMPO_GAS_FORK_LOG" >&2
    tempo_gas_fork_stop
    return 1
  fi
}

tempo_gas_fork_stop() {
  local port i
  [ -n "$TEMPO_GAS_FORK_PID" ] || return 0
  kill "$TEMPO_GAS_FORK_PID" 2>/dev/null || true
  wait "$TEMPO_GAS_FORK_PID" 2>/dev/null || true
  port="${TEMPO_GAS_FORK_URL##*:}"
  for i in $(seq 1 50); do
    _tempo_gas_port_busy "$port" || break
    sleep 0.1
  done
  rm -f "$TEMPO_GAS_FORK_LOG"
  TEMPO_GAS_FORK_PID=""
}

tempo_gas_check() {
  local target="$1"
  shift
  local file="${target%%:*}" record out rc=0 multiplier
  echo "Tempo gas check: simulating $(basename "$file") on the local fork and reading node estimates..."
  record="broadcast/$(basename "$file")/$TEMPO_GAS_FORK_CHAIN/dry-run/run-latest.json"
  rm -f "$record"
  if ! forge script "$target" --rpc-url "$TEMPO_GAS_FORK_URL" "$@"; then
    echo "Tempo gas check: the simulation of $(basename "$file") on the local fork failed; nothing was broadcast." >&2
    return 1
  fi
  out="$(mktemp)"
  "$TEMPO_GAS_LIB_DIR/tempo-gas-check.sh" "$record" "$TEMPO_GAS_FORK_URL" >"$out" || rc=$?
  cat "$out"
  multiplier="$(sed -n 's/^TEMPO_GAS_MULTIPLIER=//p' "$out")"
  TEMPO_GAS_LARGEST="$(sed -n 's/^Largest node estimate: //p' "$out")"
  rm -f "$out"
  if [ "$rc" != "0" ]; then
    echo "Tempo gas check refused $(basename "$file"); nothing was broadcast." >&2
    return 1
  fi
  [ -n "$multiplier" ] || { echo "Tempo gas check produced no multiplier." >&2; return 1; }
  TEMPO_GAS_FLAGS=(--gas-estimate-multiplier "$multiplier")
}

tempo_gas_preflight() {
  local target="$1" upstream="$2" rc=0
  shift 2
  tempo_gas_require_tools || return 1
  tempo_gas_fork_start "$upstream" || return 1
  tempo_gas_check "$target" "$@" || rc=$?
  tempo_gas_fork_stop
  return "$rc"
}

# The RPC URL behind a foundry.toml Tempo alias (anvil cannot read forge's aliases).
tempo_rpc_url() {
  case "$1" in
    tempo_moderato) printf '%s' "${FORGE_TEMPO_MODERATO_RPC_URL:?FORGE_TEMPO_MODERATO_RPC_URL not set}" ;;
    tempo) printf '%s' "${FORGE_TEMPO_RPC_URL:?FORGE_TEMPO_RPC_URL not set}" ;;
    *) echo "Unknown Tempo RPC alias $1" >&2; return 1 ;;
  esac
}
