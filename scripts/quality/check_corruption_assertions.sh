#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

TARGET_FILE="Tests/WaxCoreTests/ProductionReadinessRecoveryTests.swift"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "FAIL: missing corruption contract test file: $TARGET_FILE" >&2
  exit 1
fi

corruption_tests="$(rg -n "@Test.*(corrupt|truncat)" "$TARGET_FILE" | wc -l | tr -d ' ')"
if [[ "${corruption_tests:-0}" -lt 2 ]]; then
  echo "FAIL: expected at least 2 corruption/truncation tests in $TARGET_FILE" >&2
  exit 1
fi

if ! rg -n "catch let error as WaxError" "$TARGET_FILE" >/dev/null; then
  echo "FAIL: corruption tests must assert explicit WaxError types" >&2
  exit 1
fi

if ! rg -n "reason\\.contains\\(" "$TARGET_FILE" >/dev/null; then
  echo "FAIL: corruption tests must assert explicit error messages" >&2
  exit 1
fi

echo "PASS: corruption assertion contracts detected."
