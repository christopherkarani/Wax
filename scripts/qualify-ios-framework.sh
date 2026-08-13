#!/usr/bin/env bash
# qualify-ios-framework.sh — one-command iOS framework qualification gate.
#
# Runs hygiene, build, test, consumer contracts, size measurement, public
# snippet verification, crash harness, TSan suites, TSan consumer build, and
# dependency-graph capture.
# Continues after a failed step and exits non-zero if any step failed.
#
# Evidence: WAX_QUALIFY_EVIDENCE_DIR (default /tmp/wax-qualify-evidence)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EVIDENCE_DIR="${WAX_QUALIFY_EVIDENCE_DIR:-/tmp/wax-qualify-evidence}"

# Brief named ConcurrencyStressTests|FoundationModelsConcurrencyTests|
# FoundationModelsCancellationTests. Real identifiers (see Tests/):
#   ConcurrencyStressTests.swift — free @Test functions, no suite of that name
#   FoundationModelSessionConcurrencyTests
#   FoundationModelSessionCancellationTests
TSAN_FILTER='memoryOrchestratorConcurrentIngestAndRecallNoRace|memoryOrchestratorRapidIngestRecallCyclesDoNotCrash|FoundationModelSessionConcurrencyTests|FoundationModelSessionCancellationTests'

HYGIENE_PATTERN='(^tasks/|^marketing/|issue[0-9]+_|snapshot|screenshot|TECHNICAL_ANALYSIS|audit-.*ledger|lessons\.md|todo\.md)'

STEPS=(
  hygiene
  build
  test
  consumer
  size
  snippets
  crash
  tsan
  tsan-consumer
  deps
)

SKIP_STEPS=()
RESULTS_FILE=""

usage() {
  cat <<'EOF'
Usage: scripts/qualify-ios-framework.sh [options]

One-command Wax iOS framework qualification gate. Continues on step
failure and exits 1 if any required step failed.

Options:
  -h, --help              Show this help
  --skip STEP[,STEP...]   Skip one or more steps (repeatable; STEP=all skips every step)
  --evidence-dir DIR      Evidence directory (overrides WAX_QUALIFY_EVIDENCE_DIR)

Steps:
  hygiene         git status, git diff --check, tracked-artifact scan
  build           swift build
  test            swift test
  consumer        scripts/test-consumer-contracts.sh
  size            scripts/measure-consumer-size.sh (archives JSON)
  snippets        swift scripts/verify-public-swift-snippets.swift
  crash           WAX_RUN_CRASH_HARNESS=1 swift test --filter CrashSafetyHarnessTests
  tsan            swift test --sanitize=thread (real suite/function names)
  tsan-consumer   swift build --package-path Tests/ConsumerContracts --sanitize=thread --product StrictConsumer
  deps            swift package dump-package + show-dependencies --format json

Environment:
  WAX_QUALIFY_EVIDENCE_DIR     Evidence directory (default /tmp/wax-qualify-evidence)
  WAX_QUALIFY_SKIP             Comma-separated steps to skip
  WAX_QUALIFY_SKIP_<STEP>=1    Skip a single step (hygiene, build, test, ...)
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

add_skips() {
  local remaining="$1"
  local piece
  while [[ -n "$remaining" ]]; do
    if [[ "$remaining" == *","* ]]; then
      piece="${remaining%%,*}"
      remaining="${remaining#*,}"
    else
      piece="$remaining"
      remaining=""
    fi
    piece="$(trim "$piece")"
    if [[ -n "$piece" ]]; then
      SKIP_STEPS+=("$piece")
    fi
  done
}

env_skip_flag() {
  local step="$1"
  case "$step" in
    hygiene) printf '%s' "${WAX_QUALIFY_SKIP_HYGIENE:-0}" ;;
    build) printf '%s' "${WAX_QUALIFY_SKIP_BUILD:-0}" ;;
    test) printf '%s' "${WAX_QUALIFY_SKIP_TEST:-0}" ;;
    consumer) printf '%s' "${WAX_QUALIFY_SKIP_CONSUMER:-0}" ;;
    size) printf '%s' "${WAX_QUALIFY_SKIP_SIZE:-0}" ;;
    snippets) printf '%s' "${WAX_QUALIFY_SKIP_SNIPPETS:-0}" ;;
    crash) printf '%s' "${WAX_QUALIFY_SKIP_CRASH:-0}" ;;
    tsan) printf '%s' "${WAX_QUALIFY_SKIP_TSAN:-0}" ;;
    tsan-consumer) printf '%s' "${WAX_QUALIFY_SKIP_TSAN_CONSUMER:-0}" ;;
    deps) printf '%s' "${WAX_QUALIFY_SKIP_DEPS:-0}" ;;
    *) printf '%s' "0" ;;
  esac
}

should_skip() {
  local step="$1"
  local item
  if [[ ${#SKIP_STEPS[@]} -gt 0 ]]; then
    for item in "${SKIP_STEPS[@]}"; do
      if [[ "$item" == "$step" || "$item" == "all" ]]; then
        return 0
      fi
    done
  fi
  if [[ "$(env_skip_flag "$step")" == "1" ]]; then
    return 0
  fi
  return 1
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

record_result() {
  local name="$1"
  local status="$2"
  local exit_code="$3"
  local seconds="$4"
  local start="$5"
  local end="$6"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$status" "$exit_code" "$seconds" "$start" "$end" >>"$RESULTS_FILE"
}

extract_size_json() {
  local log_file="$1"
  local dest="$2"
  if [[ ! -f "$log_file" ]]; then
    return 1
  fi
  python3 - "$log_file" "$dest" <<'PY'
import json
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
decoder = json.JSONDecoder()
found = None
idx = 0
while True:
    start = text.find("{", idx)
    if start < 0:
        break
    try:
        obj, end = decoder.raw_decode(text, start)
    except json.JSONDecodeError:
        idx = start + 1
        continue
    if isinstance(obj, dict) and "consumers" in obj:
        found = obj
    idx = end
if found is None:
    sys.exit(1)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(found, handle, indent=2)
    handle.write("\n")
PY
}

step_hygiene() {
  local hits=""
  local check_status=0
  git status --short --branch
  git diff --check || check_status=$?
  if command -v rg >/dev/null 2>&1; then
    hits="$(git ls-files | rg "$HYGIENE_PATTERN" || true)"
  else
    hits="$(git ls-files | grep -E "$HYGIENE_PATTERN" || true)"
  fi
  if [[ -n "$hits" ]]; then
    echo "FAIL: tracked planning/session artifacts:"
    printf '%s\n' "$hits"
    return 1
  fi
  echo "GREEN: no tracked planning/session artifacts"
  if [[ "$check_status" -ne 0 ]]; then
    echo "FAIL: git diff --check reported whitespace errors"
    return "$check_status"
  fi
  return 0
}

step_build() {
  swift build
}

step_test() {
  swift test
}

step_consumer() {
  WAX_CONSUMER_EVIDENCE_DIR="$EVIDENCE_DIR/consumer-contracts"
  export WAX_CONSUMER_EVIDENCE_DIR
  mkdir -p "$WAX_CONSUMER_EVIDENCE_DIR"
  "$REPO_ROOT/scripts/test-consumer-contracts.sh"
}

step_size() {
  "$REPO_ROOT/scripts/measure-consumer-size.sh"
}

step_snippets() {
  swift "$REPO_ROOT/scripts/verify-public-swift-snippets.swift"
}

step_crash() {
  WAX_RUN_CRASH_HARNESS=1 swift test --filter CrashSafetyHarnessTests
}

step_tsan() {
  swift test --sanitize=thread --filter "$TSAN_FILTER"
}

step_tsan_consumer() {
  swift build \
    --package-path "$REPO_ROOT/Tests/ConsumerContracts" \
    --sanitize=thread \
    --product StrictConsumer
}

step_deps() {
  local status=0
  if ! swift package dump-package >"$EVIDENCE_DIR/dump-package.json"; then
    status=1
  fi
  if ! swift package show-dependencies --format json >"$EVIDENCE_DIR/show-dependencies.json"; then
    status=1
  fi
  return "$status"
}

run_named_step() {
  local name="$1"
  case "$name" in
    hygiene) step_hygiene ;;
    build) step_build ;;
    test) step_test ;;
    consumer) step_consumer ;;
    size) step_size ;;
    snippets) step_snippets ;;
    crash) step_crash ;;
    tsan) step_tsan ;;
    tsan-consumer) step_tsan_consumer ;;
    deps) step_deps ;;
    *)
      echo "error: unknown step '$name'" >&2
      return 2
      ;;
  esac
}

run_step() {
  local name="$1"
  local log_file="$EVIDENCE_DIR/logs/${name}.log"
  local start end start_epoch end_epoch seconds status

  if should_skip "$name"; then
    start="$(iso_now)"
    echo "=== SKIP $name $start ==="
    record_result "$name" "SKIP" "-" "0" "$start" "$start"
    return 0
  fi

  start="$(iso_now)"
  start_epoch="$(date +%s)"
  echo "=== START $name $start ==="
  run_named_step "$name" 2>&1 | tee "$log_file"
  status="${PIPESTATUS[0]}"
  end="$(iso_now)"
  end_epoch="$(date +%s)"
  seconds=$((end_epoch - start_epoch))
  if [[ "$status" -eq 0 ]]; then
    echo "=== END $name PASS exit=0 seconds=$seconds $end ==="
    record_result "$name" "PASS" "0" "$seconds" "$start" "$end"
  else
    echo "=== END $name FAIL exit=$status seconds=$seconds $end ==="
    record_result "$name" "FAIL" "$status" "$seconds" "$start" "$end"
  fi
  if [[ "$name" == "size" ]]; then
    if extract_size_json "$log_file" "$EVIDENCE_DIR/consumer-size-report.json"; then
      echo "Archived size JSON: $EVIDENCE_DIR/consumer-size-report.json"
    else
      echo "warning: could not extract consumer size JSON from $log_file" >&2
    fi
  fi
}

write_summary() {
  local overall="PASS"
  local failed=0
  local skipped=0
  local passed=0
  local name status exit_code seconds start end

  echo
  echo "Qualification summary"
  printf '%-16s %-8s %6s %8s  %-20s  %s\n' \
    "STEP" "STATUS" "EXIT" "SECONDS" "START" "END"
  printf '%-16s %-8s %6s %8s  %-20s  %s\n' \
    "----" "------" "----" "-------" "-----" "---"

  while IFS=$'\t' read -r name status exit_code seconds start end; do
    printf '%-16s %-8s %6s %8s  %-20s  %s\n' \
      "$name" "$status" "$exit_code" "$seconds" "$start" "$end"
    case "$status" in
      FAIL)
        overall="FAIL"
        failed=$((failed + 1))
        ;;
      SKIP) skipped=$((skipped + 1)) ;;
      PASS) passed=$((passed + 1)) ;;
    esac
  done <"$RESULTS_FILE"

  echo
  echo "RESULT: $overall  (pass=$passed fail=$failed skip=$skipped)"
  echo "Evidence: $EVIDENCE_DIR"

  {
    echo "result=$overall"
    echo "pass=$passed"
    echo "fail=$failed"
    echo "skip=$skipped"
    echo "evidence=$EVIDENCE_DIR"
    echo
    cat "$RESULTS_FILE"
  } >"$EVIDENCE_DIR/summary.txt"

  python3 - "$RESULTS_FILE" "$EVIDENCE_DIR/summary.json" "$overall" "$passed" "$failed" "$skipped" "$EVIDENCE_DIR" <<'PY' || true
import json
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        name, status, exit_code, seconds, start, end = line.rstrip("\n").split("\t")
        rows.append({
            "step": name,
            "status": status,
            "exitCode": None if exit_code == "-" else int(exit_code),
            "seconds": int(seconds),
            "start": start,
            "end": end,
        })
report = {
    "result": sys.argv[3],
    "pass": int(sys.argv[4]),
    "fail": int(sys.argv[5]),
    "skip": int(sys.argv[6]),
    "evidenceDir": sys.argv[7],
    "steps": rows,
}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2)
    handle.write("\n")
PY

  if [[ "$overall" == "FAIL" ]]; then
    return 1
  fi
  return 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --skip)
        if [[ $# -lt 2 ]]; then
          echo "error: --skip requires a step name" >&2
          usage >&2
          exit 2
        fi
        add_skips "$2"
        shift 2
        ;;
      --skip=*)
        add_skips "${1#--skip=}"
        shift
        ;;
      --evidence-dir)
        if [[ $# -lt 2 ]]; then
          echo "error: --evidence-dir requires a path" >&2
          usage >&2
          exit 2
        fi
        EVIDENCE_DIR="$2"
        shift 2
        ;;
      --evidence-dir=*)
        EVIDENCE_DIR="${1#--evidence-dir=}"
        shift
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  if [[ -n "${WAX_QUALIFY_SKIP:-}" ]]; then
    add_skips "$WAX_QUALIFY_SKIP"
  fi

  cd "$REPO_ROOT" || exit 1
  mkdir -p "$EVIDENCE_DIR/logs" || exit 1
  RESULTS_FILE="$EVIDENCE_DIR/results.tsv"
  : >"$RESULTS_FILE"

  {
    echo "repo=$REPO_ROOT"
    echo "head=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "started=$(iso_now)"
    echo "tsanFilter=$TSAN_FILTER"
    if [[ ${#SKIP_STEPS[@]} -gt 0 ]]; then
      echo "skip=${SKIP_STEPS[*]}"
    else
      echo "skip="
    fi
    echo
    swift --version 2>/dev/null || true
  } >"$EVIDENCE_DIR/meta.txt"

  echo "Wax iOS framework qualification"
  echo "  repo:     $REPO_ROOT"
  echo "  evidence: $EVIDENCE_DIR"
  if [[ ${#SKIP_STEPS[@]} -gt 0 ]]; then
    echo "  skip:     ${SKIP_STEPS[*]}"
  fi
  echo

  local step
  for step in "${STEPS[@]}"; do
    run_step "$step"
  done

  write_summary
}

main "$@"
