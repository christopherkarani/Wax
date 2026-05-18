#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in \
  "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMEmbedderTests.swift" \
  "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMEmbeddingQualityTests.swift"
do
  if grep -Fq 'guard isMiniLMInferenceEnabled() else { return }' "$file"; then
    fail "$(basename "$file") silently returns when WAX_TEST_MINILM is unset"
  fi
done

if grep -Fq 'catch {' "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMResourceFailureTests.swift" \
  && grep -Fq '#expect(Bool(true))' "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMResourceFailureTests.swift"; then
  fail "MiniLM resource failure tests must assert the specific thrown error"
fi

grep -Fq '@Test(.disabled(' "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMEmbedderTests.swift" \
  && grep -Fq 'ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1"' "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMEmbedderTests.swift" \
  || fail "MiniLM embedder inference tests must use explicit disabled metadata"

grep -Fq '@Test(.disabled(' "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMEmbeddingQualityTests.swift" \
  && grep -Fq 'ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1"' "$ROOT_DIR/Tests/WaxIntegrationTests/MiniLMEmbeddingQualityTests.swift" \
  || fail "MiniLM quality inference tests must use explicit disabled metadata"

echo "minilm_test_gating_tests: ok"
