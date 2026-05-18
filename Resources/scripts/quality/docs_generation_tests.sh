#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/Resources/scripts/generate-docs.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"' "$SCRIPT" \
  || fail "docs generator must resolve the repository root, not Resources"

grep -Fq 'mktemp -d' "$SCRIPT" \
  || fail "docs generator must render into a temporary directory before replacing output"

grep -Fq 'swift package generate-documentation' "$SCRIPT" \
  || fail "docs generator must invoke SwiftPM documentation generation"

echo "docs_generation_tests: ok"
