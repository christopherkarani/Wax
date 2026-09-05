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

assert_accepts_expected_skip() {
  local name="$1"
  local output="$2"
  local log_file="$TMP_DIR/$name.log"
  printf '%s\n' "$output" >"$log_file"

  local captured
  if ! captured="$(assert_no_skips "$log_file")"; then
    echo "FAIL: expected allowlisted skip to pass for $name" >&2
    return 1
  fi
  if [[ "$captured" != *"EXPECTED_SKIPS:"* ]]; then
    echo "FAIL: expected allowlisted skip acknowledgement for $name, got: $captured" >&2
    return 1
  fi
}

assert_accepts_expected_skip \
  "arctic-env-gated" \
  'Suite ArcticEmbedderTests skipped: "Set WAX_TEST_ARCTIC=1 to run Arctic embedder tests"'

assert_accepts_expected_skip \
  "minilm-env-gated" \
  'Test miniLMEmbedderProducesExpectedDimensions() skipped: "Set WAX_TEST_MINILM=1 to run MiniLM embedder inference tests"'

assert_accepts_expected_skip \
  "minilm-fixture-regen" \
  'Test generateMiniLMBaselineFixture() skipped: "Set WAX_GENERATE_MINILM_FIXTURES=1 to regenerate MiniLM baseline fixtures"'

assert_accepts_expected_skip \
  "waxrepo-trait-gated" \
  'Test waxRepoSearchQueryRunsOneShotAndExits() skipped: "Build with --traits default,WaxRepo on macOS 14+ to run WaxRepo executable smoke tests"'

assert_accepts_expected_skip \
  "mcp-trait-gated" \
  'Test mcpDoctorRecognizesRenamedToolSurface() skipped: "Build with --traits default,MCPServer to run wax-mcp smoke tests"'

assert_accepts_expected_skip \
  "platform-gated-docs" \
  'Test docsPasteFoundationModelsSessionCompilesAndCloses() skipped: "Requires macOS 26.0"'

skip_regex="$(full_gate_skip_regex)"
while IFS= read -r class_name; do
  [[ -n "$class_name" ]] || continue
  if [[ ! "$class_name" =~ $skip_regex ]]; then
    echo "FAIL: full-gate skip regex does not cover XCTest class $class_name" >&2
    echo "regex: $skip_regex" >&2
    exit 1
  fi
done < <(
  grep -R --include='*.swift' -h -E 'final class [A-Za-z0-9_]+(Benchmark|Benchmarks|BenchmarkHarness|StabilityTests): XCTestCase' \
    "$ROOT_DIR/Tests" \
    | sed -E 's/.*final class ([A-Za-z0-9_]+): XCTestCase.*/\1/' \
    | sort -u
)

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

if grep -F 'swift test --traits MCPServer --disable-automatic-resolution list' "$SCRIPT" >/dev/null; then
  echo "FAIL: MCP trait inventory must allow first-time trait dependency resolution" >&2
  exit 1
fi
if ! grep -F 'swift test --traits MCPServer list' "$SCRIPT" >/dev/null; then
  echo "FAIL: MCP trait inventory command is missing" >&2
  exit 1
fi
if ! grep -F 'swift test --no-parallel --traits MCPServer --skip' "$SCRIPT" >/dev/null; then
  echo "FAIL: MCPServer full gate must run serially" >&2
  exit 1
fi
if grep -E '\| tee "\$log_file"' "$SCRIPT" >/dev/null; then
  echo "FAIL: run_and_capture must not tee full swift output onto stdout (GitHub Actions log pipe stalls)" >&2
  exit 1
fi

QUALITY_GATES="$ROOT_DIR/.github/workflows/quality-gates.yml"
if ! grep -Fq 'cancel-in-progress: true' "$QUALITY_GATES"; then
  echo "FAIL: quality-gates.yml must cancel superseded in-progress runs" >&2
  exit 1
fi

SPAM_CMD="$TMP_DIR/spam-swift.sh"
cat >"$SPAM_CMD" <<'EOF'
#!/bin/bash
echo "/tmp/x.swift:1:2: warning: 'Test' is deprecated: Swift Testing is now included in the Swift 6 toolchain. [#DeprecatedDeclaration]"
echo "Executed 1 test, with 0 failures"
EOF
chmod +x "$SPAM_CMD"
SPAM_LOG="$TMP_DIR/spam-capture.log"
SPAM_STDOUT="$TMP_DIR/spam-stdout.txt"
run_and_capture "$SPAM_LOG" bash "$SPAM_CMD" >"$SPAM_STDOUT"
if ! grep -Fq "DeprecatedDeclaration" "$SPAM_LOG"; then
  echo "FAIL: run_and_capture must keep full command output in the log file" >&2
  exit 1
fi
if grep -Fq "DeprecatedDeclaration" "$SPAM_STDOUT"; then
  echo "FAIL: run_and_capture must not stream swift-testing deprecation warnings to stdout" >&2
  exit 1
fi
if ! grep -Fq "GATE_CMD:" "$SPAM_STDOUT"; then
  echo "FAIL: run_and_capture must print a short command breadcrumb on stdout" >&2
  exit 1
fi

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
