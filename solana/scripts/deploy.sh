#!/usr/bin/env bash
# Deploys, upgrades and verifies the Sponsored Tasks program from a verifiable build.
#
#   deploy <localnet|devnet>             first deploy of the program at SOLANA_PROGRAM_KEYPAIR's address
#   buffer <localnet|devnet|mainnet-beta> write the build to a buffer for an upgrade; with
#                                        SOLANA_UPGRADE_AUTHORITY set, hand the buffer to it (the
#                                        multisig executes the upgrade on mainnet-beta)
#   upgrade <localnet|devnet> <buffer>   upgrade the program from a buffer with the deployer as
#                                        upgrade authority
#   verify <localnet|devnet|mainnet-beta> compare the deployed program's hash with the verifiable build
#
# Environment:
#   SOLANA_DEPLOYER_KEYPAIR  path to the deployer (fee payer, upgrade authority) keypair
#   SOLANA_PROGRAM_KEYPAIR   path to the program-id keypair (deploy only)
#   SOLANA_PROGRAM_ID        program address (verify, upgrade); defaults to the program's declare_id!
#   SOLANA_UPGRADE_AUTHORITY new buffer authority after `buffer`, e.g. the multisig vault (required
#                            on mainnet-beta)
#   SOLANA_RPC_URL           RPC endpoint; defaults to the cluster's public endpoint
#   DRY_RUN                  any value but empty, 0 or false prints the chain-writing commands
#                            instead of running them
#
# Keypairs must live outside the repository: the script refuses a path inside it. Program-id and
# deployer keypairs are never written, copied or printed here.
set -euo pipefail
cd "$(dirname "$0")/.."
SOLANA_ROOT="$(pwd -P)"
REPO_ROOT="$(cd ../../.. && pwd -P)"
. ./toolchain.env

PROGRAM=sponsored_tasks
SO="target/verifiable/${PROGRAM}.so"
LIB_RS="programs/sponsored-tasks/src/lib.rs"

usage() {
  echo "Usage: make contract solana deploy <localnet|devnet>" >&2
  echo "       make contract solana buffer <localnet|devnet|mainnet-beta>" >&2
  echo "       make contract solana upgrade <localnet|devnet> <buffer-address>" >&2
  echo "       make contract solana verify <localnet|devnet|mainnet-beta>" >&2
  exit 1
}
fail() {
  echo "Error: $1" >&2
  exit 1
}

case "$(printf '%s' "${DRY_RUN:-}" | tr '[:upper:]' '[:lower:]')" in
  '' | 0 | false) DRY=; echo "Mode: BROADCAST" ;;
  *) DRY=1; echo "Mode: DRY RUN (chain-writing commands are printed, not run)" ;;
esac

# Runs a command that writes to the chain, or prints it on a dry run.
send() {
  if [ -n "$DRY" ]; then
    echo "DRY RUN: $*"
  else
    "$@"
  fi
}

cluster_url() {
  if [ -n "${SOLANA_RPC_URL:-}" ]; then
    printf '%s' "$SOLANA_RPC_URL"
    return
  fi
  case "$1" in
    localnet) printf 'http://127.0.0.1:8899' ;;
    devnet) printf 'https://api.devnet.solana.com' ;;
    mainnet-beta) printf 'https://api.mainnet-beta.solana.com' ;;
  esac
}

# A keypair path from the environment: set, a readable file, and not inside the repository.
keypair() {
  local var="$1" value="${!1:-}"
  [ -n "$value" ] || fail "$var must be set to a keypair file outside the repository"
  [ -f "$value" ] || fail "$var does not name a file: $value"
  local real
  real="$(cd "$(dirname "$value")" && pwd -P)/$(basename "$value")"
  case "$real" in
    "$REPO_ROOT"/*) fail "$var points inside the repository; keep keypairs outside it" ;;
  esac
  printf '%s' "$real"
}

declared_id() {
  sed -n 's/^declare_id!("\([1-9A-HJ-NP-Za-km-z]\{32,44\}\)");$/\1/p' "$LIB_RS" | head -1
}

program_id() {
  if [ -n "${SOLANA_PROGRAM_ID:-}" ]; then
    printf '%s' "$SOLANA_PROGRAM_ID"
  else
    declared_id
  fi
}

build() {
  echo "Verifiable build (Anchor ${ANCHOR_VERSION}, Solana ${SOLANA_VERSION})"
  anchor build --verifiable --arch "$SBPF_ARCH"
  [ -f "$SO" ] || fail "verifiable build did not produce $SO"
  echo "Executable hash: $(solana-verify get-executable-hash "$SO")"
}

COMMAND="${1:-}"
CLUSTER="${2:-}"
case "$COMMAND" in
  deploy)
    case "$CLUSTER" in localnet | devnet) ;; mainnet-beta)
      fail "mainnet-beta is deployed through 'buffer' and the multisig, not 'deploy'" ;;
    *) usage ;; esac
    DEPLOYER="$(keypair SOLANA_DEPLOYER_KEYPAIR)"
    PROGRAM_KP="$(keypair SOLANA_PROGRAM_KEYPAIR)"
    KP_ID="$(solana-keygen pubkey "$PROGRAM_KP")"
    [ "$KP_ID" = "$(declared_id)" ] ||
      fail "SOLANA_PROGRAM_KEYPAIR is $KP_ID but $LIB_RS declares $(declared_id); update declare_id! and Anchor.toml in a reviewed change first"
    build
    send solana program deploy "$SO" --program-id "$PROGRAM_KP" \
      --keypair "$DEPLOYER" --upgrade-authority "$DEPLOYER" --url "$(cluster_url "$CLUSTER")"
    echo "Deployed program $KP_ID on $CLUSTER; run 'make contract solana verify $CLUSTER'"
    ;;
  buffer)
    case "$CLUSTER" in localnet | devnet | mainnet-beta) ;; *) usage ;; esac
    if [ "$CLUSTER" = "mainnet-beta" ] && [ -z "${SOLANA_UPGRADE_AUTHORITY:-}" ]; then
      fail "SOLANA_UPGRADE_AUTHORITY must name the multisig that executes the mainnet-beta upgrade"
    fi
    DEPLOYER="$(keypair SOLANA_DEPLOYER_KEYPAIR)"
    URL="$(cluster_url "$CLUSTER")"
    build
    if [ -n "$DRY" ]; then
      send solana program write-buffer "$SO" --keypair "$DEPLOYER" --url "$URL"
      BUFFER="<buffer>"
    else
      OUT="$(solana program write-buffer "$SO" --keypair "$DEPLOYER" --url "$URL" --output json)"
      BUFFER="$(printf '%s' "$OUT" | sed -n 's/.*"buffer": *"\([1-9A-HJ-NP-Za-km-z]*\)".*/\1/p')"
      [ -n "$BUFFER" ] || fail "could not read the buffer address from: $OUT"
    fi
    echo "Buffer: $BUFFER"
    if [ -n "${SOLANA_UPGRADE_AUTHORITY:-}" ]; then
      send solana program set-buffer-authority "$BUFFER" \
        --new-buffer-authority "$SOLANA_UPGRADE_AUTHORITY" --keypair "$DEPLOYER" --url "$URL"
      echo "Buffer authority is $SOLANA_UPGRADE_AUTHORITY; it executes the upgrade of $(program_id) from $BUFFER, then run 'make contract solana verify $CLUSTER'"
    else
      echo "Next: make contract solana upgrade $CLUSTER $BUFFER"
    fi
    ;;
  upgrade)
    case "$CLUSTER" in localnet | devnet) ;; mainnet-beta)
      fail "the multisig executes mainnet-beta upgrades from a buffer; see 'buffer'" ;;
    *) usage ;; esac
    BUFFER="${3:-}"
    [ -n "$BUFFER" ] || usage
    DEPLOYER="$(keypair SOLANA_DEPLOYER_KEYPAIR)"
    send solana program upgrade "$BUFFER" "$(program_id)" \
      --upgrade-authority "$DEPLOYER" --keypair "$DEPLOYER" --url "$(cluster_url "$CLUSTER")"
    echo "Upgraded $(program_id) on $CLUSTER from $BUFFER; run 'make contract solana verify $CLUSTER'"
    ;;
  verify)
    case "$CLUSTER" in localnet | devnet | mainnet-beta) ;; *) usage ;; esac
    build
    LOCAL="$(solana-verify get-executable-hash "$SO")"
    ONCHAIN="$(solana-verify get-program-hash --url "$(cluster_url "$CLUSTER")" "$(program_id)")"
    echo "Build:    $LOCAL"
    echo "On chain: $ONCHAIN"
    [ "$LOCAL" = "$ONCHAIN" ] ||
      fail "program $(program_id) on $CLUSTER does not match this verifiable build"
    echo "Verified: $(program_id) on $CLUSTER matches this verifiable build"
    ;;
  *) usage ;;
esac
