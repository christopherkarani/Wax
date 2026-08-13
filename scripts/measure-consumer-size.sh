#!/usr/bin/env bash
# measure-consumer-size.sh — build default, traits-off, and Arctic Wax consumers
# and emit a machine-readable size report with checked thresholds.
#
# Thresholds (Task 13 + D-P2-1/D-P2-2):
#   default MiniLM resource <= 46 MiB, Arctic absent
#   Arctic resource         <= 35 MiB AND MiniLM bytes == 0
#   traits-off contains neither built-in model bundle
#   ordinary consumer graph contains no swift-nio or MCP product
#   all consumers inventory tiktoken / BERT vocab / Wax Metal shaders /
#   PrivacyInfo with explicit expected-presence per configuration
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
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    local mbytes
    mbytes="$(bytes_of "$model")"
    case "$model" in
      *all-MiniLM-L6-v2.mlmodelc) minilm_bytes="$mbytes" ;;
      *snowflake-arctic-embed-s.mlmodelc) arctic_bytes="$mbytes" ;;
    esac
  done < <(find "$build_dir" -type d -name '*.mlmodelc' 2>/dev/null | sort)

  local inventory_json bundles_json
  inventory_json="$(
    python3 - "$bin_path" <<'PY'
import json, os, pathlib, subprocess, sys

root = pathlib.Path(sys.argv[1])

def du_bytes(path: pathlib.Path) -> int:
    if not path.exists():
        return 0
    out = subprocess.check_output(["du", "-sk", str(path)], text=True)
    return int(out.split()[0]) * 1024

def file_bytes(path: pathlib.Path) -> int:
    if path.is_dir():
        return du_bytes(path)
    if path.is_file():
        return path.stat().st_size
    return 0

bundles = sorted(p for p in root.glob("*.bundle") if p.is_dir())
bundle_entries = []
has_minilm = False
has_arctic = False
has_tiktoken = False
has_vocab = False
has_cosine = False
has_topk = False
tiktoken_bytes = 0
vocab_bytes = 0
shader_bytes = 0
privacy_bundles = []

WAX_SHADER_BUNDLE = "Wax_WaxVectorSearch.bundle"
WAX_SHADERS = {"CosineDistance.metal", "TopKReduction.metal"}

for bundle in bundles:
    bundle_entries.append({
        "name": bundle.name,
        "path": str(bundle),
        "bytes": du_bytes(bundle),
    })
    for dirpath, dirnames, filenames in os.walk(bundle):
        current = pathlib.Path(dirpath)
        for dirname in dirnames:
            if dirname == "all-MiniLM-L6-v2.mlmodelc":
                has_minilm = True
            elif dirname == "snowflake-arctic-embed-s.mlmodelc":
                has_arctic = True
        for filename in filenames:
            path = current / filename
            if filename == "cl100k_base.tiktoken":
                has_tiktoken = True
                tiktoken_bytes = file_bytes(path)
            elif filename == "bert_tokenizer_vocab.txt":
                has_vocab = True
                vocab_bytes = file_bytes(path)
            elif filename == "PrivacyInfo.xcprivacy":
                if bundle.name not in privacy_bundles:
                    privacy_bundles.append(bundle.name)
            elif filename in WAX_SHADERS and bundle.name == WAX_SHADER_BUNDLE:
                shader_bytes += file_bytes(path)
                if filename == "CosineDistance.metal":
                    has_cosine = True
                elif filename == "TopKReduction.metal":
                    has_topk = True

inventory = {
    "hasMiniLMModel": has_minilm,
    "hasArcticModel": has_arctic,
    "hasTiktoken": has_tiktoken,
    "tiktokenBytes": tiktoken_bytes,
    "hasBertVocab": has_vocab,
    "bertVocabBytes": vocab_bytes,
    "hasCosineDistanceShader": has_cosine,
    "hasTopKReductionShader": has_topk,
    "hasWaxShaders": has_cosine and has_topk,
    "waxShaderBytes": shader_bytes,
    "hasPrivacyInfo": bool(privacy_bundles),
    "privacyInfoBundles": privacy_bundles,
}
print(json.dumps({"inventory": inventory, "resourceBundles": bundle_entries}))
PY
  )"
  bundles_json="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["resourceBundles"]))' "$inventory_json")"
  inventory_json="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["inventory"]))' "$inventory_json")"

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
    "$store_path" "$exe" "$inventory_json" <<'PY'
import json, sys
name, traits, exe, mini, arctic, logical, allocated, nio, mcp, bundles, deps, store, exe_path, inventory = sys.argv[1:]
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
    "resourceInventory": json.loads(inventory),
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

def inv(consumer):
    return consumer["resourceInventory"]

def require_shared_runtime_resources(consumer, label):
    inventory = inv(consumer)
    if not inventory["hasTiktoken"]:
        failures.append(f"{label} consumer missing cl100k_base.tiktoken")
    if not inventory["hasWaxShaders"]:
        missing = []
        if not inventory["hasCosineDistanceShader"]:
            missing.append("CosineDistance.metal")
        if not inventory["hasTopKReductionShader"]:
            missing.append("TopKReduction.metal")
        failures.append(
            f"{label} consumer missing Wax Metal shaders ({', '.join(missing) or 'unknown'})"
        )
    if not inventory["hasPrivacyInfo"]:
        failures.append(f"{label} consumer missing PrivacyInfo.xcprivacy")
    if consumer["containsSwiftNIO"] or consumer["containsMCP"]:
        failures.append(f"{label} consumer graph contains swift-nio or MCP product")

if default["miniLMResourceBytes"] <= 0 or not inv(default)["hasMiniLMModel"]:
    failures.append("default consumer missing MiniLM resource bundle")
if default["miniLMResourceBytes"] > minilm_max:
    failures.append(
        f"default MiniLM resource {default['miniLMResourceBytes']} > {minilm_max}"
    )
if default["arcticResourceBytes"] != 0 or inv(default)["hasArcticModel"]:
    failures.append("default consumer unexpectedly contains Arctic bundle")
if not inv(default)["hasBertVocab"]:
    failures.append("default consumer missing bert_tokenizer_vocab.txt")
require_shared_runtime_resources(default, "default")

if off["miniLMResourceBytes"] != 0 or off["arcticResourceBytes"] != 0:
    failures.append("traits-off consumer contains a built-in model bundle")
if inv(off)["hasMiniLMModel"] or inv(off)["hasArcticModel"]:
    failures.append("traits-off consumer inventory lists a built-in model bundle")
if inv(off)["hasBertVocab"]:
    failures.append("traits-off consumer unexpectedly contains bert_tokenizer_vocab.txt")
require_shared_runtime_resources(off, "traits-off")

if arctic["arcticResourceBytes"] <= 0 or not inv(arctic)["hasArcticModel"]:
    failures.append("Arctic consumer missing Arctic resource bundle")
if arctic["arcticResourceBytes"] > arctic_max:
    failures.append(
        f"Arctic resource {arctic['arcticResourceBytes']} > {arctic_max}"
    )
if arctic["miniLMResourceBytes"] != 0 or inv(arctic)["hasMiniLMModel"]:
    failures.append("Arctic consumer unexpectedly contains MiniLM bundle")
if not inv(arctic)["hasBertVocab"]:
    failures.append("Arctic consumer missing bert_tokenizer_vocab.txt")
require_shared_runtime_resources(arctic, "Arctic")

report = {
    "generatedAt": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "thresholds": {
        "miniLMResourceBytesMax": minilm_max,
        "arcticResourceBytesMax": arctic_max,
        "arcticMustExcludeMiniLM": True,
        "expectedPresence": {
            "default": {
                "miniLM": True,
                "arctic": False,
                "tiktoken": True,
                "bertVocab": True,
                "waxShaders": True,
                "privacyInfo": True,
            },
            "traitsOff": {
                "miniLM": False,
                "arctic": False,
                "tiktoken": True,
                "bertVocab": False,
                "waxShaders": True,
                "privacyInfo": True,
            },
            "arctic": {
                "miniLM": False,
                "arctic": True,
                "tiktoken": True,
                "bertVocab": True,
                "waxShaders": True,
                "privacyInfo": True,
            },
        },
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
