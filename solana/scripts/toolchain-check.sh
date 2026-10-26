#!/usr/bin/env bash
# Fails unless the installed Anchor and Solana CLIs match toolchain.env.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./toolchain.env
fail() {
  echo "Error: $1" >&2
  echo "Install the pinned toolchain (see packages/contracts/solana/README.md):" >&2
  echo "  sh -c \"\$(curl -sSfL https://release.anza.xyz/v${SOLANA_VERSION}/install)\"" >&2
  echo "  cargo install --git https://github.com/solana-foundation/anchor avm --locked && avm install ${ANCHOR_VERSION} && avm use ${ANCHOR_VERSION}" >&2
  exit 1
}
command -v solana >/dev/null || fail "solana CLI not found"
command -v anchor >/dev/null || fail "anchor CLI not found"
solana --version | grep -q " ${SOLANA_VERSION} " || fail "solana CLI is not ${SOLANA_VERSION}: $(solana --version)"
anchor --version | grep -q " ${ANCHOR_VERSION}$" || fail "anchor CLI is not ${ANCHOR_VERSION}: $(anchor --version)"
