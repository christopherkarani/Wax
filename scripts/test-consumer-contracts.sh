#!/usr/bin/env bash
# test-consumer-contracts.sh — isolated downstream Wax consumer contract gate.
#
# Proves:
#   1. StrictConsumer compiles under Swift 6.2 strict concurrency (macOS + generic iOS)
#   2. ConsumerContractTests pass against currently-shipping public API
#   3. A traits-off fixture compiles Wax with default traits disabled and runs text-only
#   4. StrictConsumer two-process reopen: process A creates+saves+searches+closes;
#      process B reopens the same store path and searches again
#
# Task 2: StrictConsumer is required-green (Sendable configure closures).
# Override with WAX_CONSUMER_EXPECT_STRICT_RED=1 only to re-check the old red path.
set -euo pipefail

WAX_CONSUMER_EXPECT_STRICT_RED="${WAX_CONSUMER_EXPECT_STRICT_RED:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSUMER_ROOT="$REPO_ROOT/Tests/ConsumerContracts"

if [[ ! -f "$CONSUMER_ROOT/Package.swift" ]]; then
  echo "error: consumer package not found at $CONSUMER_ROOT" >&2
  exit 1
fi

REAL_HOME="${HOME}"
SWIFTPM_HOME_CACHE="$REAL_HOME/.swiftpm"
SWIFTPM_LIB_CACHE="$REAL_HOME/Library/Caches/org.swift.swiftpm"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/wax-consumer-contracts.XXXXXX")"
cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

mkdir -p \
  "$fixture_root/swiftpm-cache" \
  "$fixture_root/clang-cache" \
  "$fixture_root/DerivedData" \
  "$fixture_root/checkouts" \
  "$fixture_root/home/Library/Caches" \
  "$fixture_root/snapshots/before" \
  "$fixture_root/snapshots/after" \
  "$fixture_root/logs"

# xcodebuild needs the real Xcode support files (simulators, toolchains, licenses)
# but must not write SwiftPM caches into the developer's home. Isolate HOME and
# symlink only Library/Developer from the real home.
if [[ -d "$REAL_HOME/Library/Developer" ]]; then
  ln -s "$REAL_HOME/Library/Developer" "$fixture_root/home/Library/Developer"
fi
if [[ -d "$REAL_HOME/Library/Preferences" ]]; then
  mkdir -p "$fixture_root/home/Library"
  ln -s "$REAL_HOME/Library/Preferences" "$fixture_root/home/Library/Preferences"
fi

export CLANG_MODULE_CACHE_PATH="$fixture_root/clang-cache"
export MODULE_CACHE_DIR="$fixture_root/clang-cache"
# Honor --cache-path for swift; also export so xcodebuild's SwiftPM integration
# does not fall back to ~/Library/Caches/org.swift.swiftpm.
CACHE_PATH="$fixture_root/swiftpm-cache"
export SWIFTPM_CACHE_PATH="$CACHE_PATH"
SWIFT_COMMON=(
  --cache-path "$CACHE_PATH"
  --disable-sandbox
)
SWIFT_WERROR=(
  -Xswiftc -warnings-as-errors
)

snapshot_real_caches() {
  local dest="$1"
  mkdir -p "$dest"
  {
    echo "# HOME=$REAL_HOME"
    echo "# snapshot_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -d "$SWIFTPM_HOME_CACHE" ]]; then
      find "$SWIFTPM_HOME_CACHE" -print 2>/dev/null | sort
    else
      echo "# missing $SWIFTPM_HOME_CACHE"
    fi
  } > "$dest/dot-swiftpm.list"
  {
    if [[ -d "$SWIFTPM_LIB_CACHE" ]]; then
      find "$SWIFTPM_LIB_CACHE" -print 2>/dev/null | sort
    else
      echo "# missing $SWIFTPM_LIB_CACHE"
    fi
  } > "$dest/org.swift.swiftpm.list"
  # mtime+size fingerprint so we can detect writes even if the file set is unchanged
  {
    if [[ -d "$SWIFTPM_HOME_CACHE" ]]; then
      find "$SWIFTPM_HOME_CACHE" -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | sort
    fi
  } > "$dest/dot-swiftpm.stat"
  {
    if [[ -d "$SWIFTPM_LIB_CACHE" ]]; then
      find "$SWIFTPM_LIB_CACHE" -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | sort
    fi
  } > "$dest/org.swift.swiftpm.stat"
}

is_strict_concurrency_red() {
  local log="$1"
  grep -Eiq \
    'sending value of non-Sendable type|risks causing data races|Sendable|nonisolated' \
    "$log" \
    && grep -Eq 'Memory\.(init|search)|Memory\.Config|configure' "$log"
}

stage() {
  echo
  echo "=== STAGE: $* ==="
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_strict_step() {
  local name="$1"
  local log="$2"
  shift 2
  local status=0
  set +e
  "$@" >"$log" 2>&1
  status=$?
  set -e

  if [[ "$WAX_CONSUMER_EXPECT_STRICT_RED" == "1" ]]; then
    if [[ $status -eq 0 ]]; then
      fail "$name compiled green while WAX_CONSUMER_EXPECT_STRICT_RED=1 (harness must stay red until Task 2)"
    fi
    if ! is_strict_concurrency_red "$log"; then
      echo "---- $name log (unexpected failure) ----" >&2
      cat "$log" >&2
      fail "$name failed, but not with a strict-concurrency diagnostic about Memory configure closures"
    fi
    echo "EXPECTED-RED: $name (strict-concurrency configure-closure diagnostic)"
    grep -E 'error:|Sendable|data races|Memory' "$log" | head -n 20 || true
  else
    if [[ $status -ne 0 ]]; then
      echo "---- $name log ----" >&2
      cat "$log" >&2
      fail "$name is required-green (WAX_CONSUMER_EXPECT_STRICT_RED=0) but failed"
    fi
    echo "GREEN: $name"
  fi
}

# Swift commands use an isolated HOME so SwiftPM cannot fall back to ~/.swiftpm.
# xcodebuild uses the same isolated HOME, with Library/Developer and
# Library/Preferences symlinked from the real home for licenses/simulators.
run_swift_isolated() {
  HOME="$fixture_root/home" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  MODULE_CACHE_DIR="$MODULE_CACHE_DIR" \
    "$@"
}

export HOME="$fixture_root/home"

echo "Wax consumer contract gate"
echo "  repo:        $REPO_ROOT"
echo "  consumer:    $CONSUMER_ROOT"
echo "  fixture:     $fixture_root"
echo "  expect_red:  $WAX_CONSUMER_EXPECT_STRICT_RED"
echo "  isolated HOME: $HOME (real home snapshotted at $REAL_HOME)"
swift --version

stage "snapshot real SwiftPM caches (before)"
snapshot_real_caches "$fixture_root/snapshots/before"

stage "resolve (isolated cache)"
run_swift_isolated swift package \
  --package-path "$CONSUMER_ROOT" \
  "${SWIFT_COMMON[@]}" \
  resolve

stage "strict-macos"
run_strict_step "StrictConsumer macOS" "$fixture_root/logs/strict-macos.log" \
  run_swift_isolated swift build \
    --package-path "$CONSUMER_ROOT" \
    --product StrictConsumer \
    "${SWIFT_COMMON[@]}" \
    "${SWIFT_WERROR[@]}"

host_can_cross_compile_float16_x86_64() {
  local probe="$fixture_root/x86_64-float16-probe"
  mkdir -p "$probe/Sources/F16Probe"
  printf '%s\n' 'let value = Float16(1.5)' '_ = value.bitPattern' \
    > "$probe/Sources/F16Probe/main.swift"
  cat > "$probe/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "F16Probe",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "F16Probe")]
)
EOF
  run_swift_isolated swift build \
    --package-path "$probe" \
    --arch x86_64 \
    --scratch-path "$fixture_root/x86_64-float16-build" \
    "${SWIFT_COMMON[@]}" \
    "${SWIFT_WERROR[@]}" \
    >"$fixture_root/logs/x86_64-float16-probe.log" 2>&1
}

stage "strict-macos-x86_64"
if host_can_cross_compile_float16_x86_64; then
  run_strict_step "StrictConsumer macOS x86_64" "$fixture_root/logs/strict-macos-x86_64.log" \
    run_swift_isolated swift build \
      --package-path "$CONSUMER_ROOT" \
      --product StrictConsumer \
      --arch x86_64 \
      "${SWIFT_COMMON[@]}" \
      "${SWIFT_WERROR[@]}"
else
  echo "SKIP: StrictConsumer macOS x86_64 — this toolchain cannot compile Swift.Float16 under --arch x86_64 (required by MetalANNS/Wax). warnings-as-errors still applies to host macOS and iOS Simulator consumer builds."
  echo "  probe log: $fixture_root/logs/x86_64-float16-probe.log"
fi
stage "xcodebuild-list"
xcodebuild_list_log="$fixture_root/logs/xcodebuild-list.log"
# -list rejects -derivedDataPath unless -scheme is also set.
(
  cd "$CONSUMER_ROOT"
  xcodebuild -list \
    -clonedSourcePackagesDirPath "$fixture_root/checkouts"
) >"$xcodebuild_list_log" 2>&1 || true
if ! grep -q 'StrictConsumer' "$xcodebuild_list_log"; then
  echo "---- xcodebuild -list ----" >&2
  cat "$xcodebuild_list_log" >&2
  fail "xcodebuild -list did not see scheme StrictConsumer"
fi
echo "xcodebuild -list sees scheme StrictConsumer"

stage "strict-ios"
run_strict_step "StrictConsumer iOS Simulator" "$fixture_root/logs/strict-ios.log" \
  bash -c "
    cd \"$CONSUMER_ROOT\"
    xcodebuild \
      -scheme StrictConsumer \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath \"$fixture_root/DerivedData\" \
      -clonedSourcePackagesDirPath \"$fixture_root/checkouts\" \
      CODE_SIGNING_ALLOWED=NO \
      OTHER_SWIFT_FLAGS='\$(inherited) -parse-as-library' \
      build
  "

stage "strict-macos-two-process-reopen"
if [[ "$WAX_CONSUMER_EXPECT_STRICT_RED" == "1" ]]; then
  echo "SKIP: two-process reopen (StrictConsumer expected-red)"
else
  bin_path="$(
    run_swift_isolated swift build \
      --package-path "$CONSUMER_ROOT" \
      --product StrictConsumer \
      --show-bin-path \
      "${SWIFT_COMMON[@]}"
  )"
  bin_path="$(printf '%s\n' "$bin_path" | tail -n 1)"
  strict_exe="$bin_path/StrictConsumer"
  if [[ ! -x "$strict_exe" ]]; then
    fail "StrictConsumer executable not found at $strict_exe"
  fi
  process_a_log="$fixture_root/logs/strict-process-a.log"
  process_b_log="$fixture_root/logs/strict-process-b.log"
  if ! run_swift_isolated "$strict_exe" >"$process_a_log" 2>&1; then
    echo "---- StrictConsumer process A ----" >&2
    cat "$process_a_log" >&2
    fail "StrictConsumer process A (create+save+search+close) failed"
  fi
  store_path="$(grep '^WAX_STRICT_STORE=' "$process_a_log" | tail -n 1 | cut -d= -f2-)"
  if [[ -z "$store_path" ]]; then
    echo "---- StrictConsumer process A ----" >&2
    cat "$process_a_log" >&2
    fail "process A did not print WAX_STRICT_STORE=<path>"
  fi
  if ! run_swift_isolated "$strict_exe" "$store_path" >"$process_b_log" 2>&1; then
    echo "---- StrictConsumer process B ----" >&2
    cat "$process_b_log" >&2
    fail "StrictConsumer process B (reopen+search+close) failed"
  fi
  echo "GREEN: StrictConsumer two-process reopen"
  echo "  store: $store_path"
  echo "  process A: $process_a_log"
  echo "  process B: $process_b_log"
fi

stage "consumer-tests (required green)"
# StrictConsumer is part of the same package graph and must typecheck with tests.
test_log="$fixture_root/logs/consumer-tests.log"
if ! run_swift_isolated swift test \
  --package-path "$CONSUMER_ROOT" \
  --scratch-path "$fixture_root/test-build" \
  --disable-build-manifest-caching \
  "${SWIFT_COMMON[@]}" \
  "${SWIFT_WERROR[@]}" \
  >"$test_log" 2>&1; then
  echo "---- consumer-tests log ----" >&2
  cat "$test_log" >&2
  fail "ConsumerContractTests must pass"
fi
echo "GREEN: ConsumerContractTests"
tail -n 20 "$test_log"

stage "traits-off fixture (required green)"
traits_root="$fixture_root/traits-off"
mkdir -p "$traits_root/Sources/TraitsOffConsumer"
cp "$CONSUMER_ROOT/Sources/TraitsOffConsumer/main.swift" \
  "$traits_root/Sources/TraitsOffConsumer/main.swift"

# Generated second manifest: path dependency with default traits disabled.
python3 - "$traits_root/Package.swift" "$REPO_ROOT" <<'PY'
import pathlib, sys
dest = pathlib.Path(sys.argv[1])
wax_root = pathlib.Path(sys.argv[2]).resolve()
# Path-package identity is the last path component; `name:` pins it to Wax so
# `.product(..., package: "Wax")` works in worktrees whose folder is not "Wax".
# `traits: []` disables default traits (MiniLMEmbeddings). Combined form:
# `.package(name:path:traits:)` — if SwiftPM rejects it, the script records the
# fallback spelling.
dest.write_text(
    f"""// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WaxTraitsOffConsumer",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [.package(name: "Wax", path: "{wax_root}", traits: [])],
    targets: [
        .executableTarget(
            name: "TraitsOffConsumer",
            dependencies: [.product(name: "Wax", package: "Wax")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
""",
    encoding="utf-8",
)
PY

traits_build_log="$fixture_root/logs/traits-off-build.log"
if ! run_swift_isolated swift build \
  --package-path "$traits_root" \
  --product TraitsOffConsumer \
  --scratch-path "$fixture_root/traits-off-build" \
  "${SWIFT_COMMON[@]}" \
  "${SWIFT_WERROR[@]}" \
  >"$traits_build_log" 2>&1; then
  echo "---- traits-off build log ----" >&2
  cat "$traits_build_log" >&2
  fail "traits-off fixture failed to build (check traits: [] spelling if SwiftPM rejected the manifest)"
fi
echo "GREEN: traits-off build"

traits_run_log="$fixture_root/logs/traits-off-run.log"
if ! run_swift_isolated swift run \
  --package-path "$traits_root" \
  --scratch-path "$fixture_root/traits-off-build" \
  "${SWIFT_COMMON[@]}" \
  "${SWIFT_WERROR[@]}" \
  TraitsOffConsumer \
  >"$traits_run_log" 2>&1; then
  echo "---- traits-off run log ----" >&2
  cat "$traits_run_log" >&2
  fail "traits-off fixture built but runtime assertions failed"
fi
echo "GREEN: traits-off run"

stage "cache-isolation proof"
snapshot_real_caches "$fixture_root/snapshots/after"

# Prove the isolated caches were actually used.
isolated_ok=1
if [[ ! -d "$CACHE_PATH" ]] || [[ -z "$(find "$CACHE_PATH" -type f 2>/dev/null | head -n 1)" ]]; then
  echo "warning: isolated --cache-path $CACHE_PATH has no files" >&2
  isolated_ok=0
fi
if [[ ! -d "$CLANG_MODULE_CACHE_PATH" ]]; then
  echo "warning: isolated clang cache missing: $CLANG_MODULE_CACHE_PATH" >&2
  isolated_ok=0
fi
echo "isolated swiftpm-cache files: $(find "$CACHE_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "isolated clang-cache files:   $(find "$CLANG_MODULE_CACHE_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "isolated HOME .swiftpm files: $(find "$fixture_root/home/.swiftpm" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "isolated HOME org.swift.swiftpm files: $(find "$fixture_root/home/Library/Caches/org.swift.swiftpm" -type f 2>/dev/null | wc -l | tr -d ' ')"

# ~/.swiftpm must be unchanged (HOME was redirected).
cache_diff_log="$fixture_root/logs/cache-isolation.diff"
status=0
diff -u \
  "$fixture_root/snapshots/before/dot-swiftpm.stat" \
  "$fixture_root/snapshots/after/dot-swiftpm.stat" \
  >"$cache_diff_log" || status=$?
if [[ $status -ne 0 ]]; then
  echo "---- ~/.swiftpm diff ----" >&2
  cat "$cache_diff_log" >&2
  fail "real ~/.swiftpm changed during the run"
fi
echo "GREEN: no writes to ~/.swiftpm"

# org.swift.swiftpm is a machine-global cache. Xcode uses the login-user home
# (getpwuid) rather than $HOME, so FETCH_HEAD/HEAD/manifest .dia mtimes can
# change even with HOME redirected. Fail only when consumer-relevant paths or
# sizes change (new files or content growth), not timestamp-only bumps.
filter_consumer_relevant_identity() {
  awk '{
    mtime=$1; size=$2;
    path=$0; sub(/^[^ ]+ [^ ]+ /, "", path);
    print size, path
  }' "$1" | grep -Ei 'GRDB\.swift|MetalANNS|swift-crypto|swift-asn1|consumercontracts|codex-ios-remediation|WaxConsumer' | sort || true
}
filter_consumer_relevant_identity "$fixture_root/snapshots/before/org.swift.swiftpm.stat" \
  > "$fixture_root/snapshots/before/org.swift.swiftpm.consumer.stat"
filter_consumer_relevant_identity "$fixture_root/snapshots/after/org.swift.swiftpm.stat" \
  > "$fixture_root/snapshots/after/org.swift.swiftpm.consumer.stat"

consumer_status=0
diff -u \
  "$fixture_root/snapshots/before/org.swift.swiftpm.consumer.stat" \
  "$fixture_root/snapshots/after/org.swift.swiftpm.consumer.stat" \
  > "$fixture_root/logs/cache-isolation-consumer.diff" || consumer_status=$?
if [[ $consumer_status -ne 0 ]]; then
  echo "---- consumer-relevant org.swift.swiftpm diff ----" >&2
  cat "$fixture_root/logs/cache-isolation-consumer.diff" >&2
  fail "consumer-relevant writes landed in ~/Library/Caches/org.swift.swiftpm"
fi
echo "GREEN: no consumer-relevant path/size writes to ~/Library/Caches/org.swift.swiftpm"
echo "  (Xcode may bump FETCH_HEAD/manifest mtimes via login-user home; ignored if size+path match)"
if [[ "$isolated_ok" -ne 1 ]]; then
  fail "isolated caches were not populated"
fi
echo "  isolated swiftpm-cache: $CACHE_PATH"
echo "  isolated clang-cache:   $CLANG_MODULE_CACHE_PATH"
echo "  isolated HOME:          $fixture_root/home (Library/Developer + Preferences symlinked)"

echo
echo "Consumer contract gate complete."
if [[ "$WAX_CONSUMER_EXPECT_STRICT_RED" == "1" ]]; then
  echo "StrictConsumer: EXPECTED-RED | tests: GREEN | traits-off: GREEN | caches: isolated"
else
  echo "StrictConsumer: GREEN | tests: GREEN | traits-off: GREEN | caches: isolated"
fi

if [[ -n "${WAX_CONSUMER_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$WAX_CONSUMER_EVIDENCE_DIR/script-logs" "$WAX_CONSUMER_EVIDENCE_DIR/cache-snapshots"
  cp -R "$fixture_root/logs/." "$WAX_CONSUMER_EVIDENCE_DIR/script-logs/"
  cp -R "$fixture_root/snapshots/." "$WAX_CONSUMER_EVIDENCE_DIR/cache-snapshots/"
  echo "Archived fixture logs to $WAX_CONSUMER_EVIDENCE_DIR"
fi
