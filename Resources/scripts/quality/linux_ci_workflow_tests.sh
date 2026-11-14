#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/waxcore-linux.yml"
QUALITY_DIR="$ROOT_DIR/Resources/scripts/quality"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Lines of one job: from its "  <job>:" key up to the next top-level job key.
job_block() {
  awk -v job="  $1:" '
    $0 == job { inside = 1; print; next }
    inside && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    inside { print }
  ' "$WORKFLOW"
}

BUILD_JOB="$(job_block linux-build)"
TESTS_JOB="$(job_block linux-tests)"
[ -n "$BUILD_JOB" ] || fail "Linux CI must define the linux-build job"
[ -n "$TESTS_JOB" ] || fail "Linux CI must define the linux-tests job"

# Every third-party action is pinned to a full commit SHA.
while IFS= read -r line; do
  [[ "$line" =~ uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}([[:space:]]|$) ]] \
    || fail "action must be pinned to a full commit SHA: $line"
done < <(grep -E '^[[:space:]]+(-[[:space:]]+)?uses:' "$WORKFLOW")

for job in linux-build linux-tests; do
  block="$(job_block "$job")"
  grep -Eq 'timeout-minutes: [0-9]+' <<<"$block" \
    || fail "$job must set timeout-minutes"
  grep -Fq 'runner: ubuntu-24.04-arm' <<<"$block" \
    || fail "$job must run on the GitHub-hosted arm runner (ubuntu-24.04-arm)"
  grep -Eq 'arch: aarch64' <<<"$block" \
    || fail "$job must have an aarch64 matrix entry"
  grep -Eq 'arch: x86_64' <<<"$block" \
    || fail "$job must have an x86_64 matrix entry"
  grep -Eq 'swift-actions/setup-swift@[0-9a-f]{40} # v2' <<<"$block" \
    || fail "$job must install the requested Swift toolchain"
  grep -Fq 'Resources/scripts/quality/install_swift_linux_aarch64.sh' <<<"$block" \
    || fail "$job must install a Swift toolchain on aarch64 (setup-swift v2 is x86_64-only)"
  grep -Fq 'Resources/scripts/quality/package_resolved_linux_check.sh' <<<"$block" \
    || fail "$job must check that Linux resolution kept the committed Package.resolved pins"
done

[ -x "$QUALITY_DIR/install_swift_linux_aarch64.sh" ] \
  || fail "install_swift_linux_aarch64.sh must exist and be executable"
grep -Fq 'gpg --batch --verify' "$QUALITY_DIR/install_swift_linux_aarch64.sh" \
  || fail "the aarch64 toolchain install must verify the swift.org signature"
[ -x "$QUALITY_DIR/package_resolved_linux_check.sh" ] \
  || fail "package_resolved_linux_check.sh must exist and be executable"

# Package.resolved written on Linux drops macOS-only pins; CI must never commit it.
if grep -v '^[[:space:]]*#' "$WORKFLOW" | grep -Eq 'git (add|commit|push)'; then
  fail "Linux CI must not commit or push (a Linux-written Package.resolved drops macOS pins)"
fi
grep -Fq 'Never commit a Package.resolved written on Linux.' "$WORKFLOW" \
  || fail "Linux CI must document why its Package.resolved rewrite is left uncommitted"

grep -Eq 'swift build --product Wax([[:space:]]|$)' <<<"$BUILD_JOB" \
  || fail "Linux CI must build the public Wax product"

grep -Fq 'swift build --product wax-cli --traits default,MCPServer' <<<"$BUILD_JOB" \
  || fail "Linux CI must build wax-cli with MCPServer traits"

grep -Fq 'swift build --product wax-mcp --traits default,MCPServer' <<<"$BUILD_JOB" \
  || fail "Linux CI must build wax-mcp with MCPServer traits"

grep -Fq 'swift build -c release --product wax-cli --traits default,MCPServer' <<<"$BUILD_JOB" \
  || fail "Linux CI must build release wax-cli with MCPServer traits"

grep -Fq 'swift build -c release --product wax-mcp --traits default,MCPServer' <<<"$BUILD_JOB" \
  || fail "Linux CI must build release wax-mcp with MCPServer traits"

grep -Fq 'Resources/scripts/quality/daemon_sigterm_smoke.sh "$BIN_DIR/wax-cli" "$BIN_DIR/wax-mcp"' <<<"$BUILD_JOB" \
  || fail "Linux CI must smoke-test SIGTERM shutdown of wax-cli and wax-mcp"

[ -x "$QUALITY_DIR/daemon_sigterm_smoke.sh" ] \
  || fail "daemon_sigterm_smoke.sh must exist and be executable"

# The suites run through the production gate, not a hand-copied list of
# swift test commands, so Linux and macOS share the skip regex and checks.
grep -Fq 'Resources/scripts/quality/production_readiness_gates_tests.sh' <<<"$TESTS_JOB" \
  || fail "Linux CI must run the production gate script self-tests"

grep -Fq 'Resources/scripts/quality/production_readiness_gates.sh full' <<<"$TESTS_JOB" \
  || fail "Linux CI must run the production gate's full mode (default suite + MCPServer slices)"

grep -Fq 'Resources/scripts/quality/production_readiness_gates.sh embedder-inference' <<<"$TESTS_JOB" \
  || fail "Linux CI must run the env-gated embedder inference suites"

grep -Fq 'embedder-inference)' "$QUALITY_DIR/production_readiness_gates.sh" \
  || fail "production_readiness_gates.sh must expose the embedder-inference mode"

if grep -v '^[[:space:]]*#' "$WORKFLOW" | grep -Eq 'swift test --filter WaxCoreTests([[:space:]]|$)'; then
  fail "Linux CI must run the whole suite through the gate, not only WaxCoreTests"
fi

# Comments may name the define; commands must not use it.
if grep -v '^[[:space:]]*#' "$WORKFLOW" | grep -q -- '-DGRDBCUSTOMSQLITE'; then
  fail "Linux CI must not pass -DGRDBCUSTOMSQLITE; GRDB 7 SPM imports GRDBSQLite, and that define selects an empty custom-SQLite import"
fi

echo "linux_ci_workflow_tests: ok"
