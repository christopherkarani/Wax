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

assert_rejects_skip_output() {
  local name="$1"
  local output="$2"
  local log_file="$TMP_DIR/$name.log"
  printf '%s\n' "$output" >"$log_file"

  if assert_no_skips "$log_file" >/dev/null 2>&1; then
    echo "FAIL: expected skipped-test rejection for $name" >&2
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

assert_rejects_skip_output \
  "swift-testing-suite-skipped" \
  "Suite FeatureFlaggedTests skipped: requires local fixture"

assert_rejects_skip_output \
  "swift-testing-test-skipped" \
  "Test testRequiresFixture() skipped: requires local fixture"

DEFAULT_TEST_LIST="$TMP_DIR/default-tests.txt"
cat >"$DEFAULT_TEST_LIST" <<'EOF'
waxTests.PackageTraitManifestTests/waxMCPProductEnablesMiniLMCompileDefine()
wax_mcpTests.mcpServerTestsRequireTrait()
EOF

assert_default_mcp_trait_tests_omitted "$DEFAULT_TEST_LIST"

MCP_TEST_LIST="$TMP_DIR/mcp-tests.txt"
cat >"$MCP_TEST_LIST" <<'EOF'
waxTests.PackageTraitManifestTests/waxMCPProductEnablesMiniLMCompileDefine()
wax_mcpTests.WaxMCPProcessTests/brokerAutoStartHandlesConcurrentFirstAccess()
wax_mcpTests.toolsListContainsExpectedTools()
EOF

assert_mcp_trait_tests_listed "$MCP_TEST_LIST"

CAPTURED_COMMANDS="$TMP_DIR/captured-gate-commands.txt"

run_and_capture() {
  local log_file="$1"
  shift
  printf '%s\n' "$*" >>"$CAPTURED_COMMANDS"
  : >"$log_file"
}

assert_no_skips() {
  local _log_file="$1"
}

assert_stability_gate_sets_search_mode() {
  local gate_name="$1"
  local function_name="$2"
  local test_filter="$3"
  local expected_mode="$4"
  local requested_mode="${5:-}"

  : >"$CAPTURED_COMMANDS"
  if [[ -n "$requested_mode" ]]; then
    WAX_STABILITY_SEARCH_MODE="$requested_mode" "$function_name"
  else
    unset WAX_STABILITY_SEARCH_MODE
    "$function_name"
  fi

  local stability_command
  stability_command="$(grep "$test_filter" "$CAPTURED_COMMANDS" || true)"
  if [[ "$stability_command" != *"WAX_STABILITY_SEARCH_MODE=$expected_mode"* ]]; then
    echo "FAIL: $gate_name stability gate did not pass WAX_STABILITY_SEARCH_MODE=$expected_mode" >&2
    echo "Captured: $stability_command" >&2
    return 1
  fi
}

unset WAX_STABILITY_SEARCH_MODE
assert_stability_gate_sets_search_mode \
  "soak-smoke" \
  run_soak_smoke \
  "ProductionReadinessStabilityTests.testSoakSmokeStability" \
  "hybrid"

assert_stability_gate_sets_search_mode \
  "burn-smoke" \
  run_burn_smoke \
  "ProductionReadinessStabilityTests.testBurnSmokeStability" \
  "hybrid"

assert_stability_gate_sets_search_mode \
  "soak-smoke override" \
  run_soak_smoke \
  "ProductionReadinessStabilityTests.testSoakSmokeStability" \
  "vector" \
  "vector"

echo "production_readiness_gates_tests: ok"
