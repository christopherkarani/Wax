#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/verify-waxmcp-http.sh"

if ! grep -q '"method": "tools/call"' "$SCRIPT"; then
  echo "FAIL: HTTP verifier must call at least one MCP tool" >&2
  exit 1
fi

if ! grep -q '"name": "stats"' "$SCRIPT"; then
  echo "FAIL: HTTP verifier must exercise the stats tool" >&2
  exit 1
fi

echo "verify-waxmcp-http-tests: ok"
