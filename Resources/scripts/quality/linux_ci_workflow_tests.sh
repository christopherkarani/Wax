#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/waxcore-linux.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'swift-actions/setup-swift@v2' "$WORKFLOW" \
  || fail "Linux CI must install the requested Swift toolchain"

grep -Fq 'swift build --product Wax ' "$WORKFLOW" \
  || fail "Linux CI must build the public Wax product"

grep -Fq 'swift build --product wax-cli --traits default,MCPServer' "$WORKFLOW" \
  || fail "Linux CI must build wax-cli with MCPServer traits"

grep -Fq 'swift build --product wax-mcp --traits default,MCPServer' "$WORKFLOW" \
  || fail "Linux CI must build wax-mcp with MCPServer traits"

echo "linux_ci_workflow_tests: ok"
