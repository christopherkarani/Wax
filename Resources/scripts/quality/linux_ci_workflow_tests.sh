#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/waxcore-linux.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Eq 'swift-actions/setup-swift@[0-9a-f]{40} # v2' "$WORKFLOW" \
  || fail "Linux CI must install the requested Swift toolchain"

grep -Eq 'swift build --product Wax([[:space:]]|$)' "$WORKFLOW" \
  || fail "Linux CI must build the public Wax product"

grep -Fq 'swift build --product wax-cli --traits default,MCPServer' "$WORKFLOW" \
  || fail "Linux CI must build wax-cli with MCPServer traits"

grep -Fq 'swift build --product wax-mcp --traits default,MCPServer' "$WORKFLOW" \
  || fail "Linux CI must build wax-mcp with MCPServer traits"

grep -Fq 'Resources/scripts/quality/daemon_sigterm_smoke.sh "$BIN_DIR/wax-cli" "$BIN_DIR/wax-mcp"' "$WORKFLOW" \
  || fail "Linux CI must smoke-test SIGTERM shutdown of wax-cli and wax-mcp"

[ -x "$ROOT_DIR/Resources/scripts/quality/daemon_sigterm_smoke.sh" ] \
  || fail "daemon_sigterm_smoke.sh must exist and be executable"

grep -Fq 'swift test --filter WaxCoreTests' "$WORKFLOW" \
  || fail "Linux CI must run WaxCoreTests"

if grep -E '^[[:space:]]+run:' "$WORKFLOW" | grep -q -- '-DGRDBCUSTOMSQLITE'; then
  fail "Linux CI must not pass -DGRDBCUSTOMSQLITE; GRDB 7 SPM imports GRDBSQLite, and that define selects an empty custom-SQLite import"
fi

echo "linux_ci_workflow_tests: ok"
