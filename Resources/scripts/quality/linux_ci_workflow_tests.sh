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

grep -Eq 'swift build --product Wax([[:space:]]|$)' "$WORKFLOW" \
  || fail "Linux CI must build the public Wax product"

grep -Fq 'swift build --product wax-cli --traits default,MCPServer' "$WORKFLOW" \
  || fail "Linux CI must build wax-cli with MCPServer traits"

grep -Fq 'swift build --product wax-mcp --traits default,MCPServer' "$WORKFLOW" \
  || fail "Linux CI must build wax-mcp with MCPServer traits"

grep -Fq 'swift test --filter WaxCoreTests' "$WORKFLOW" \
  || fail "Linux CI must run WaxCoreTests"

if grep -E '^[[:space:]]+run:' "$WORKFLOW" | grep -q -- '-DGRDBCUSTOMSQLITE'; then
  fail "Linux CI must not pass -DGRDBCUSTOMSQLITE; GRDB 7 SPM imports GRDBSQLite, and that define selects an empty custom-SQLite import"
fi

echo "linux_ci_workflow_tests: ok"
