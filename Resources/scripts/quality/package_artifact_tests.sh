#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WAXMCP_PACKAGE="$ROOT_DIR/Resources/npm/waxmcp/package.json"
WAXMCP_VERIFY="$ROOT_DIR/Resources/npm/waxmcp/scripts/verify-dist.mjs"
OPENCLAW_PACKAGE="$ROOT_DIR/Resources/openclaw/wax-memory-plugin/package.json"
OPENCLAW_PLUGIN="$ROOT_DIR/Resources/openclaw/wax-memory-plugin/openclaw.plugin.json"
OPENCLAW_DIST="$ROOT_DIR/Resources/openclaw/wax-memory-plugin/dist/index.js"
OPENCLAW_SRC="$ROOT_DIR/Resources/openclaw/wax-memory-plugin/src/index.ts"
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

node -e '
const fs = require("fs");
const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!pkg.files?.includes("dist")) process.exit(1);
if (pkg.files?.includes("src")) process.exit(2);
if (!pkg.openclaw?.extensions?.includes("./dist/index.js")) process.exit(3);
if (pkg.dependencies?.waxmcp !== pkg.version) process.exit(4);
' "$OPENCLAW_PACKAGE" || fail "OpenClaw package must publish built JS instead of TypeScript source"

[[ -f "$OPENCLAW_DIST" ]] || fail "OpenClaw dist/index.js is missing"
[[ -f "$OPENCLAW_SRC" ]] || fail "OpenClaw source file should remain for maintainers"
grep -Fq 'command: api.pluginConfig?.command ?? "waxmcp"' "$OPENCLAW_DIST" \
  || fail "OpenClaw runtime must default to the waxmcp launcher"
grep -Fq '"placeholder": "waxmcp"' "$OPENCLAW_PLUGIN" \
  || fail "OpenClaw plugin metadata must not suggest unavailable wax-mcp command"

echo "package_artifact_tests: ok"
