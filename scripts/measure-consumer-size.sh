#!/usr/bin/env bash
# measure-consumer-size.sh — build default, traits-off, and Arctic Wax consumers
# and emit a machine-readable size report with checked thresholds.
#
# Thresholds (Task 13):
#   default MiniLM resource <= 46 MiB
#   Arctic resource         <= 35 MiB
#   traits-off contains neither built-in model bundle
#   ordinary consumer graph contains no swift-nio or MCP product
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MINILM_MAX=$((46 * 1024 * 1024))
ARCTIC_MAX=$((35 * 1024 * 1024))

REAL_HOME="${HOME}"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/wax-consumer-size.XXXXXX")"
cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

mkdir -p \
  "$fixture_root/swiftpm-cache" \
  "$fixture_root/clang-cache" \
  "$fixture_root/home/Library/Caches" \
  "$fixture_root/logs" \
  "$fixture_root/reports"

if [[ -d "$REAL_HOME/Library/Developer" ]]; then
  ln -s "$REAL_HOME/Library/Developer" "$fixture_root/home/Library/Developer"
fi
if [[ -d "$REAL_HOME/Library/Preferences" ]]; then
  ln -s "$REAL_HOME/Library/Preferences" "$fixture_root/home/Library/Preferences"
fi

export CLANG_MODULE_CACHE_PATH="$fixture_root/clang-cache"
export MODULE_CACHE_DIR="$fixture_root/clang-cache"
CACHE_PATH="$fixture_root/swiftpm-cache"
export SWIFTPM_CACHE_PATH="$CACHE_PATH"
export HOME="$fixture_root/home"

SWIFT_COMMON=(
  --cache-path "$CACHE_PATH"
  --disable-sandbox
)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_swift() {
  HOME="$fixture_root/home" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  MODULE_CACHE_DIR="$MODULE_CACHE_DIR" \
    "$@"
}

write_consumer_sources() {
  local dest="$1"
  mkdir -p "$dest/Sources/SizeConsumer"
  cat > "$dest/Sources/SizeConsumer/main.swift" <<'SWIFT'
import Foundation
import Wax

@main
struct SizeConsumer {
    static func main() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "wax-size-\(UUID().uuidString).wax")
        var config = Memory.Config.default
        config.enableVectorSearch = false
        let memory = try await Memory(at: storeURL, config: config)
        try await memory.save("Size measurement payload.")
        try await memory.close()
        print("WAX_SIZE_STORE=\(storeURL.path)")
    }
}
SWIFT
}

write_manifest() {
  local dest="$1"
  local traits_arg="$2"
  python3 - "$dest/Package.swift" "$REPO_ROOT" "$traits_arg" <<'PY'
import pathlib, sys
dest = pathlib.Path(sys.argv[1])
wax_root = pathlib.Path(sys.argv[2]).resolve()
traits = sys.argv[3]
if traits == "DEFAULT":
    dep = f'.package(name: "Wax", path: "{wax_root}")'
elif traits == "OFF":
    dep = f'.package(name: "Wax", path: "{wax_root}", traits: [])'
elif traits == "ARCTIC":
    dep = f'.package(name: "Wax", path: "{wax_root}", traits: ["ArcticEmbeddings"])'
else:
    raise SystemExit(f"unknown traits {traits}")
dest.write_text(
    f"""// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WaxSizeConsumer",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [{dep}],
    targets: [
        .executableTarget(
            name: "SizeConsumer",
            dependencies: [.product(name: "Wax", package: "Wax")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
""",
    encoding="utf-8",
)
PY
}

bytes_of() {
  local path="$1"
  if [[ -d "$path" ]]; then
    du -sk "$path" | awk '{ print $1 * 1024 }'
  elif [[ -f "$path" ]]; then
    stat -f '%z' "$path"
  else
    echo 0
  fi
}

logical_bytes() {
  stat -f '%z' "$1"
}

allocated_bytes() {
  # st_blocks is 512-byte units on Darwin.
  stat -f '%b' "$1" | awk '{ print $1 * 512 }'
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:-1] if False else sys.argv[1]))' "$1"
}

measure_consumer() {
  local name="$1"
  local traits_arg="$2"
  local root="$fixture_root/$name"
  mkdir -p "$root"
  write_consumer_sources "$root"
  write_manifest "$root" "$traits_arg"

  local log="$fixture_root/logs/$name-build.log"
  if ! run_swift swift build \
    --package-path "$root" \
    --product SizeConsumer \
    --scratch-path "$fixture_root/build-$name" \
    "${SWIFT_COMMON[@]}" \
    >"$log" 2>&1; then
    echo "---- $name build log ----" >&2
    cat "$log" >&2
    fail "$name consumer failed to build"
  fi

  local bin_path
  bin_path="$(
    run_swift swift build \
      --package-path "$root" \
      --product SizeConsumer \
      --scratch-path "$fixture_root/build-$name" \
      --show-bin-path \
      "${SWIFT_COMMON[@]}"
  )"
  bin_path="$(printf '%s\n' "$bin_path" | tail -n 1)"
  local exe="$bin_path/SizeConsumer"
  [[ -x "$exe" ]] || fail "$name executable missing at $exe"
  local exe_bytes
  exe_bytes="$(bytes_of "$exe")"

  local build_dir="$fixture_root/build-$name"
  local minilm_bytes=0
  local arctic_bytes=0
  local bundles_json="["
  local first_bundle=1
  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    local bbytes
    bbytes="$(bytes_of "$bundle")"
    local bname
    bname="$(basename "$bundle")"
    if [[ "$first_bundle" -eq 1 ]]; then
      first_bundle=0
    else
      bundles_json+=","
    fi
    bundles_json+="{\"name\":$(json_escape "$bname"),\"path\":$(json_escape "$bundle"),\"bytes\":$bbytes}"
    case "$bundle" in
      *all-MiniLM-L6-v2.mlmodelc*) minilm_bytes="$bbytes" ;;
      *snowflake-arctic-embed-s.mlmodelc*) arctic_bytes="$bbytes" ;;
    esac
  done < <(find "$build_dir" -type d -name '*.mlmodelc' 2>/dev/null | sort)

  bundles_json+="]"

  local run_log="$fixture_root/logs/$name-run.log"
  if ! run_swift "$exe" >"$run_log" 2>&1; then
    echo "---- $name run log ----" >&2
    cat "$run_log" >&2
    fail "$name consumer built but failed at runtime"
  fi
  local store_path
  store_path="$(grep '^WAX_SIZE_STORE=' "$run_log" | tail -n 1 | cut -d= -f2-)"
  [[ -n "$store_path" ]] || fail "$name did not print WAX_SIZE_STORE"
  local store_logical store_allocated
  store_logical="$(logical_bytes "$store_path")"
  store_allocated="$(allocated_bytes "$store_path")"

  local nio=0 mcp=0
  if find "$build_dir" \( \
      -name 'NIOCore.swiftmodule' -o \
      -name 'NIOPosix.swiftmodule' -o \
      -name 'NIOHTTP1.swiftmodule' -o \
      -name 'NIOEmbedded.swiftmodule' \
    \) 2>/dev/null | grep -q .; then
    nio=1
  fi
  if find "$build_dir" \( -name 'MCP.swiftmodule' -o -name 'MCP.swiftinterface' \) 2>/dev/null | grep -q .; then
    mcp=1
  fi

  local deps_json
  deps_json="$(
    python3 - "$build_dir" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
idents = []
for checkouts in root.rglob("checkouts"):
    if not checkouts.is_dir():
        continue
    for child in sorted(checkouts.iterdir()):
        if child.is_dir():
            idents.append(child.name)
# Also harvest from workspace-state if present
seen = []
for name in idents:
    if name not in seen:
        seen.append(name)
print(json.dumps(seen))
PY
  )"

  python3 - "$name" "$traits_arg" "$exe_bytes" "$minilm_bytes" "$arctic_bytes" \
    "$store_logical" "$store_allocated" "$nio" "$mcp" "$bundles_json" "$deps_json" \
    "$store_path" "$exe" <<'PY'
import json, sys
name, traits, exe, mini, arctic, logical, allocated, nio, mcp, bundles, deps, store, exe_path = sys.argv[1:]
report = {
    "name": name,
    "traits": traits,
    "executablePath": exe_path,
    "executableBytes": int(exe),
    "miniLMResourceBytes": int(mini),
    "arcticResourceBytes": int(arctic),
    "storePath": store,
    "storeLogicalBytes": int(logical),
    "storeAllocatedBytes": int(allocated),
    "containsSwiftNIO": nio == "1",
    "containsMCP": mcp == "1",
    "resourceBundles": json.loads(bundles),
    "dependencyIdentities": json.loads(deps),
}
print(json.dumps(report))
PY
}

echo "Wax consumer size gate"
echo "  repo:    $REPO_ROOT"
echo "  fixture: $fixture_root"

default_json="$(measure_consumer default DEFAULT)"
echo "GREEN: default consumer"
off_json="$(measure_consumer traitsOff OFF)"
echo "GREEN: traits-off consumer"
arctic_json="$(measure_consumer arctic ARCTIC)"
echo "GREEN: Arctic consumer"

python3 - "$default_json" "$off_json" "$arctic_json" "$MINILM_MAX" "$ARCTIC_MAX" <<'PY'
import json, sys
default = json.loads(sys.argv[1])
off = json.loads(sys.argv[2])
arctic = json.loads(sys.argv[3])
minilm_max = int(sys.argv[4])
arctic_max = int(sys.argv[5])
failures = []

if default["miniLMResourceBytes"] <= 0:
    failures.append("default consumer missing MiniLM resource bundle")
if default["miniLMResourceBytes"] > minilm_max:
    failures.append(
        f"default MiniLM resource {default['miniLMResourceBytes']} > {minilm_max}"
    )
if default["arcticResourceBytes"] != 0:
    failures.append("default consumer unexpectedly contains Arctic bundle")
if default["containsSwiftNIO"] or default["containsMCP"]:
    failures.append("default consumer graph contains swift-nio or MCP product")

if off["miniLMResourceBytes"] != 0 or off["arcticResourceBytes"] != 0:
    failures.append("traits-off consumer contains a built-in model bundle")
if off["containsSwiftNIO"] or off["containsMCP"]:
    failures.append("traits-off consumer graph contains swift-nio or MCP product")

if arctic["arcticResourceBytes"] <= 0:
    failures.append("Arctic consumer missing Arctic resource bundle")
if arctic["arcticResourceBytes"] > arctic_max:
    failures.append(
        f"Arctic resource {arctic['arcticResourceBytes']} > {arctic_max}"
    )
if arctic["containsSwiftNIO"] or arctic["containsMCP"]:
    failures.append("Arctic consumer graph contains swift-nio or MCP product")

report = {
    "generatedAt": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "thresholds": {
        "miniLMResourceBytesMax": minilm_max,
        "arcticResourceBytesMax": arctic_max,
    },
    "consumers": {
        "default": default,
        "traitsOff": off,
        "arctic": arctic,
    },
    "passed": not failures,
    "failures": failures,
}
print(json.dumps(report, indent=2))
if failures:
    raise SystemExit("size thresholds failed:\n  " + "\n  ".join(failures))
PY

echo "GREEN: consumer size thresholds"
