#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/release-waxmcp.yml"
ROOT_RELEASE_SCRIPT="$ROOT_DIR/scripts/release-waxmcp.sh"
CANONICAL_RELEASE_SCRIPT="$ROOT_DIR/Resources/scripts/release-waxmcp.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if grep -Fq 'shasum -a 256 -c "$PLATFORM_DIR/wax-cli.sha256"' "$WORKFLOW"; then
  fail "build job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'sha256sum -c "$PLATFORM_DIR/wax-cli.sha256"' "$WORKFLOW"; then
  fail "build job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'shasum -a 256 -c "$chk"' "$WORKFLOW"; then
  fail "publish job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'sha256sum -c "$chk"' "$WORKFLOW"; then
  fail "publish job verifies basename-only checksum files from the repo root"
fi

if grep -Fq 'let serverVersion = "[0-9]' "$WORKFLOW"; then
  fail "release workflow extracts the stale serverVersion literal instead of WaxMCPServerMetadata.version"
fi

if grep -Fq 's/let serverVersion\s*=' "$ROOT_DIR/scripts/release-waxmcp.sh" "$ROOT_DIR/Resources/scripts/release-waxmcp.sh"; then
  fail "release scripts rewrite the stale serverVersion literal instead of WaxMCPServerMetadata.version"
fi

if grep -Fq 'perl -0pi' "$ROOT_RELEASE_SCRIPT"; then
  fail "root release script must delegate instead of duplicating release mutation logic"
fi

grep -Fq 'exec "$ROOT/Resources/scripts/release-waxmcp.sh" "$@"' "$ROOT_RELEASE_SCRIPT" \
  || fail "root release script must delegate to Resources/scripts/release-waxmcp.sh"

set_version_line="$(grep -n 'name: Set release version' "$WORKFLOW" | head -n 1 | cut -d: -f1 || true)"
build_line="$(grep -n 'name: Build binaries' "$WORKFLOW" | head -n 1 | cut -d: -f1 || true)"
[[ -n "$set_version_line" ]] || fail "release workflow must set the release version before building binaries"
[[ -n "$build_line" ]] || fail "release workflow must still build binaries"
(( set_version_line < build_line )) \
  || fail "release workflow sets package metadata after binaries are built"

grep -Fq './Resources/scripts/sync-waxmcp-version.sh' "$WORKFLOW" \
  || fail "release workflow must use the shared waxmcp version sync helper"

grep -Fq 'Resources/scripts/sync-waxmcp-version.sh' "$CANONICAL_RELEASE_SCRIPT" \
  || fail "canonical release script must use the shared waxmcp version sync helper"

grep -Fq 'darwin-arm64' "$CANONICAL_RELEASE_SCRIPT" \
  || fail "canonical release script must stage darwin-arm64 artifacts"

grep -Fq 'build-waxmcp-binaries.sh" "$platform" "$triple"' "$CANONICAL_RELEASE_SCRIPT" \
  || fail "canonical release script must use the shared multi-platform binary builder"

FINALIZE_SCRIPT="$ROOT_DIR/Resources/scripts/finalize-homebrew-formula.sh"
[[ -x "$FINALIZE_SCRIPT" ]] || fail "finalize-homebrew-formula.sh must exist and be executable"

grep -Fq 'finalize-homebrew-formula.sh' "$WORKFLOW" \
  || fail "release workflow must finalize Homebrew sha256 from the GitHub tag archive"

grep -Fq 'name: Finalize Homebrew formula' "$WORKFLOW" \
  || fail "release workflow must include a Homebrew finalize job"

grep -Fq 'HOMEBREW_TAP_TOKEN' "$WORKFLOW" \
  || fail "release workflow must document HOMEBREW_TAP_TOKEN for tap sync"

grep -Fq -e '--push-tap' "$FINALIZE_SCRIPT" \
  || fail "finalize-homebrew-formula.sh must support --push-tap for the external tap"

if grep -Fq 'git push origin HEAD:main' "$WORKFLOW"; then
  fail "release workflow must not push to main; open a pull request for the formula bump"
fi

grep -Fq 'gh pr create' "$WORKFLOW" \
  || fail "release workflow must open a pull request for the vendored Homebrew formula bump"

ruby -e '
require "yaml"
wf = YAML.load_file(ARGV[0])
jobs = wf.fetch("jobs")
needs = ->(name) { Array(jobs.fetch(name)["needs"]) }

gates = jobs["gates"] or abort "release workflow must have a gates job"
gate_runs = gates.fetch("steps").map { |step| step["run"].to_s }
unless gate_runs.any? { |run| run.include?("production_readiness_gates.sh full") }
  abort "release gates job must run production_readiness_gates.sh full"
end
%w[build publish homebrew].each do |job|
  abort "#{job} must depend on gates" unless needs.(job).include?("gates")
end

publish = jobs.fetch("publish")
unless publish.dig("permissions", "id-token") == "write"
  abort "publish job needs id-token: write for npm provenance"
end
publish_run = publish.fetch("steps").map { |step| step["run"].to_s }.find { |run| run.include?("npm publish") }
abort "publish job must npm publish --provenance" unless publish_run&.include?("--provenance")

if jobs.fetch("homebrew").dig("permissions", "pull-requests") != "write"
  abort "homebrew job needs pull-requests: write to open the formula PR"
end
' "$WORKFLOW" || fail "release workflow gate/provenance/PR contract violated"

# Every action reference is pinned to a full commit SHA (tags are mutable).
unpinned="$(grep -hE '^[[:space:]]*-?[[:space:]]*uses:' "$ROOT_DIR"/.github/workflows/*.yml \
  | grep -vE 'uses:[[:space:]]*(\./|[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$))' || true)"
[[ -z "$unpinned" ]] || fail "workflow actions must be pinned to commit SHAs: $unpinned"

if grep -Fq 'latest-stable' "$WORKFLOW" "$ROOT_DIR/.github/workflows/quality-gates.yml"; then
  fail "release and gate workflows must pin a concrete Xcode version, not latest-stable"
fi

echo "release_workflow_tests: ok"
