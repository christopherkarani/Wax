#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

run_and_capture() {
  local log_file="$1"
  shift

  set +e
  "$@" 2>&1 | tee "$log_file"
  local status=${PIPESTATUS[0]}
  set -e

  if [[ $status -ne 0 ]]; then
    echo "FAIL: command failed with status $status: $*" >&2
    return "$status"
  fi
}

assert_no_skips() {
  local log_file="$1"
  if grep -E "(Test skipped|test skipped)" "$log_file" >/dev/null; then
    echo "FAIL: skipped tests detected in $log_file" >&2
    return 1
  fi
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
  failures="$(echo "$summary" | sed -E 's/.* and ([0-9]+) failures.*/\1/')"
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

run_full() {
  local log_file="/tmp/wax-gate-full.log"
  local skip_regex
  skip_regex="(RAGBenchmarks|RAGBenchmarksMiniLM|WALCompactionBenchmarks|LongMemoryBenchmarkHarness|BatchEmbeddingBenchmark|MetalVectorEngineBenchmark|OptimizationComparisonBenchmark|TokenizerBenchmark|BufferSerializationBenchmark)"

  run_and_capture "$log_file" \
    swift test --parallel --skip "$skip_regex"
  assert_no_skips "$log_file"
  assert_full_pass_rate "$log_file"

  bash "$ROOT_DIR/scripts/quality/check_corruption_assertions.sh"
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
