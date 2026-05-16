#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/release-waxmcp.yml"
ROOT_RELEASE_SCRIPT="$ROOT_DIR/scripts/release-waxmcp.sh"
CANONICAL_RELEASE_SCRIPT="$ROOT_DIR/Resources/scripts/release-waxmcp.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if grep -Fq 'shasum -a 256 -c "$PLATFORM_DIR/wax-cli.sha256"' "$WORKFLOW"; then
  fail "build job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'sha256sum -c "$PLATFORM_DIR/wax-cli.sha256"' "$WORKFLOW"; then
  fail "build job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'shasum -a 256 -c "$chk"' "$WORKFLOW"; then
  fail "publish job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'sha256sum -c "$chk"' "$WORKFLOW"; then
  fail "publish job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'let serverVersion = "[0-9]' "$WORKFLOW"; then
  fail "release workflow extracts the stale serverVersion literal instead of WaxMCPServerMetadata.version"
fi

if grep -Fq 's/let serverVersion\s*=' "$ROOT_DIR/scripts/release-waxmcp.sh" "$ROOT_DIR/Resources/scripts/release-waxmcp.sh"; then
  fail "release scripts rewrite the stale serverVersion literal instead of WaxMCPServerMetadata.version"
fi

if grep -Fq 'perl -0pi' "$ROOT_RELEASE_SCRIPT"; then
  fail "root release script must delegate instead of duplicating release mutation logic"
fi

grep -Fq 'exec "$ROOT/Resources/scripts/release-waxmcp.sh" "$@"' "$ROOT_RELEASE_SCRIPT" \
  || fail "root release script must delegate to Resources/scripts/release-waxmcp.sh"

set_version_line="$(grep -n 'name: Set release version' "$WORKFLOW" | head -n 1 | cut -d: -f1 || true)"
build_line="$(grep -n 'name: Build binaries' "$WORKFLOW" | head -n 1 | cut -d: -f1 || true)"
[[ -n "$set_version_line" ]] || fail "release workflow must set the release version before building binaries"
[[ -n "$build_line" ]] || fail "release workflow must still build binaries"
(( set_version_line < build_line )) \
  || fail "release workflow sets package metadata after binaries are built"

grep -Fq './Resources/scripts/sync-waxmcp-version.sh' "$WORKFLOW" \
  || fail "release workflow must use the shared waxmcp version sync helper"

grep -Fq 'Resources/scripts/sync-waxmcp-version.sh' "$CANONICAL_RELEASE_SCRIPT" \
  || fail "canonical release script must use the shared waxmcp version sync helper"

echo "release_workflow_tests: ok"
