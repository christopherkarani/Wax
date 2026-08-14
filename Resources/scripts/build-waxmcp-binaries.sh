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

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$PROJECT_ROOT/Resources/npm/waxmcp/dist/$PLATFORM"
CLI_BIN_PATH="$DIST_DIR/wax-cli"
MCP_BIN_PATH="$DIST_DIR/wax-mcp"

mkdir -p "$DIST_DIR"

if [[ -n "$TRIPLE" ]]; then
  # Build the CLI binary (with both MiniLM and Arctic embedders)
  swift build --product wax-cli --traits "MiniLMEmbeddings,ArcticEmbeddings" --configuration release --triple "$TRIPLE"
  LOCAL_BIN_PATH="$(swift build --product wax-cli --traits "MiniLMEmbeddings,ArcticEmbeddings" --configuration release --triple "$TRIPLE" --show-bin-path)"
  cp "$LOCAL_BIN_PATH/wax-cli" "$CLI_BIN_PATH"

  # Build the MCP server binary (with both MiniLM and Arctic embedders)
  swift build --product wax-mcp --traits "MiniLMEmbeddings,ArcticEmbeddings,MCPServer" --configuration release --triple "$TRIPLE"
  MCP_LOCAL_BIN_PATH="$(swift build --product wax-mcp --traits "MiniLMEmbeddings,ArcticEmbeddings,MCPServer" --configuration release --triple "$TRIPLE" --show-bin-path)"
  cp "$MCP_LOCAL_BIN_PATH/wax-mcp" "$MCP_BIN_PATH"

  # Copy resource bundles required for vector search and runtime.
  # Scan both bin paths defensively (they're usually identical but may diverge).
  echo "Copying resource bundles..."
  for dir in "$LOCAL_BIN_PATH" "$MCP_LOCAL_BIN_PATH"; do
    for bundle in "$dir"/*.bundle; do
      [[ -d "$bundle" ]] || continue
      bundle_name="$(basename "$bundle")"
      [[ -d "$DIST_DIR/$bundle_name" ]] && continue  # skip if already copied
      cp -r "$bundle" "$DIST_DIR/$bundle_name"
      echo "  Copied $bundle_name"
    done
  done
else
  if [[ ! -f "$CLI_BIN_PATH" ]]; then
    echo "ERROR: expected checked-in wax-cli binary at $CLI_BIN_PATH but it does not exist." >&2
    echo "Rebuild with a matching triple or copy the binary first." >&2
    exit 1
  fi
  if [[ ! -f "$MCP_BIN_PATH" ]]; then
    echo "WARN: wax-mcp binary not found at $MCP_BIN_PATH. MCP server will not be shipped for this platform." >&2
  fi
fi

chmod +x "$CLI_BIN_PATH"
echo "Created $CLI_BIN_PATH"

if [[ -f "$MCP_BIN_PATH" ]]; then
  chmod +x "$MCP_BIN_PATH"
  echo "Created $MCP_BIN_PATH"
fi

# Reject mislabeled artifacts before checksums make them look trustworthy.
case "$PLATFORM" in
  darwin-arm64)
    EXPECTED_FILE_ARCH="arm64"
    EXPECTED_HOST_ARCH="arm64"
    ;;
  darwin-x64)
    EXPECTED_FILE_ARCH="x86_64"
    EXPECTED_HOST_ARCH="x86_64"
    ;;
  *)
    echo "ERROR: unsupported distribution platform '$PLATFORM'." >&2
    exit 1
    ;;
esac

for bin in "$CLI_BIN_PATH" "$MCP_BIN_PATH"; do
  [[ -f "$bin" ]] || continue
  binary_description="$(file -b "$bin")"
  if [[ "$binary_description" != *"$EXPECTED_FILE_ARCH"* ]]; then
    echo "ERROR: $(basename "$bin") for $PLATFORM has wrong architecture: $binary_description" >&2
    exit 1
  fi
done

if [[ -f "$MCP_BIN_PATH" && "$(uname -m)" == "$EXPECTED_HOST_ARCH" ]]; then
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: node is required for wax-mcp version verification." >&2
    exit 1
  fi
  EXPECTED_VERSION="$(node -p "require('$PROJECT_ROOT/Resources/npm/waxmcp/package.json').version")"
  REPORTED_VERSION="$("$MCP_BIN_PATH" --version)"
  if [[ "$REPORTED_VERSION" != *"$EXPECTED_VERSION"* ]]; then
    echo "ERROR: wax-mcp reports '$REPORTED_VERSION', expected version $EXPECTED_VERSION." >&2
    exit 1
  fi
fi

# Generate checksums
for bin in "$CLI_BIN_PATH" "$MCP_BIN_PATH"; do
  if [[ -f "$bin" ]]; then
    if command -v shasum >/dev/null 2>&1; then
      digest="$(shasum -a 256 "$bin" | awk '{print $1}')"
    else
      digest="$(sha256sum "$bin" | awk '{print $1}')"
    fi
    printf '%s  %s\n' "$digest" "$(basename "$bin")" > "$bin.sha256"
    echo "Wrote $bin.sha256"
  fi
done
