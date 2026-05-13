#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: scripts/release-waxmcp.sh <version>" >&2
  echo "example: scripts/release-waxmcp.sh 0.1.18" >&2
  exit 2
fi

VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be semver like 0.1.18 (got '$VERSION')" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG_JSON="$ROOT/Resources/npm/waxmcp/package.json"
SERVER_SWIFT="$ROOT/Sources/WaxMCPServer/main.swift"
DIST_DIR="$ROOT/Resources/npm/waxmcp/dist/darwin-arm64"
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/release"

if [[ ! -f "$PKG_JSON" ]]; then
  echo "error: missing $PKG_JSON" >&2
  exit 2
fi

if [[ ! -f "$SERVER_SWIFT" ]]; then
  echo "error: missing $SERVER_SWIFT" >&2
  exit 2
fi

echo "-> Bump versions to $VERSION"
perl -0pi -e 's/"version"\s*:\s*"[^"]+"/"version": "'"$VERSION"'"/' "$PKG_JSON"
perl -0pi -e 's/let serverVersion\s*=\s*"[^"]+"/let serverVersion = "'"$VERSION"'"/' "$SERVER_SWIFT"

echo "-> Build release binaries (darwin-arm64)"
cd "$ROOT"
swift build -c release --product wax-cli --traits default,MCPServer
swift build -c release --product wax-mcp --traits default,MCPServer

echo "-> Stage dist artifacts"
mkdir -p "$DIST_DIR"
cp -f "$BUILD_DIR/wax-cli" "$DIST_DIR/wax-cli"
cp -f "$BUILD_DIR/wax-mcp" "$DIST_DIR/wax-mcp"

# Copy all SwiftPM resource bundles next to the binaries so Bundle.module resolves at runtime.
for b in "$BUILD_DIR"/*.bundle; do
  name="$(basename "$b")"
  rm -rf "$DIST_DIR/$name"
  ditto "$b" "$DIST_DIR/$name"
done

shasum -a 256 "$DIST_DIR/wax-cli" | awk '{print $1 "  wax-cli"}' > "$DIST_DIR/wax-cli.sha256"
shasum -a 256 "$DIST_DIR/wax-mcp" | awk '{print $1 "  wax-mcp"}' > "$DIST_DIR/wax-mcp.sha256"

echo "-> Done"
echo "Next:"
echo "  git status -sb"
echo "  git diff"
echo "  # optional local smoke checks:"
echo "  $DIST_DIR/wax-cli vector-health --store-path /tmp/waxmcp-release.wax --format text"
echo "  $DIST_DIR/wax-cli mcp doctor --server-path $DIST_DIR/wax-mcp --store-path /tmp/waxmcp-release.wax"
