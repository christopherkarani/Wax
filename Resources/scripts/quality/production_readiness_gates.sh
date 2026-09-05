#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"

run_and_capture() {
  local log_file="$1"
  shift
  local status cmd_pid heartbeat_pid start_ts now_ts timed_out=0
  local timeout_secs="${GATE_CMD_TIMEOUT_SECS:-2700}"
  local last_line
  local shell_flags=$-

  # Full swift test output includes hundreds of MB of swift-testing
  # deprecation warnings. Teeing that onto stdout stalls the GitHub
  # Actions log pipe (local Popen has the same failure). Keep the full
  # log on disk for skip/pass-rate checks; print only breadcrumbs.
  # Run under `script -F` so Swift line-buffers; a plain file redirect
  # froze the log while tests were still passing (CI 20m false timeout).
  echo "GATE_CMD: $*"
  echo "GATE_LOG: $log_file"
  echo "GATE_TIMEOUT_SECS: $timeout_secs"
  : >"$log_file"

  set +e
  if command -v script >/dev/null 2>&1; then
    script -q -F "$log_file" "$@" >/dev/null 2>&1 &
  else
    "$@" >"$log_file" 2>&1 &
  fi
  cmd_pid=$!
  start_ts=$(date +%s)
  (
    while sleep 30; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      last_line="$(tail -n 1 "$log_file" 2>/dev/null | tr -cd '[:print:]' | cut -c1-160)"
      echo "GATE_STILL_RUNNING bytes=$(wc -c <"$log_file" | tr -d ' ') last=${last_line}"
    done
  ) &
  heartbeat_pid=$!
  while kill -0 "$cmd_pid" 2>/dev/null; do
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= timeout_secs )); then
      timed_out=1
      echo "GATE_TIMEOUT ${timeout_secs}s: $*"
      last_line="$(tail -n 1 "$log_file" 2>/dev/null | tr -cd '[:print:]' | cut -c1-160)"
      echo "GATE_TIMEOUT_LAST ${last_line}"
      kill "$cmd_pid" 2>/dev/null || true
      sleep 2
      kill -9 "$cmd_pid" 2>/dev/null || true
      pkill -P "$cmd_pid" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  wait "$cmd_pid" 2>/dev/null
  status=$?
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true

  echo "GATE_DONE status=$status bytes=$(wc -c <"$log_file" | tr -d ' ')"
  if [[ $shell_flags == *e* ]]; then
    set -e
  fi
  if [[ $timed_out -ne 0 ]]; then
    echo "FAIL: command timed out after ${timeout_secs}s: $*" >&2
    tail -n 80 "$log_file" >&2 || true
    return 124
  fi
  if [[ $status -ne 0 ]]; then
    echo "FAIL: command failed with status $status: $*" >&2
    tail -n 80 "$log_file" >&2 || true
    return "$status"
  fi
}

# Optional suites that use Swift Testing `.disabled` / XCTest `XCTSkip` unless an
# explicit env var or package trait is set. These are not silent product gaps.
expected_optional_skip_pattern() {
  printf '%s' \
    "Set WAX_TEST_ARCTIC=1|Set WAX_TEST_MINILM=1|Set WAX_GENERATE_MINILM_FIXTURES=1|Build with --traits default,WaxRepo|Build with --traits default,MCPServer|Set WAX_RUN_XCTEST_BENCHMARKS=1|Set WAX_BENCHMARK_|Requires macOS 26.0"
}

assert_no_skips() {
  local log_file="$1"
  local skip_lines unexpected
  skip_lines="$(grep -E "([Tt]est skipped|(^|[[:space:]])(Suite|Test)[[:space:]].* skipped:)" "$log_file" || true)"
  if [[ -z "$skip_lines" ]]; then
    return 0
  fi

  unexpected="$(printf '%s\n' "$skip_lines" | grep -Ev "$(expected_optional_skip_pattern)" || true)"
  if [[ -n "$unexpected" ]]; then
    echo "FAIL: skipped tests detected in $log_file" >&2
    printf '%s\n' "$unexpected" >&2
    return 1
  fi
  echo "EXPECTED_SKIPS: env/trait-gated optional suites omitted"
}

# Heavy XCTest benches and soak/burn profiles belong in dedicated jobs, not `full`.
# Keep historical class names so a rename cannot silently reintroduce a 10k-doc run.
full_gate_skip_regex() {
  printf '%s' \
    "(RAGPerformanceBenchmarks|RAGMiniLMBenchmarks|RAGBenchmarks|RAGBenchmarksMiniLM|WALCompactionBenchmarks|LongMemoryBenchmarkHarness|BatchEmbeddingBenchmark|MetalVectorEngineBenchmark|OptimizationComparisonBenchmark|TokenizerBenchmark|BufferSerializationBenchmark|HybridVectorEngineBenchmark|HandoffLookupBenchmarks|PayloadLivenessBenchmarks|SessionRuntimeStatsBenchmarks|StoreBloatBenchmarks|RememberDedupBenchmarks|SurrogateSourceBenchmarks|ArcticPerformanceBenchmark|AccessStatsBootstrapBenchmarks|ProductionReadinessStabilityTests)"
}

assert_full_pass_rate() {
  local log_file="$1"

  if grep -E "Test run with [0-9]+ tests.*failed" "$log_file" >/dev/null; then
    echo "FAIL: swift-testing reported failed tests." >&2
    return 1
  fi

  local summary
  summary="$(grep -E "Executed [0-9]+ tests?" "$log_file" | tail -n1 || true)"
  if [[ -z "$summary" ]]; then
    echo "PASS_RATE: 100.00% (no XCTest summary line found, using command exit status)"
    return 0
  fi

  local executed skipped failures runnable passed
  executed="$(echo "$summary" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')"
  skipped="$(echo "$summary" | sed -nE 's/.*with ([0-9]+) test skipped.*/\1/p')"
  failures="$(echo "$summary" | sed -nE 's/.*(and|with) ([0-9]+) failures?.*/\2/p')"
  skipped="${skipped:-0}"

  runnable=$((executed - skipped))
  if [[ $runnable -le 0 ]]; then
    echo "FAIL: no runnable XCTest cases detected." >&2
    return 1
  fi

  passed=$((runnable - failures))
  local pass_rate
  pass_rate="$(awk -v p="$passed" -v r="$runnable" 'BEGIN { printf "%.2f", (p/r)*100 }')"
  echo "PASS_RATE: ${pass_rate}% (passed=$passed runnable=$runnable)"

  if [[ "$pass_rate" != "100.00" ]]; then
    echo "FAIL: pass rate below 100%." >&2
    return 1
  fi
}

require_swiftpm_traits() {
  if ! swift test --help | grep -q -- "--traits <traits>"; then
    echo "FAIL: current Swift toolchain does not support package traits (--traits)." >&2
    echo "Install a Swift toolchain that supports package traits (for example Swift 6.1+)." >&2
    return 1
  fi
}

assert_default_mcp_trait_tests_omitted() {
  local log_file="$1"
  if grep -E "^wax_mcpTests\.(WaxMCPProcessTests[/.]|toolsListContainsExpectedTools\(\)|toolsRememberRecallSearchFlushStatsHappyPath\(\)|vectorSearchRememberFlushRecallHappyPath\(\))" "$log_file" >/dev/null; then
    echo "FAIL: default SwiftPM test list unexpectedly includes MCP trait suites." >&2
    return 1
  fi
  echo "MCP_TRAIT_DEFAULT_LIST: real MCP trait suites omitted as expected"
}

assert_mcp_trait_tests_listed() {
  local log_file="$1"
  if ! grep -E "^wax_mcpTests\.WaxMCPProcessTests[/.]" "$log_file" >/dev/null; then
    echo "FAIL: MCPServer trait test list is missing wax_mcpTests.WaxMCPProcessTests." >&2
    return 1
  fi
  if ! grep -E "^wax_mcpTests\.toolsListContainsExpectedTools\(\)" "$log_file" >/dev/null; then
    echo "FAIL: MCPServer trait test list is missing wax_mcpTests.toolsListContainsExpectedTools()." >&2
    return 1
  fi

  local count
  count="$(grep -Ec "^wax_mcpTests\." "$log_file")"
  echo "MCP_TRAIT_TESTS: listed=$count"
}

assert_mcp_trait_test_inventory() {
  local default_list_log="/tmp/wax-gate-default-test-list.log"
  local mcp_list_log="/tmp/wax-gate-mcp-test-list.log"

  run_and_capture "$default_list_log" \
    swift test --disable-automatic-resolution list
  assert_default_mcp_trait_tests_omitted "$default_list_log"

  run_and_capture "$mcp_list_log" \
    swift test --traits MCPServer list
  assert_mcp_trait_tests_listed "$mcp_list_log"
}

run_full() {
  local log_file="/tmp/wax-gate-full.log"
  local mcp_unit_log="/tmp/wax-gate-full-mcp-unit.log"
  local mcp_process_log="/tmp/wax-gate-full-mcp-process.log"
  local skip_regex
  skip_regex="$(full_gate_skip_regex)"

  run_and_capture "$log_file" \
    swift test --parallel --skip "$skip_regex"
  assert_no_skips "$log_file"
  assert_full_pass_rate "$log_file"

  require_swiftpm_traits
  assert_mcp_trait_test_inventory

  # Do not re-run the default suite serially under --traits MCPServer: that
  # hung GitHub macos-15 for 75m with a frozen log after compile. Keep
  # trait-gated unit tests parallel; serialize only process tests that share
  # ports/locks.
  run_and_capture "$mcp_unit_log" \
    swift test --parallel --traits MCPServer --filter wax_mcpTests --skip "${skip_regex}|WaxMCPProcessTests"
  assert_no_skips "$mcp_unit_log"
  assert_full_pass_rate "$mcp_unit_log"

  run_and_capture "$mcp_process_log" \
    swift test --no-parallel --traits MCPServer --filter WaxMCPProcessTests
  assert_no_skips "$mcp_process_log"
  assert_full_pass_rate "$mcp_process_log"

  bash "$ROOT_DIR/Resources/scripts/quality/check_corruption_assertions.sh"
}

run_soak_smoke() {
  local stability_log="/tmp/wax-gate-soak-stability.log"
  local wal_log="/tmp/wax-gate-soak-wal.log"

  run_and_capture "$stability_log" env \
    WAX_REPLAY_SEED="${WAX_REPLAY_SEED:-2026021801}" \
    WAX_REPLAY_ITERATIONS="${WAX_REPLAY_ITERATIONS:-700}" \
    WAX_STABILITY_MAX_RSS_GROWTH_MB="${WAX_STABILITY_MAX_RSS_GROWTH_MB:-256}" \
    WAX_STABILITY_MAX_P50_DRIFT_PCT="${WAX_STABILITY_MAX_P50_DRIFT_PCT:-140}" \
    WAX_STABILITY_MAX_P95_DRIFT_PCT="${WAX_STABILITY_MAX_P95_DRIFT_PCT:-180}" \
    WAX_STABILITY_SEARCH_MODE="${WAX_STABILITY_SEARCH_MODE:-hybrid}" \
    WAX_STABILITY_OUTPUT="${WAX_STABILITY_OUTPUT:-/tmp/wax-soak-stability.json}" \
    swift test --enable-xctest --disable-swift-testing --filter ProductionReadinessStabilityTests.testSoakSmokeStability
  assert_no_skips "$stability_log"

  run_and_capture "$wal_log" env \
    WAX_BENCHMARK_WAL_COMPACTION=1 \
    WAX_BENCHMARK_WAL_GUARDRAILS=1 \
    swift test --enable-xctest --disable-swift-testing --filter WALCompactionBenchmarks.testProactivePressureGuardrails
  assert_no_skips "$wal_log"
}

run_burn_smoke() {
  local stability_log="/tmp/wax-gate-burn-stability.log"
  local wal_log="/tmp/wax-gate-burn-wal.log"

  run_and_capture "$stability_log" env \
    WAX_REPLAY_SEED="${WAX_REPLAY_SEED:-2026021802}" \
    WAX_REPLAY_ITERATIONS="${WAX_REPLAY_ITERATIONS:-1800}" \
    WAX_STABILITY_MAX_RSS_GROWTH_MB="${WAX_STABILITY_MAX_RSS_GROWTH_MB:-512}" \
    WAX_STABILITY_MAX_P50_DRIFT_PCT="${WAX_STABILITY_MAX_P50_DRIFT_PCT:-200}" \
    WAX_STABILITY_MAX_P95_DRIFT_PCT="${WAX_STABILITY_MAX_P95_DRIFT_PCT:-260}" \
    WAX_STABILITY_SEARCH_MODE="${WAX_STABILITY_SEARCH_MODE:-hybrid}" \
    WAX_STABILITY_OUTPUT="${WAX_STABILITY_OUTPUT:-/tmp/wax-burn-stability.json}" \
    swift test --enable-xctest --disable-swift-testing --filter ProductionReadinessStabilityTests.testBurnSmokeStability
  assert_no_skips "$stability_log"

  run_and_capture "$wal_log" env \
    WAX_BENCHMARK_WAL_COMPACTION=1 \
    WAX_BENCHMARK_WAL_REOPEN_GUARDRAILS=1 \
    swift test --enable-xctest --disable-swift-testing --filter WALCompactionBenchmarks.testReplayStateSnapshotGuardrails
  assert_no_skips "$wal_log"
}

main() {
  local mode="${1:-all}"
  case "$mode" in
    full)
      run_full
      ;;
    soak-smoke)
      run_soak_smoke
      ;;
    burn-smoke)
      run_burn_smoke
      ;;
    all)
      run_full
      run_soak_smoke
      run_burn_smoke
      ;;
    *)
      echo "Usage: $0 [full|soak-smoke|burn-smoke|all]" >&2
      exit 64
      ;;
  esac
}

main "$@"
