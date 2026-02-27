#!/usr/bin/env bash
set -euo pipefail

PLATFORM=""
TRIPLE=""

usage() {
  echo "Usage: $0 <platform> [<triple>|--triple <triple>]" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 64
fi

PLATFORM="$1"
shift

apply_usarch_float16_patch_for_x86() {
  local triple="$1"
  if [[ "$triple" != x86_64-* ]]; then
    return 0
  fi

  local source="$PROJECT_ROOT/.build/checkouts/USearch/swift/USearchIndex.swift"
  if [[ ! -f "$source" ]]; then
    return 0
  fi

  chmod u+w "$source" || true
  if [[ ! -w "$source" ]]; then
    return 0
  fi

  if rg -q "#if arch\\(arm64\\)" "$source"; then
    return 0
  fi

  python - "$source" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r") as fh:
    text = fh.read()

start_marker = "    /**\n     * @brief Adds a labeled vector to the index.\n     * @param vector Half-precision vector.\n     */"
end_marker = "    public func contains(key: USearchKey) throws -> Bool {\n"

if start_marker not in text or end_marker not in text:
    raise SystemExit(0)

start_index = text.index(start_marker)
end_index = text.index(end_marker)
block = text[start_index:end_index]

if "#if arch(arm64)" in block or "#endif" in block:
    raise SystemExit(0)

patched = "    #if arch(arm64)\n\n" + block + "    #endif\n\n"
text = text[:start_index] + patched + text[end_index:]

with open(path, "w") as fh:
    fh.write(text)
PY
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --triple)
      if [[ $# -lt 2 ]]; then
        usage
        exit 64
      fi
      TRIPLE="$2"
      shift 2
      ;;
    *)
      TRIPLE="$1"
      shift
      ;;
  esac
fi

if [[ $# -ne 0 ]]; then
  usage
  exit 64
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/npm/waxmcp/dist/$PLATFORM"
BIN_PATH="$DIST_DIR/WaxCLI"

mkdir -p "$DIST_DIR"

if [[ -n "$TRIPLE" ]]; then
  apply_usarch_float16_patch_for_x86 "$TRIPLE"
  swift build --product WaxCLI --traits MCPServer --configuration release --triple "$TRIPLE"
  LOCAL_BIN_PATH="$(swift build --product WaxCLI --traits MCPServer --configuration release --triple "$TRIPLE" --show-bin-path)"
  cp "$LOCAL_BIN_PATH/WaxCLI" "$BIN_PATH"
else
  if [[ ! -f "$BIN_PATH" ]]; then
    echo "ERROR: expected checked-in WaxCLI at $BIN_PATH but it does not exist." >&2
    echo "Rebuild with a matching triple or copy the binary first." >&2
    exit 1
  fi
fi

chmod +x "$BIN_PATH"

echo "Created $BIN_PATH"

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$BIN_PATH" > "$BIN_PATH.sha256"
else
  sha256sum "$BIN_PATH" > "$BIN_PATH.sha256"
fi

echo "Wrote $BIN_PATH.sha256"
