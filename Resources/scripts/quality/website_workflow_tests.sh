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

# Pull requests only check that the site builds. Pages setup needs Pages enabled on the
# repository and its artifact is used only by deploy, so neither may run for a pull request.
for step in "Setup Pages" "Upload artifact"; do
  awk -v step="      - name: $step" '
    $0 == step { found = 1; next }
    found && /^      - name:/ { exit }
    found && /^        if: \$\{\{ github.event_name != '\''pull_request'\'' \}\}$/ { ok = 1; exit }
    END { exit ok ? 0 : 1 }
  ' "$WORKFLOW" || fail "website workflow step '$step' must be skipped on pull_request"
done

echo "website_workflow_tests: ok"
