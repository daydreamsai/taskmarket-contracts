#!/usr/bin/env bash
# tempo-gas-check.sh <run-record.json> <rpc-url>
#
# Replays every transaction in a forge dry-run record against <rpc-url> (a local anvil fork
# started with --auto-impersonate and --base-fee 0, never a live network) and asks the node for eth_estimateGas
# on each one before sending it, so every estimate sees the state the earlier steps leave.
#
# Tempo rejects any transaction whose gas limit exceeds 30,000,000, and forge's own simulated
# gas can be far below the node's estimate (a rev025 cut simulated at about 13.6M and estimated
# at about 28.4M). So the node's estimate is what has to fit.
#
# Prints one line per transaction, then "TEMPO_GAS_MULTIPLIER=<percent>":
# min(130, floor(TEMPO_GAS_BUDGET * 100 / largest estimate)). Forge multiplies the live node's
# estimate, not this fork's, and on Moderato the live estimates for facet deploys ran 0.80-0.87%
# above the fork's (CoreFacet 18,336,344 live vs 18,190,805 on the fork), so the budget
# (29,400,000) leaves about 2% under the cap for that gap. Exits 1, naming the transaction, if any
# estimate is >= TEMPO_GAS_LIMIT_MAX (29,900,000), or if the multiplier would fall below 101
# (a largest estimate above about 29.1M): below that forge would set a limit at or under the
# estimate, and the transaction could run out of gas on chain instead of being refused here.
set -euo pipefail

RECORD="${1:?usage: tempo-gas-check.sh <run-record.json> <rpc-url>}"
RPC="${2:?usage: tempo-gas-check.sh <run-record.json> <rpc-url>}"
LIMIT="${TEMPO_GAS_LIMIT_MAX:-29900000}"
BUDGET="${TEMPO_GAS_BUDGET:-29400000}"
DEFAULT_MULTIPLIER=130
MIN_MULTIPLIER=101

command -v jq >/dev/null || { echo "tempo-gas-check needs jq." >&2; exit 1; }
[ -f "$RECORD" ] || { echo "No forge run record at $RECORD." >&2; exit 1; }

COUNT="$(jq '.transactions | length' "$RECORD")"
[ "$COUNT" -gt 0 ] || { echo "The run record at $RECORD has no transactions." >&2; exit 1; }

MAX=0
OVER=""
for i in $(seq 0 $((COUNT - 1))); do
  TX="$(jq -c --argjson i "$i" '.transactions[$i].transaction | {from, to, data: (.input // .data), value: (.value // "0x0")} | with_entries(select(.value != null))' "$RECORD")"
  LABEL="$(jq -r --argjson i "$i" '.transactions[$i] | "\(.transactionType) \(.contractName // "?") \(if .transactionType == "CREATE" then "" else (.function // ((.transaction.input // .transaction.data // "")[0:10])) end)"' "$RECORD")"
  if ! EST_HEX="$(cast rpc --rpc-url "$RPC" eth_estimateGas "$TX" 2>&1)"; then
    echo "tx $i ($LABEL): eth_estimateGas failed: $EST_HEX" >&2
    exit 1
  fi
  EST="$(printf '%d' "$(printf '%s' "$EST_HEX" | tr -d '"[:space:]')")"
  printf 'tx %-3s %-60s estimate %10s  cap %s\n' "$i" "$LABEL" "$EST" "$LIMIT"
  [ "$EST" -gt "$MAX" ] && MAX="$EST"
  if [ "$EST" -ge "$LIMIT" ]; then
    OVER="${OVER}tx $i ($LABEL): node estimate $EST >= $LIMIT"$'\n'
  fi
  # Send it on the fork so the next estimate sees its effect. The limit here is fork-only, and the
  # fee is zero (the fork runs with --base-fee 0) so the replay never needs the fee token.
  SEND="$(printf '%s' "$TX" | jq -c --arg gas "$(printf '0x%x' $((EST + EST / 5)))" '. + {gas: $gas, maxFeePerGas: "0x0", maxPriorityFeePerGas: "0x0"}')"
  HASH="$(cast rpc --rpc-url "$RPC" eth_sendTransaction "$SEND" | tr -d '"[:space:]')"
  STATUS="$(cast receipt --rpc-url "$RPC" "$HASH" status 2>/dev/null | awk '{print $1}')"
  if [ "$STATUS" != "1" ] && [ "$STATUS" != "true" ]; then
    echo "tx $i ($LABEL) reverted on the fork ($HASH); cannot estimate the steps after it." >&2
    exit 1
  fi
done

if [ -n "$OVER" ]; then
  echo "Refusing to broadcast: Tempo rejects a transaction whose gas limit exceeds 30,000,000." >&2
  printf '%s' "$OVER" >&2
  exit 1
fi

MULTIPLIER=$((BUDGET * 100 / MAX))
[ "$MULTIPLIER" -gt "$DEFAULT_MULTIPLIER" ] && MULTIPLIER=$DEFAULT_MULTIPLIER
if [ "$MULTIPLIER" -lt "$MIN_MULTIPLIER" ]; then
  echo "Refusing to broadcast: largest node estimate $MAX gives multiplier $MULTIPLIER, which is below the minimum $MIN_MULTIPLIER (budget $BUDGET)." >&2
  echo "A gas limit at or under the estimate could run out of gas on chain; the transaction has to be split." >&2
  exit 1
fi
echo "Largest node estimate: $MAX"
echo "TEMPO_GAS_MULTIPLIER=$MULTIPLIER"
