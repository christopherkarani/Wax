#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WAXMCP_PACKAGE="$ROOT_DIR/Resources/npm/waxmcp/package.json"
WAXMCP_VERIFY="$ROOT_DIR/Resources/npm/waxmcp/scripts/verify-dist.mjs"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

node -e '
const fs = require("fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (pkg.scripts?.prepack !== "node scripts/verify-dist.mjs") process.exit(1);
' "$WAXMCP_PACKAGE" || fail "waxmcp package must verify dist artifacts before packing"

[[ -f "$WAXMCP_VERIFY" ]] || fail "waxmcp dist verifier is missing"
grep -Fq 'darwin-arm64' "$WAXMCP_VERIFY" || fail "waxmcp verifier must check darwin-arm64"
grep -Fq 'darwin-x64' "$WAXMCP_VERIFY" || fail "waxmcp verifier must check darwin-x64"

echo "package_artifact_tests: ok"
