#!/usr/bin/env bash
# Tempo deploy helper -- run via the Make targets, not directly:
#   make deploy tempo-testnet|tempo-mainnet
#   make deploy-forwarder tempo-testnet|tempo-mainnet
#   make upgrade tempo-testnet|tempo-mainnet [revNNN]
#
# Usage: script/tempo.sh <deploy|deploy-forwarder|upgrade> <tempo-testnet|tempo-mainnet> [revNNN]
#
# Inputs are read ONLY from the network-suffixed variables (FORGE_*_TEMPO_TESTNET /
# FORGE_*_TEMPO_MAINNET). An unsuffixed FORGE_DEFAULT_PLATFORM_FEE_BPS or
# FORGE_ERC8004_REPUTATION_REGISTRY left in .env for Base never reaches a Tempo deploy: the
# unsuffixed names are overwritten from the suffixed ones before forge runs (an unset optional
# FORGE_ERC8004_REPUTATION_REGISTRY_TEMPO_* clears the unsuffixed one too). A missing suffixed
# variable fails before anything is sent, and the resolved inputs are printed first.
#
# DRY_RUN=1 simulates without broadcasting (forge script without --broadcast, and no
# addForwarder transaction).
set -euo pipefail

ACTION="${1:-}"
NETWORK="${2:-}"
REV="${3:-}"
DRY_RUN="${DRY_RUN:-0}"

usage() {
  echo "Usage: script/tempo.sh <deploy|deploy-forwarder|upgrade> <tempo-testnet|tempo-mainnet> [revNNN]" >&2
  exit 1
}

case "$NETWORK" in
  tempo-testnet) SUFFIX=TEMPO_TESTNET; RPC_ALIAS=tempo_moderato; CHAIN_ID=42431 ;;
  tempo-mainnet) SUFFIX=TEMPO_MAINNET; RPC_ALIAS=tempo; CHAIN_ID=4217 ;;
  *) usage ;;
esac
case "$ACTION" in deploy|deploy-forwarder|upgrade) ;; *) usage ;; esac

MISSING=()
# need NAME -> value of NAME_<SUFFIX> (empty when unset; presence is checked below).
need() {
  local var="${1}_${SUFFIX}"
  printf '%s' "${!var:-}"
}

KEY="$(need FORGE_DEV_PRIVATE_KEY)"
FEE_TOKEN="$(need FORGE_FEE_TOKEN)"
case "$ACTION" in
  deploy)
    USDC="$(need FORGE_USDC_TOKEN_ADDRESS)"
    FEE_RECIPIENT="$(need FORGE_FEE_RECIPIENT_ADDRESS)"
    FEE_BPS="$(need FORGE_DEFAULT_PLATFORM_FEE_BPS)"
    REGISTRY="$(need FORGE_ERC8004_REPUTATION_REGISTRY)"
    ;;
  deploy-forwarder)
    USDC="$(need FORGE_USDC_TOKEN_ADDRESS)"
    DIAMOND="$(need FORGE_DIAMOND_ADDRESS)"
    RELAYER="$(need FORGE_SERVER_ADDRESS)"
    ;;
  upgrade)
    DIAMOND="$(need FORGE_DIAMOND_ADDRESS)"
    ;;
esac
for name in FORGE_DEV_PRIVATE_KEY FORGE_FEE_TOKEN; do
  v="${name}_${SUFFIX}"; [ -n "${!v:-}" ] || MISSING+=("$v")
done
case "$ACTION" in
  deploy) CHECK=(FORGE_USDC_TOKEN_ADDRESS FORGE_FEE_RECIPIENT_ADDRESS FORGE_DEFAULT_PLATFORM_FEE_BPS) ;;
  deploy-forwarder) CHECK=(FORGE_USDC_TOKEN_ADDRESS FORGE_DIAMOND_ADDRESS FORGE_SERVER_ADDRESS) ;;
  upgrade) CHECK=(FORGE_DIAMOND_ADDRESS) ;;
esac
for name in "${CHECK[@]}"; do
  v="${name}_${SUFFIX}"; [ -n "${!v:-}" ] || MISSING+=("$v")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "tempo $ACTION $NETWORK: missing required variable(s):" >&2
  printf '  %s\n' $(printf '%s\n' "${MISSING[@]}" | sort -u) >&2
  echo "Only the _${SUFFIX} names are read; unsuffixed FORGE_* values are ignored for Tempo." >&2
  exit 1
fi

DEPLOYER="$(cast wallet address --private-key "$KEY")"

echo "== Tempo $ACTION: $NETWORK (chain $CHAIN_ID) =="
echo "  RPC alias:          $RPC_ALIAS"
echo "  Deployer:           $DEPLOYER"
echo "  Fee token (gas):    $FEE_TOKEN"
case "$ACTION" in
  deploy)
    echo "  Settlement token:   $USDC"
    echo "  Fee recipient:      $FEE_RECIPIENT"
    echo "  Platform fee bps:   $FEE_BPS"
    echo "  Reputation registry: ${REGISTRY:-<unset: none registered>}"
    ;;
  deploy-forwarder)
    echo "  Settlement token:   $USDC"
    echo "  Diamond:            $DIAMOND"
    echo "  Authorized relayer: $RELAYER"
    ;;
  upgrade)
    echo "  Diamond:            $DIAMOND"
    echo "  Step:               ${REV:-all pending}"
    ;;
esac
[ "$DRY_RUN" = "1" ] && echo "  Mode:               DRY RUN (no broadcast)"
echo ""

export FOUNDRY_PROFILE=tempo
# Overwrite every unsuffixed name the scripts read so a Base value in .env cannot leak through.
export FORGE_DEV_PRIVATE_KEY="$KEY"
export FORGE_FEE_TOKEN="$FEE_TOKEN"
unset USDC_TOKEN_ADDRESS CONTRACT_ADDRESS FORWARDER_ADDRESS

BROADCAST=(--broadcast --slow --verify --verifier sourcify --verifier-url https://contracts.tempo.xyz)
[ "$DRY_RUN" = "1" ] && BROADCAST=()

case "$ACTION" in
  deploy)
    export FORGE_USDC_TOKEN_ADDRESS="$USDC"
    export FORGE_FEE_RECIPIENT_ADDRESS="$FEE_RECIPIENT"
    export FORGE_DEFAULT_PLATFORM_FEE_BPS="$FEE_BPS"
    if [ -n "$REGISTRY" ]; then export FORGE_ERC8004_REPUTATION_REGISTRY="$REGISTRY"; else unset FORGE_ERC8004_REPUTATION_REGISTRY; fi
    forge script script/DiamondDeploy.s.sol:DiamondDeploy \
      --rpc-url "$RPC_ALIAS" --tempo.fee-token "$FEE_TOKEN" ${BROADCAST[@]+"${BROADCAST[@]}"}
    ;;
  deploy-forwarder)
    export FORGE_USDC_TOKEN_ADDRESS="$USDC"
    export CONTRACT_ADDRESS="$DIAMOND"
    export FORGE_SERVER_ADDRESS="$RELAYER"
    OWNER="$(cast call "$DIAMOND" "owner()(address)" --rpc-url "$RPC_ALIAS" 2>/dev/null || true)"
    echo "Diamond owner: ${OWNER:-<unreadable>}"
    if [ -n "$OWNER" ] && [ "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" ]; then
      echo "Deployer is not the diamond owner; addForwarder is onlyOwner and would revert." >&2
      exit 1
    fi
    LOG="$(mktemp)"
    forge script script/DeployForwarder.s.sol:DeployForwarder \
      --rpc-url "$RPC_ALIAS" --tempo.fee-token "$FEE_TOKEN" ${BROADCAST[@]+"${BROADCAST[@]}"} 2>&1 | tee "$LOG"
    FORWARDER="$(grep 'Forwarder (FORWARDER_ADDRESS):' "$LOG" | tail -1 | awk '{print $NF}')"
    rm -f "$LOG"
    if [ "$DRY_RUN" = "1" ]; then
      echo "DRY RUN: skipping addForwarder (the simulated forwarder address is not on chain)."
      exit 0
    fi
    if [ -z "$FORWARDER" ]; then
      echo "Forwarder deploy did not report an address; not calling addForwarder." >&2
      exit 1
    fi
    export FORWARDER_ADDRESS="$FORWARDER"
    forge script script/AddForwarder.s.sol:AddForwarder \
      --rpc-url "$RPC_ALIAS" --tempo.fee-token "$FEE_TOKEN" --broadcast --slow
    TRUSTED="$(cast call "$DIAMOND" "isTrustedForwarder(address)(bool)" "$FORWARDER" --rpc-url "$RPC_ALIAS")"
    echo "isTrustedForwarder($FORWARDER) = $TRUSTED"
    [ "$TRUSTED" = "true" ] || { echo "Forwarder is not trusted after addForwarder." >&2; exit 1; }
    echo "Set FORWARDER_ADDRESS_${CHAIN_ID}=$FORWARDER on the backend."
    ;;
  upgrade)
    exec ./script/upgrade.sh "$NETWORK" "$REV"
    ;;
esac
