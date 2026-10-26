#!/usr/bin/env bash
# Deploys TaskMarketForwarderV2 against an existing diamond on a chain that pays gas in its native
# coin (Base, Robinhood Chain), checks its getters against the inputs, then trusts it on the diamond
# with addForwarder (onlyOwner, so the deployer key must own the diamond).
#
#   make deploy-forwarder 84532|8453|4663|46630
#
# Usage: script/base-forwarder.sh <84532|8453|4663|46630>
#
# Inputs are read ONLY from the chain-suffixed variables (FORGE_*_<chainId>); unsuffixed
# names are overwritten from them before forge runs, so a value meant for another chain cannot leak
# through. DRY_RUN=1 simulates the deploy, checks the simulated constructor inputs and skips
# addForwarder.
set -euo pipefail

CHAIN_ID="${1:-}"
case "$CHAIN_ID" in
  84532|8453|4663|46630) ;;
  *) echo "Usage: script/base-forwarder.sh <84532|8453|4663|46630>" >&2; exit 1 ;;
esac
RPC="$CHAIN_ID"

case "$(printf '%s' "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')" in
  ''|0|false) DRY_RUN=0 ;;
  *) DRY_RUN=1 ;;
esac

MISSING=()
need() { local v="${1}_${CHAIN_ID}"; printf '%s' "${!v:-}"; }
KEY="$(need FORGE_DEV_PRIVATE_KEY)"
USDC="$(need FORGE_USDC_TOKEN_ADDRESS)"
DIAMOND="$(need FORGE_DIAMOND_ADDRESS)"
RELAYER="$(need FORGE_SERVER_ADDRESS)"
for name in FORGE_DEV_PRIVATE_KEY FORGE_USDC_TOKEN_ADDRESS FORGE_DIAMOND_ADDRESS FORGE_SERVER_ADDRESS; do
  v="${name}_${CHAIN_ID}"; [ -n "${!v:-}" ] || MISSING+=("$v")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "deploy-forwarder $CHAIN_ID: missing required variable(s):" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi
export FORGE_DEV_PRIVATE_KEY="$KEY" FORGE_USDC_TOKEN_ADDRESS="$USDC" CONTRACT_ADDRESS="$DIAMOND" \
  FORGE_SERVER_ADDRESS="$RELAYER"

echo "== deploy-forwarder: chain $CHAIN_ID =="
echo "  Diamond:            $DIAMOND"
echo "  Settlement token:   $USDC"
echo "  Authorized relayer: $RELAYER"
[ "$DRY_RUN" = "1" ] && echo "  Mode:               DRY RUN (no broadcast)" || echo "  Mode:               BROADCAST"

# A wrong FORGE_RPC_URL_<chainId> must not put a mainnet deploy on testnet, or the reverse.
ACTUAL="$(cast chain-id --rpc-url "$RPC" 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$ACTUAL" != "$CHAIN_ID" ]; then
  echo "Refusing to run: the $RPC RPC alias reports chain ID '${ACTUAL:-unreadable}', expected $CHAIN_ID." >&2
  exit 1
fi

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
expect() {
  if [ "$(lc "$2")" != "$(lc "$3")" ]; then
    echo "  $1 = $2, expected $3" >&2
    exit 1
  fi
  echo "  $1 = $2"
}

BROADCAST=()
[ "$DRY_RUN" = "1" ] || BROADCAST=(--broadcast --verify)
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
forge script script/DeployForwarderV2.s.sol:DeployForwarderV2 --rpc-url "$RPC" \
  ${BROADCAST[@]+"${BROADCAST[@]}"} 2>&1 | tee "$LOG"
logged() { grep -E "^ *$1" "$LOG" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}' | tail -1; }
FORWARDER="$(logged 'Forwarder v2')"
[ -n "$FORWARDER" ] || { echo "No forwarder address in the forge output." >&2; exit 1; }

echo "Forwarder v2 constructor inputs (from the script's output):"
expect "usdc" "$(logged 'USDC:')" "$USDC"
expect "taskMarket" "$(logged 'TaskMarket:')" "$DIAMOND"
expect "authorizedRelayer" "$(logged 'Authorized relayer:')" "$RELAYER"
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: simulated forwarder $FORWARDER; skipping the on-chain checks and addForwarder."
  exit 0
fi

echo "Forwarder v2 at $FORWARDER (read on chain):"
expect "usdc()" "$(cast call "$FORWARDER" "usdc()(address)" --rpc-url "$RPC")" "$USDC"
expect "taskMarket()" "$(cast call "$FORWARDER" "taskMarket()(address)" --rpc-url "$RPC")" "$DIAMOND"
expect "authorizedRelayer()" "$(cast call "$FORWARDER" "authorizedRelayer()(address)" --rpc-url "$RPC")" "$RELAYER"
if [ "$(cast call "$DIAMOND" "isTrustedForwarder(address)(bool)" "$FORWARDER" --rpc-url "$RPC" 2>/dev/null || true)" = "true" ]; then
  echo "The diamond already trusts $FORWARDER; skipping addForwarder."
else
  FORWARDER_ADDRESS="$FORWARDER" forge script script/AddForwarder.s.sol:AddForwarder \
    --rpc-url "$RPC" --broadcast
fi
TRUSTED="$(cast call "$DIAMOND" "isTrustedForwarder(address)(bool)" "$FORWARDER" --rpc-url "$RPC")"
echo "isTrustedForwarder($FORWARDER) = $TRUSTED"
[ "$TRUSTED" = "true" ] || { echo "Forwarder is not trusted after addForwarder." >&2; exit 1; }
echo "Set FORWARDER_ADDRESS=$FORWARDER on the backend environment that serves chain $CHAIN_ID."
