#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/release-waxmcp.yml"

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

echo "release_workflow_tests: ok"
