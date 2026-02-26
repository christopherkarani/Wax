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
