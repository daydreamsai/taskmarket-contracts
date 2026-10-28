#!/usr/bin/env bash
# Tempo deploy helper -- run via the Make targets, not directly:
#   make deploy 42431|4217
#   make deploy-forwarder 42431|4217
#   make upgrade 42431|4217 [revNNN]
#   make deploy-sponsored-task|upgrade-sponsored-task|deploy-safe|deploy-sponsored-task-timelock 42431|4217
#
# Usage: script/tempo.sh <action> <42431|4217> [revNNN]
#
# Inputs are read ONLY from the network-suffixed variables (FORGE_*_42431 /
# FORGE_*_4217). An unsuffixed FORGE_DEFAULT_PLATFORM_FEE_BPS or
# FORGE_ERC8004_REPUTATION_REGISTRY left in .env for Base never reaches a Tempo deploy: the
# unsuffixed names are overwritten from the suffixed ones before forge runs (an unset optional
# FORGE_ERC8004_REPUTATION_REGISTRY_TEMPO_* clears the unsuffixed one too). A missing suffixed
# variable fails before anything is sent, and the resolved inputs are printed first.
#
# deploy-forwarder deploys TaskMarketForwarderV2 (it checks each relayed createTask/updateTask
# against the payment it reports), checks its usdc(), taskMarket() and authorizedRelayer() against
# the inputs, then trusts it with addForwarder and confirms isTrustedForwarder.
#
# DRY_RUN simulates without broadcasting (forge script without --broadcast, and no
# addForwarder transaction). Any non-empty value other than 0 or false is a dry run (1, true,
# yes, ...); only unset, empty, 0 and false broadcast. The Make targets pass a DRY_RUN given on
# the command line (or in the calling environment) after .env is loaded, so a DRY_RUN line in
# .env never overrides it.
set -euo pipefail

ACTION="${1:-}"
NETWORK="${2:-}"
REV="${3:-}"
RESUME="${FORWARDER_ADDRESS_RESUME:-}"
case "$(printf '%s' "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')" in
  ""|0|false) DRY_RUN=0 ;;
  *) DRY_RUN=1 ;;
esac
export DRY_RUN

usage() {
  echo "Usage: script/tempo.sh <deploy|deploy-forwarder|upgrade|deploy-sponsored-task|upgrade-sponsored-task|deploy-safe|deploy-sponsored-task-timelock> <42431|4217> [revNNN]" >&2
  exit 1
}

case "$NETWORK" in
  42431) SUFFIX=42431; RPC_ALIAS=42431; CHAIN_ID=42431 ;;
  4217) SUFFIX=4217; RPC_ALIAS=4217; CHAIN_ID=4217 ;;
  *) usage ;;
esac
# The single-script actions: the forge target, whether a broadcast verifies it, the variable holding
# the signing key, and its required and optional inputs. Each input NAME is read from
# FORGE_<NAME without FORGE_>_<chain> and exported to forge as NAME.
SCRIPT=""
case "$ACTION" in
  deploy|deploy-forwarder|upgrade) ;;
  deploy-sponsored-task)
    SCRIPT=script/DeploySponsoredTask.s.sol:DeploySponsoredTask; SCRIPT_VERIFY=1
    KEY_NAME=FORGE_DEV_PRIVATE_KEY
    REQUIRED=(FORGE_USDC_TOKEN_ADDRESS FORGE_DIAMOND_ADDRESS FORGE_SPONSORED_TASK_CREATION_FEE_RECIPIENT
      FORGE_SPONSORED_TASK_TOKEN_FEE_RECIPIENT FORGE_SPONSORED_TASK_ADMIN)
    OPTIONAL=(FORGE_SPONSORED_TASK_CREATION_FEE_USDC FORGE_SPONSORED_TASK_TOKEN_FEE_BPS)
    ;;
  upgrade-sponsored-task)
    SCRIPT=script/UpgradeSponsoredTask.s.sol:UpgradeSponsoredTask; SCRIPT_VERIFY=1
    KEY_NAME=FORGE_DEV_PRIVATE_KEY
    REQUIRED=(FORGE_SPONSORED_TASK_HOOK_ADDRESS)
    OPTIONAL=()
    ;;
  deploy-safe)
    SCRIPT=script/DeploySafe.s.sol:DeploySafe; SCRIPT_VERIFY=0
    KEY_NAME=SAFE_DEPLOYER_KEY
    REQUIRED=(SAFE_OWNERS SAFE_THRESHOLD)
    OPTIONAL=(SAFE_SALT_NONCE)
    ;;
  deploy-sponsored-task-timelock)
    SCRIPT=script/DeploySponsoredTaskGuardTimelock.s.sol:DeploySponsoredTaskGuardTimelock; SCRIPT_VERIFY=0
    KEY_NAME=TIMELOCK_DEPLOYER_KEY
    REQUIRED=(TIMELOCK_SAFE TIMELOCK_MIN_DELAY)
    OPTIONAL=(TIMELOCK_ADMIN)
    ;;
  *) usage ;;
esac
src_name() { printf 'FORGE_%s_%s' "${1#FORGE_}" "$SUFFIX"; }

# shellcheck source=lib/tempo-gas.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tempo-gas.sh"
# deploy and upgrade run the gas check, which needs anvil and jq; refuse before anything else.
case "$ACTION" in deploy-forwarder) ;; *) tempo_gas_require_tools || exit 1 ;; esac

MISSING=()
# need NAME -> value of NAME_<SUFFIX> (empty when unset; presence is checked below).
need() {
  local var="${1}_${SUFFIX}"
  printf '%s' "${!var:-}"
}

KEY_NAME="${KEY_NAME:-FORGE_DEV_PRIVATE_KEY}"
KEY_SRC="$(src_name "$KEY_NAME")"
KEY="${!KEY_SRC:-}"
FEE_TOKEN="$(need FORGE_FEE_TOKEN)"
case "$ACTION" in
  deploy)
    USDC="$(need FORGE_USDC_TOKEN_ADDRESS)"
    FEE_RECIPIENT="$(need FORGE_FEE_RECIPIENT_ADDRESS)"
    FEE_BPS="$(need FORGE_DEFAULT_PLATFORM_FEE_BPS)"
    REGISTRY="$(need FORGE_ERC8004_REPUTATION_REGISTRY)"
    FEEDBACK_GAS="$(need FORGE_MIN_FEEDBACK_GAS)"
    HOOK_STIPEND="$(need FORGE_HOOK_GAS_STIPEND)"
    ;;
  deploy-forwarder)
    USDC="$(need FORGE_USDC_TOKEN_ADDRESS)"
    DIAMOND="$(need FORGE_DIAMOND_ADDRESS)"
    RELAYER="$(need FORGE_SERVER_ADDRESS)"
    ;;
  upgrade)
    DIAMOND="$(need FORGE_DIAMOND_ADDRESS)"
    FEEDBACK_GAS="$(need FORGE_MIN_FEEDBACK_GAS)"
    HOOK_STIPEND="$(need FORGE_HOOK_GAS_STIPEND)"
    ;;
esac
[ -n "$KEY" ] || MISSING+=("$KEY_SRC")
[ -n "$FEE_TOKEN" ] || MISSING+=("FORGE_FEE_TOKEN_${SUFFIX}")
CHECK=()
case "$ACTION" in
  deploy) CHECK=(FORGE_USDC_TOKEN_ADDRESS FORGE_FEE_RECIPIENT_ADDRESS FORGE_DEFAULT_PLATFORM_FEE_BPS FORGE_MIN_FEEDBACK_GAS FORGE_HOOK_GAS_STIPEND) ;;
  deploy-forwarder) CHECK=(FORGE_USDC_TOKEN_ADDRESS FORGE_DIAMOND_ADDRESS FORGE_SERVER_ADDRESS) ;;
  upgrade) CHECK=(FORGE_DIAMOND_ADDRESS FORGE_MIN_FEEDBACK_GAS FORGE_HOOK_GAS_STIPEND) ;;
esac
for name in ${CHECK[@]+"${CHECK[@]}"}; do
  v="${name}_${SUFFIX}"; [ -n "${!v:-}" ] || MISSING+=("$v")
done
if [ -n "$SCRIPT" ]; then
  for name in ${REQUIRED[@]+"${REQUIRED[@]}"}; do
    v="$(src_name "$name")"; [ -n "${!v:-}" ] || MISSING+=("$v")
  done
fi
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
    echo "  Feedback gas floor: $FEEDBACK_GAS"
    echo "  Hook gas stipend:   $HOOK_STIPEND"
    ;;
  deploy-forwarder)
    echo "  Settlement token:   $USDC"
    echo "  Diamond:            $DIAMOND"
    echo "  Authorized relayer: $RELAYER"
    ;;
  upgrade)
    echo "  Diamond:            $DIAMOND"
    echo "  Step:               ${REV:-all pending}"
    echo "  Feedback gas floor: $FEEDBACK_GAS"
    echo "  Hook gas stipend:   $HOOK_STIPEND"
    ;;
esac
if [ -n "$SCRIPT" ]; then
  for name in ${REQUIRED[@]+"${REQUIRED[@]}"} ${OPTIONAL[@]+"${OPTIONAL[@]}"}; do
    v="$(src_name "$name")"
    echo "  $name: ${!v:-<unset: script default>}"
  done
fi
[ "$DRY_RUN" = "1" ] && echo "  Mode:               DRY RUN (no broadcast)"
echo ""

export FOUNDRY_PROFILE=tempo
# Overwrite every unsuffixed name the scripts read so a Base value in .env cannot leak through.
export FORGE_DEV_PRIVATE_KEY="$KEY"
if [ -n "$SCRIPT" ]; then
  export "$KEY_NAME=$KEY"
  for name in ${REQUIRED[@]+"${REQUIRED[@]}"} ${OPTIONAL[@]+"${OPTIONAL[@]}"}; do
    v="$(src_name "$name")"
    if [ -n "${!v:-}" ]; then export "$name=${!v}"; else unset "$name"; fi
  done
fi
export FORGE_FEE_TOKEN="$FEE_TOKEN"
if [ -n "${FEEDBACK_GAS:-}" ]; then export FORGE_MIN_FEEDBACK_GAS="$FEEDBACK_GAS"; else unset FORGE_MIN_FEEDBACK_GAS; fi
if [ -n "${HOOK_STIPEND:-}" ]; then export FORGE_HOOK_GAS_STIPEND="$HOOK_STIPEND"; else unset FORGE_HOOK_GAS_STIPEND; fi
unset USDC_TOKEN_ADDRESS CONTRACT_ADDRESS FORWARDER_ADDRESS

# Set once a broadcast forwarder is on chain and cleared once it is trusted: any failure in
# between prints its address and the resume command instead of leaving a rerun to deploy another.
DEPLOYED_FORWARDER=""
resume_hint() {
  local rc=$?
  if [ "$rc" != "0" ] && [ -n "$DEPLOYED_FORWARDER" ]; then
    echo "" >&2
    echo "TaskMarketForwarderV2 is deployed at $DEPLOYED_FORWARDER, but a later step failed." >&2
    echo "Do not rerun the deploy: it would create a second forwarder. Resume with:" >&2
    echo "  FORWARDER_ADDRESS_RESUME=$DEPLOYED_FORWARDER make deploy-forwarder $NETWORK" >&2
  fi
}
trap resume_hint EXIT

# Refuse to send anything when the RPC answers for a different chain than the network named:
# a wrong FORGE_TEMPO_*_RPC_URL must not put a mainnet deploy on testnet, or the reverse.
ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_ALIAS" 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
  echo "Refusing to run: $RPC_ALIAS reports chain ID '${ACTUAL_CHAIN_ID:-unreadable}', expected $CHAIN_ID for $NETWORK." >&2
  echo "Check the RPC URL behind the $RPC_ALIAS alias in foundry.toml before retrying." >&2
  exit 1
fi

BROADCAST=(--broadcast --slow)
# A loopback RPC is a local anvil started with --network tempo (scripts/local-tempo-setup.sh):
# the Tempo explorer has never seen its contracts, so they are not sent for verification.
RPC_URL_VAR="FORGE_RPC_URL_${SUFFIX}"
case "${!RPC_URL_VAR:-}" in
  http://127.0.0.1:*|http://localhost:*) echo "Local node: skipping source verification." ;;
  *) BROADCAST+=(--verify --verifier sourcify --verifier-url https://contracts.tempo.xyz) ;;
esac
[ "$DRY_RUN" = "1" ] && BROADCAST=()

case "$ACTION" in
  deploy)
    export FORGE_USDC_TOKEN_ADDRESS="$USDC"
    export FORGE_FEE_RECIPIENT_ADDRESS="$FEE_RECIPIENT"
    export FORGE_DEFAULT_PLATFORM_FEE_BPS="$FEE_BPS"
    if [ -n "$REGISTRY" ]; then export FORGE_ERC8004_REPUTATION_REGISTRY="$REGISTRY"; else unset FORGE_ERC8004_REPUTATION_REGISTRY; fi
    # Refuses before anything is sent if a node estimate reaches Tempo's 30M cap; sets
    # TEMPO_GAS_FLAGS so no gas limit forge sends exceeds it (script/lib/tempo-gas.sh).
    tempo_gas_preflight script/DiamondDeploy.s.sol:DiamondDeploy "$(tempo_rpc_url "$RPC_ALIAS")" \
      --tempo.fee-token "$FEE_TOKEN"
    forge script script/DiamondDeploy.s.sol:DiamondDeploy \
      --rpc-url "$RPC_ALIAS" --tempo.fee-token "$FEE_TOKEN" "${TEMPO_GAS_FLAGS[@]}" ${BROADCAST[@]+"${BROADCAST[@]}"}
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
    lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
    # expect LABEL GOT WANT: fail when the forwarder was built with anything but the inputs.
    expect() {
      echo "  $1 = $2"
      [ "$(lc "$2")" = "$(lc "$3")" ] || { echo "Forwarder $1 is $2, expected $3." >&2; exit 1; }
    }
    has_code() {
      local code
      code="$(cast code "$1" --rpc-url "$RPC_ALIAS" 2>/dev/null | tr -d '[:space:]' || true)"
      [ -n "$code" ] && [ "$code" != "0x" ]
    }
    RUN_DIR="broadcast/DeployForwarderV2.s.sol/$CHAIN_ID"
    if [ -n "$RESUME" ]; then
      # A forwarder an earlier run broadcast: skip the deploy and finish its checks and trust.
      if ! printf '%s' "$RESUME" | grep -Eq '^0x[0-9a-fA-F]{40}$'; then
        echo "FORWARDER_ADDRESS_RESUME=$RESUME is not an address." >&2
        exit 1
      fi
      echo "Resuming with the forwarder at $RESUME (FORWARDER_ADDRESS_RESUME): not deploying another."
      if ! has_code "$RESUME"; then
        echo "No contract code at $RESUME on $RPC_ALIAS; nothing to resume." >&2
        exit 1
      fi
      FORWARDER="$RESUME"
    else
      command -v jq >/dev/null || { echo "deploy-forwarder needs jq to read forge's run record." >&2; exit 1; }
      if [ "$DRY_RUN" = "1" ]; then
        RUN_JSON="$RUN_DIR/dry-run/run-latest.json"
      else
        RUN_JSON="$RUN_DIR/run-latest.json"
        # A forwarder an earlier broadcast left on chain but never trusted is finished with
        # FORWARDER_ADDRESS_RESUME, never replaced by a second deploy.
        if [ -f "$RUN_JSON" ]; then
          PREV="$(jq -r '[.transactions[] | select(.transactionType == "CREATE" and .contractName == "TaskMarketForwarderV2")] | last | .contractAddress // empty' "$RUN_JSON" 2>/dev/null || true)"
          if [ -n "$PREV" ] && has_code "$PREV" \
            && [ "$(cast call "$DIAMOND" "isTrustedForwarder(address)(bool)" "$PREV" --rpc-url "$RPC_ALIAS" 2>/dev/null || true)" != "true" ]; then
            echo "An earlier run deployed TaskMarketForwarderV2 at $PREV ($RUN_JSON), and the diamond does not trust it yet." >&2
            echo "Refusing to deploy a second forwarder. Finish that one with:" >&2
            echo "  FORWARDER_ADDRESS_RESUME=$PREV make deploy-forwarder $NETWORK" >&2
            echo "or delete $RUN_JSON to deploy a new forwarder deliberately." >&2
            exit 1
          fi
        fi
      fi
      # A record left by an earlier run must not stand in for this one.
      rm -f "$RUN_JSON"
      LOG="$(mktemp)"
      set +e
      forge script script/DeployForwarderV2.s.sol:DeployForwarderV2 \
        --rpc-url "$RPC_ALIAS" --tempo.fee-token "$FEE_TOKEN" ${BROADCAST[@]+"${BROADCAST[@]}"} 2>&1 | tee "$LOG"
      FORGE_RC="${PIPESTATUS[0]}"
      set -e
      FORWARDER="$(grep 'Forwarder v2 (FORWARDER_ADDRESS once trusted):' "$LOG" | tail -1 | awk '{print $NF}')"
      rm -f "$LOG"
      if [ "$DRY_RUN" != "1" ]; then
        # From here on, any failure must say where the broadcast forwarder is and how to resume.
        RECORDED="$(jq -r '[.transactions[] | select(.transactionType == "CREATE" and .contractName == "TaskMarketForwarderV2")] | last | .contractAddress // empty' "$RUN_JSON" 2>/dev/null || true)"
        for candidate in "$RECORDED" "$FORWARDER"; do
          if [ -n "$candidate" ] && has_code "$candidate"; then DEPLOYED_FORWARDER="$candidate"; break; fi
        done
        if [ "$FORGE_RC" != "0" ] && [ -z "$DEPLOYED_FORWARDER" ] && [ -n "$RECORDED$FORWARDER" ]; then
          echo "forge failed and no forwarder code was found at ${RECORDED:-$FORWARDER} yet; check that address on chain" >&2
          echo "before retrying, and resume with FORWARDER_ADDRESS_RESUME=<address> if it was deployed." >&2
        fi
      fi
      [ "$FORGE_RC" = "0" ] || exit "$FORGE_RC"
      if [ -z "$FORWARDER" ]; then
        echo "Forwarder deploy did not report an address; not calling addForwarder." >&2
        exit 1
      fi
      # The constructor arguments are decoded from the creation transaction forge recorded (its
      # initcode ends with the three ABI-encoded addresses), not from the script's own console.log,
      # which only echoes the environment this script exported.
      if [ ! -f "$RUN_JSON" ]; then
        echo "No forge run record at $RUN_JSON; cannot check the forwarder's constructor arguments." >&2
        exit 1
      fi
      CREATE_TX="$(jq -c '[.transactions[] | select(.transactionType == "CREATE" and .contractName == "TaskMarketForwarderV2")] | last // empty' "$RUN_JSON")"
      if [ -z "$CREATE_TX" ]; then
        echo "$RUN_JSON has no TaskMarketForwarderV2 creation transaction." >&2
        exit 1
      fi
      CREATE_INPUT="$(printf '%s' "$CREATE_TX" | jq -r '.transaction.input // .transaction.data // ""')"
      word_addr() { printf '0x%s' "${CREATE_INPUT: $(( ${#CREATE_INPUT} - 64 * $1 + 24 )):40}"; }
      if [ "${#CREATE_INPUT}" -lt 194 ]; then
        echo "TaskMarketForwarderV2 creation input in $RUN_JSON is too short to hold its constructor arguments." >&2
        exit 1
      fi
      SIM_USDC="$(word_addr 3)"
      SIM_MARKET="$(word_addr 2)"
      SIM_RELAYER="$(word_addr 1)"
      SIM_ADDRESS="$(printf '%s' "$CREATE_TX" | jq -r '.contractAddress // ""')"
      echo "Forwarder v2 constructor arguments (decoded from the creation transaction in $RUN_JSON):"
      expect "address" "$SIM_ADDRESS" "$FORWARDER"
      expect "usdc()" "$SIM_USDC" "$USDC"
      expect "taskMarket()" "$SIM_MARKET" "$DIAMOND"
      expect "authorizedRelayer()" "$SIM_RELAYER" "$RELAYER"
      if [ "$DRY_RUN" = "1" ]; then
        echo "DRY RUN: skipping addForwarder (the simulated forwarder address is not on chain)."
        exit 0
      fi
    fi
    echo "Forwarder v2 at $FORWARDER (read on chain):"
    expect "usdc()" "$(cast call "$FORWARDER" "usdc()(address)" --rpc-url "$RPC_ALIAS")" "$USDC"
    expect "taskMarket()" "$(cast call "$FORWARDER" "taskMarket()(address)" --rpc-url "$RPC_ALIAS")" "$DIAMOND"
    expect "authorizedRelayer()" "$(cast call "$FORWARDER" "authorizedRelayer()(address)" --rpc-url "$RPC_ALIAS")" "$RELAYER"
    if [ "$DRY_RUN" = "1" ]; then
      echo "DRY RUN: skipping addForwarder for $FORWARDER."
      exit 0
    fi
    if [ "$(cast call "$DIAMOND" "isTrustedForwarder(address)(bool)" "$FORWARDER" --rpc-url "$RPC_ALIAS" 2>/dev/null || true)" = "true" ]; then
      echo "The diamond already trusts $FORWARDER; skipping addForwarder."
    else
      export FORWARDER_ADDRESS="$FORWARDER"
      forge script script/AddForwarder.s.sol:AddForwarder \
        --rpc-url "$RPC_ALIAS" --tempo.fee-token "$FEE_TOKEN" --broadcast --slow
    fi
    TRUSTED="$(cast call "$DIAMOND" "isTrustedForwarder(address)(bool)" "$FORWARDER" --rpc-url "$RPC_ALIAS")"
    echo "isTrustedForwarder($FORWARDER) = $TRUSTED"
    [ "$TRUSTED" = "true" ] || { echo "Forwarder is not trusted after addForwarder." >&2; exit 1; }
    DEPLOYED_FORWARDER=""
    echo "Set FORWARDER_ADDRESS_${CHAIN_ID}=$FORWARDER on the backend."
    ;;
  upgrade)
    exec ./script/upgrade.sh "$NETWORK" "$REV"
    ;;
  *)
    if [ "$SCRIPT_VERIFY" != "1" ] && [ "${#BROADCAST[@]}" -gt 0 ]; then BROADCAST=(--broadcast --slow); fi
    tempo_gas_preflight "$SCRIPT" "$(tempo_rpc_url "$RPC_ALIAS")" --tempo.fee-token "$FEE_TOKEN"
    forge script "$SCRIPT" \
      --rpc-url "$RPC_ALIAS" --tempo.fee-token "$FEE_TOKEN" "${TEMPO_GAS_FLAGS[@]}" ${BROADCAST[@]+"${BROADCAST[@]}"}
    ;;
esac
