#!/usr/bin/env bash
# Compiles VerdiktaValidationAdapter.sol against a pinned solc.
# Usage: bash build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOLC_VERSION="v0.8.37"
SOLC_URL="https://binaries.soliditylang.org/windows-amd64/solc-windows-amd64-${SOLC_VERSION}+commit.f401782d.exe"
# fallback for linux/mac users
SOLC_URL_LINUX="https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-${SOLC_VERSION}+commit.f401782d"
SOLC_URL_MAC="https://binaries.soliditylang.org/macosx-amd64/solc-macosx-amd64-${SOLC_VERSION}+commit.f401782d"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if command -v solc >/dev/null 2>&1; then
  SOLC="$(command -v solc)"
elif command -v solcjs >/dev/null 2>&1; then
  SOLC="$(command -v solcjs)"
else
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) URL="$SOLC_URL"; OUT="solc.exe" ;;
    Darwin)                URL="$SOLC_URL_MAC"; OUT="solc" ;;
    *)                     URL="$SOLC_URL_LINUX"; OUT="solc" ;;
  esac
  echo "Downloading solc ${SOLC_VERSION}..."
  curl -sL --max-time 180 -o "$TMP/$OUT" "$URL"
  chmod +x "$TMP/$OUT"
  SOLC="$TMP/$OUT"
fi

echo "Using: $("$SOLC" --version 2>&1 | head -2 | tail -1)"
echo "Compiling..."
"$SOLC" --bin --abi --optimize --via-ir "$HERE/VerdiktaValidationAdapter.sol" >/dev/null
echo "compile OK"
