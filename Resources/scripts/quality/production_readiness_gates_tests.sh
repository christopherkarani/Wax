#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT="$ROOT_DIR/Resources/scripts/quality/production_readiness_gates.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Load gate functions without invoking the production gate modes.
FUNCTIONS_FILE="$TMP_DIR/production_readiness_gates_functions.sh"
awk '$0 != "main \"$@\"" { print }' "$SCRIPT" >"$FUNCTIONS_FILE"
# shellcheck source=/dev/null
source "$FUNCTIONS_FILE"

assert_accepts_summary() {
  local name="$1"
  local summary="$2"
  local log_file="$TMP_DIR/$name.log"
  printf '%s\n' "$summary" >"$log_file"

  local output
  output="$(assert_full_pass_rate "$log_file")"
  if [[ "$output" != *"PASS_RATE: 100.00%"* ]]; then
    echo "FAIL: expected 100% pass rate for $name, got: $output" >&2
    return 1
  fi
}

assert_rejects_summary() {
  local name="$1"
  local summary="$2"
  local log_file="$TMP_DIR/$name.log"
  printf '%s\n' "$summary" >"$log_file"

  if assert_full_pass_rate "$log_file" >/dev/null 2>&1; then
    echo "FAIL: expected pass-rate rejection for $name" >&2
    return 1
  fi
}

assert_accepts_summary \
  "swift-testing-singular" \
  "Executed 1 test, with 0 failures"

assert_accepts_summary \
  "swift-testing-plural" \
  "Executed 2 tests, with 0 failures"

assert_rejects_summary \
  "swift-testing-failure" \
  "Executed 2 tests, with 1 failure"

echo "production_readiness_gates_tests: ok"
