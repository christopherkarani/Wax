#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-website.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Eq '^  pull_request:' "$WORKFLOW" \
  || fail "website workflow must run on pull_request"

grep -Fq "      - 'Resources/website/**'" "$WORKFLOW" \
  || fail "website workflow pull_request must cover Resources/website changes"

grep -Fq "      - '.github/workflows/deploy-website.yml'" "$WORKFLOW" \
  || fail "website workflow pull_request must cover its workflow file"

grep -Eq '^    if: .*\$\{\{ github.event_name != '\''pull_request'\'' \}\}' "$WORKFLOW" \
  || fail "website deploy job must not publish from pull_request builds"

echo "website_workflow_tests: ok"
