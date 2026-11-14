#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"

# Per-run log directory: fixed /tmp paths collide when two gate runs share a
# machine and ignore $TMPDIR. Override with GATE_LOG_DIR to keep logs elsewhere.
GATE_LOG_DIR="${GATE_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/wax-gate.XXXXXX")}"
mkdir -p "$GATE_LOG_DIR"

# Tests that started and never finished, in start order. A timed-out run otherwise shows
# only its log tail, where a test that hung long before the timeout does not appear.
# Handles swift-testing ("Test x() started." / "passed|failed after" / "skipped:") and
# XCTest ("Test Case '-[S t]' started." / "passed|failed (").
unfinished_tests() {
  local log_file="$1"
  sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g; s/\r$//' "$log_file" 2>/dev/null \
    | sed -nE \
      -e "/Test Case '/{
            s/.*Test Case '(-\[[^]]+\])' started.*/START \1/p
            s/.*Test Case '(-\[[^]]+\])' (passed|failed) .*/END \1/p
            d
          }" \
      -e '/recorded an issue/d' \
      -e '/Test run (started|with)/d' \
      -e '/Test case passing /d' \
      -e 's/ with [0-9]+ test cases? (passed|failed) after / \1 after /' \
      -e 's/.*Test (.+) started\.$/START \1/p' \
      -e 's/.*Test (.+) (passed|failed) after .*/END \1/p' \
      -e 's/.*Test (.+) skipped(:.*)?$/END \1/p' \
    | awk '
        $1 == "START" { name = substr($0, 7); if (!(name in open)) order[++n] = name; open[name] = 1 }
        $1 == "END" { delete open[substr($0, 5)] }
        END { for (i = 1; i <= n; i++) if (order[i] in open) print order[i] }
      '
}

# Runs "$@" under a pseudo-terminal so Swift line-buffers, with all output in
# $1. `exec` keeps the caller's `$!` on the `script` process itself.
# BSD script (macOS) takes the command as arguments. util-linux script (Linux)
# rejects -F, takes one shell string via -c, and needs -e to return the
# command's exit status; it also writes "Script started/done" lines to the log.
run_under_pty() {
  local log_file="$1"
  shift
  if script --version 2>/dev/null | grep -q util-linux; then
    local command_string
    printf -v command_string '%q ' "$@"
    # -c runs the string with $SHELL; %q quoting is bash syntax.
    SHELL="${BASH:-/bin/bash}" exec script -q -f -e -c "$command_string" "$log_file"
  fi
  exec script -q -F "$log_file" "$@"
}

descendant_pids() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendant_pids "$child"
  done
}

run_and_capture() {
  local log_file="$1"
  shift
  local status cmd_pid heartbeat_pid start_ts now_ts timed_out=0
  local timeout_secs="${GATE_CMD_TIMEOUT_SECS:-2700}"
  local last_line
  local shell_flags=$-

  # Full swift test output is large (it used to include hundreds of MB of
  # swift-testing package deprecation warnings). Teeing it onto stdout stalls the GitHub
  # Actions log pipe (local Popen has the same failure). Keep the full
  # log on disk for skip/pass-rate checks; print only breadcrumbs.
  # Run under a PTY (`script`) so Swift line-buffers; a plain file redirect
  # froze the log while tests were still passing (CI 20m false timeout).
  echo "GATE_CMD: $*"
  echo "GATE_LOG: $log_file"
  echo "GATE_TIMEOUT_SECS: $timeout_secs"
  : >"$log_file"

  set +e
  if command -v script >/dev/null 2>&1; then
    run_under_pty "$log_file" "$@" >/dev/null 2>&1 &
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
      unfinished_tests "$log_file" | head -n 40 | sed 's/^/GATE_UNFINISHED_TEST /'
      # Test-spawned processes still alive (daemons, CLI children) often explain a hang.
      ps -axo pid,ppid,etime,command 2>/dev/null \
        | grep -E "wax|xctest|swiftpm-testing-helper" | grep -v grep | head -n 40 \
        | sed 's/^/GATE_LIVE_PROCESS /' || true
      # Every thread's stack in a hung test process says where it is stuck (macOS only).
      if command -v sample >/dev/null 2>&1; then
        local test_pid
        for test_pid in $(descendant_pids "$cmd_pid"); do
          ps -o command= -p "$test_pid" 2>/dev/null | grep -qE "swiftpm-testing-helper|xctest" || continue
          sample "$test_pid" 3 2>/dev/null | head -n 600 | sed "s/^/GATE_STACK ${test_pid} /" || true
        done
      fi
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
    grep -E "recorded an issue|✘|error:" "$log_file" 2>/dev/null | grep -v "skipped" | tail -n 40 >&2 || true
    tail -n 80 "$log_file" >&2 || true
    return 124
  fi
  if [[ $status -ne 0 ]]; then
    echo "FAIL: command failed with status $status: $*" >&2
    # swift-testing writes failures mid-stream; a bare tail loses them. Surface
    # the failing assertions first, then the tail for context.
    grep -E "recorded an issue|✘|error:" "$log_file" 2>/dev/null | grep -v "skipped" | tail -n 40 >&2 || true
    tail -n 80 "$log_file" >&2 || true
    return "$status"
  fi
}

# Optional suites that use Swift Testing `.disabled` / XCTest `XCTSkip` unless an
# explicit env var or package trait is set. These are not silent product gaps.
expected_optional_skip_pattern() {
  printf '%s' \
    "Set WAX_TEST_ARCTIC=1|Set WAX_TEST_E5=1|Set WAX_TEST_RERANKER=1|Set WAX_TEST_MINILM=1|Set WAX_GENERATE_MINILM_FIXTURES=1|Build with --traits default,WaxRepo|Build with --traits default,MCPServer|Set WAX_RUN_XCTEST_BENCHMARKS=1|Set WAX_BENCHMARK_|Requires macOS 26.0"
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
    # swift test on Linux prints no XCTest summary when no XCTest case is
    # selected; the Swift Testing count must then be positive, as below.
    if grep -E "Test run with 0 tests? (in [0-9]+ suites? )?passed" "$log_file" >/dev/null; then
      echo "FAIL: swift-testing ran 0 tests and no XCTest summary was found." >&2
      return 1
    fi
    if grep -E "Test run with [1-9][0-9]* tests? (in [0-9]+ suites? )?passed" "$log_file" >/dev/null; then
      echo "PASS_RATE: 100.00% (swift-testing; no XCTest summary line)"
      return 0
    fi
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
    # Swift Testing emits an XCTest wrapper of "Executed 0 tests" when the
    # selected filter has no XCTest cases. Require a positive swift-testing
    # count so an empty --filter cannot green as 100%. Newer Swift Testing
    # prints "Test run with N tests in M suites passed".
    if grep -E "Test run with [1-9][0-9]* tests? (in [0-9]+ suites? )?passed" "$log_file" >/dev/null; then
      echo "PASS_RATE: 100.00% (swift-testing; XCTest wrapper executed 0)"
      return 0
    fi
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
  # Package.swift is swift-tools-version 6.2; an older compiler would fail later
  # with a less obvious manifest error.
  local swift_version
  swift_version="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
  if [[ -n "$swift_version" ]] \
     && [[ "$(printf '%s\n' "6.2" "$swift_version" | sort -V | head -n 1)" != "6.2" ]]; then
    echo "FAIL: Swift $swift_version is too old; this package needs Swift 6.2+." >&2
    return 1
  fi
  # Capture first: under pipefail, `grep -q` exiting early SIGPIPEs swift and
  # fails the pipeline even when the option is listed (seen on Linux).
  local test_help
  test_help="$(swift test --help 2>&1 || true)"
  if ! grep -q -- "--traits <traits>" <<<"$test_help"; then
    echo "FAIL: current Swift toolchain does not support package traits (--traits)." >&2
    echo "Install a Swift toolchain that supports package traits (Swift 6.2+)." >&2
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
  if ! grep -E "^WaxCLITests\.WaxCLIMemoryTests/mcpDoctorIsHostAgnosticAndValidatesDailyToolSurface\(\)" "$log_file" >/dev/null; then
    echo "FAIL: MCPServer trait test list is missing WaxCLITests.WaxCLIMemoryTests/mcpDoctorIsHostAgnosticAndValidatesDailyToolSurface()." >&2
    return 1
  fi
  if ! grep -E "^WaxCLITests\.WaxCLIMemoryTests/mcpDoctorSmokeChecksIsolatedStoreWhenTargetStoreIsHeld\(\)" "$log_file" >/dev/null; then
    echo "FAIL: MCPServer trait test list is missing WaxCLITests.WaxCLIMemoryTests/mcpDoctorSmokeChecksIsolatedStoreWhenTargetStoreIsHeld()." >&2
    return 1
  fi

  local count
  count="$(grep -Ec "^wax_mcpTests\." "$log_file")"
  echo "MCP_TRAIT_TESTS: listed=$count"
}

assert_mcp_cli_doctor_smokes_ran() {
  local log_file="$1"
  local id
  for id in \
    mcpDoctorIsHostAgnosticAndValidatesDailyToolSurface \
    mcpDoctorSmokeChecksIsolatedStoreWhenTargetStoreIsHeld
  do
    if grep -E "Test ${id}\(\) skipped:" "$log_file" >/dev/null; then
      echo "FAIL: MCPServer WaxCLI doctor smoke ${id} was skipped." >&2
      return 1
    fi
    if ! grep -F "$id" "$log_file" >/dev/null; then
      echo "FAIL: MCPServer WaxCLI run log is missing doctor smoke ${id}." >&2
      return 1
    fi
  done
  echo "MCP_CLI_DOCTOR_SMOKES: executed"
}

assert_mcp_trait_test_inventory() {
  local default_list_log="$GATE_LOG_DIR/wax-gate-default-test-list.log"
  local mcp_list_log="$GATE_LOG_DIR/wax-gate-mcp-test-list.log"

  run_and_capture "$default_list_log" \
    swift test --disable-automatic-resolution list
  assert_default_mcp_trait_tests_omitted "$default_list_log"

  run_and_capture "$mcp_list_log" \
    swift test --traits MCPServer list
  assert_mcp_trait_tests_listed "$mcp_list_log"
}

run_full() {
  local log_file="$GATE_LOG_DIR/wax-gate-full.log"
  local mcp_unit_log="$GATE_LOG_DIR/wax-gate-full-mcp-unit.log"
  local mcp_cli_log="$GATE_LOG_DIR/wax-gate-full-mcp-cli.log"
  local mcp_process_log="$GATE_LOG_DIR/wax-gate-full-mcp-process.log"
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

  # Doctor smokes live in WaxCLIMemoryTests, not wax_mcpTests. Keep this
  # slice filtered; do not restore an unfiltered MCPServer package run.
  run_and_capture "$mcp_cli_log" \
    swift test --parallel --traits MCPServer --filter WaxCLIMemoryTests
  assert_no_skips "$mcp_cli_log"
  assert_full_pass_rate "$mcp_cli_log"
  assert_mcp_cli_doctor_smokes_ran "$mcp_cli_log"

  run_and_capture "$mcp_process_log" \
    swift test --no-parallel --traits MCPServer --filter WaxMCPProcessTests
  assert_no_skips "$mcp_process_log"
  assert_full_pass_rate "$mcp_process_log"

  bash "$ROOT_DIR/Resources/scripts/quality/check_corruption_assertions.sh"
}

run_soak_smoke() {
  local stability_log="$GATE_LOG_DIR/wax-gate-soak-stability.log"
  local wal_log="$GATE_LOG_DIR/wax-gate-soak-wal.log"

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
  local stability_log="$GATE_LOG_DIR/wax-gate-burn-stability.log"
  local wal_log="$GATE_LOG_DIR/wax-gate-burn-wal.log"

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

# `full` tolerates these opt-in skips (expected_optional_skip_pattern). The
# opt-in-configs mode turns them on, so the same skip reason must not appear.
assert_opt_in_suite_ran() {
  local log_file="$1"
  local skip_reason="$2"
  if grep -F "$skip_reason" "$log_file" >/dev/null; then
    echo "FAIL: opt-in suite was skipped (\"$skip_reason\") in $log_file" >&2
    grep -F "$skip_reason" "$log_file" | head -n 10 >&2
    return 1
  fi
}

# Configurations that `full` skips: the WaxRepo trait build + its executable
# smoke tests, and real MiniLM inference (WAX_TEST_MINILM=1). Arctic stays
# opt-in. Every step runs even if an earlier one fails, so one regression
# cannot hide another; the mode fails at the end if any step failed.
# Steps return explicitly on failure: run_opt_in_configs calls them in an
# `||` context, where bash ignores `set -e`.
run_opt_in_waxrepo() {
  local waxrepo_build_log="$GATE_LOG_DIR/wax-gate-opt-in-waxrepo-build.log"
  local waxrepo_log="$GATE_LOG_DIR/wax-gate-opt-in-waxrepo.log"

  require_swiftpm_traits || return 1
  run_and_capture "$waxrepo_build_log" \
    swift build --traits WaxRepo --product WaxRepo || return 1

  run_and_capture "$waxrepo_log" \
    swift test --parallel --traits WaxRepo --filter 'waxTests\.waxRepo' || return 1
  assert_opt_in_suite_ran "$waxrepo_log" "Build with --traits default,WaxRepo" || return 1
  # Guard against a filter that silently matches nothing.
  grep -E "Test waxRepoFullReindexReplacesExistingStore\(\) passed" "$waxrepo_log" >/dev/null \
    || { echo "FAIL: WaxRepo executable smoke tests did not run" >&2; return 1; }
  assert_full_pass_rate "$waxrepo_log" || return 1
}

run_opt_in_minilm() {
  local minilm_log="$GATE_LOG_DIR/wax-gate-opt-in-minilm.log"

  run_and_capture "$minilm_log" env WAX_TEST_MINILM=1 \
    swift test --parallel --filter 'WaxIntegrationTests\.(miniLMEmbedder|minilmEmbedding)' || return 1
  assert_opt_in_suite_ran "$minilm_log" "Set WAX_TEST_MINILM=1" || return 1
  # Guard against a filter that silently matches nothing.
  grep -E "Test minilmEmbeddingsStayCloseToBaseline\(\) passed" "$minilm_log" >/dev/null \
    || { echo "FAIL: MiniLM quality suite did not run" >&2; return 1; }
  assert_full_pass_rate "$minilm_log" || return 1
}

run_opt_in_configs() {
  local step failed=()
  for step in run_opt_in_waxrepo run_opt_in_minilm; do
    if ! "$step"; then
      echo "OPT_IN_STEP_FAILED: $step" >&2
      failed+=("$step")
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "FAIL: opt-in-configs steps failed: ${failed[*]}" >&2
    return 1
  fi
}

# Real built-in embedder and reranker inference: the env-gated suites that
# `full` skips. On Linux they run on WaxMILRuntime instead of Core ML. Every
# gate env var is set, so none of their skip reasons may appear.
run_embedder_inference() {
  local log_file="$GATE_LOG_DIR/wax-gate-embedder-inference.log"
  local skip_reason

  run_and_capture "$log_file" env \
    WAX_TEST_MINILM=1 WAX_TEST_E5=1 WAX_TEST_ARCTIC=1 WAX_TEST_RERANKER=1 \
    swift test --parallel --skip "$(full_gate_skip_regex)" \
      --filter 'E5|Arctic|Reranker|WaxMILRuntimeTests|MiniLM|BertTokenizer'
  for skip_reason in \
    "Set WAX_TEST_MINILM=1" "Set WAX_TEST_E5=1" "Set WAX_TEST_ARCTIC=1" "Set WAX_TEST_RERANKER=1"
  do
    assert_opt_in_suite_ran "$log_file" "$skip_reason"
  done
  assert_no_skips "$log_file"
  assert_full_pass_rate "$log_file"
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
    opt-in-configs)
      run_opt_in_configs
      ;;
    embedder-inference)
      run_embedder_inference
      ;;
    all)
      run_full
      run_soak_smoke
      run_burn_smoke
      ;;
    *)
      echo "Usage: $0 [full|soak-smoke|burn-smoke|opt-in-configs|embedder-inference|all]" >&2
      exit 64
      ;;
  esac
}

main "$@"
