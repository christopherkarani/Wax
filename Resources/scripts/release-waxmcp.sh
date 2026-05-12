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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_JSON="$ROOT/Resources/npm/waxmcp/package.json"
SERVER_SWIFT="$ROOT/Sources/WaxMCPServer/main.swift"
BUILD_SCRIPT="$ROOT/Resources/scripts/build-waxmcp-binaries.sh"

if [[ ! -f "$PKG_JSON" ]]; then
  echo "error: missing $PKG_JSON" >&2
  exit 2
fi

if [[ ! -f "$SERVER_SWIFT" ]]; then
  echo "error: missing $SERVER_SWIFT" >&2
  exit 2
fi

if [[ ! -x "$BUILD_SCRIPT" ]]; then
  echo "error: missing executable $BUILD_SCRIPT" >&2
  exit 2
fi

echo "-> Bump versions to $VERSION"
perl -0pi -e 's/"version"\s*:\s*"[^"]+"/"version": "'"$VERSION"'"/' "$PKG_JSON"
VERSION="$VERSION" perl -0pi -e 's/(enum\s+WaxMCPServerMetadata\s*\{[\s\S]*?static\s+let\s+version\s*=\s*)"[^"]+"/$1"$ENV{VERSION}"/' "$SERVER_SWIFT"

echo "-> Build release binaries (darwin-arm64, darwin-x64)"
cd "$ROOT"
"$BUILD_SCRIPT" darwin-arm64 arm64-apple-macosx15.0
"$BUILD_SCRIPT" darwin-x64 x86_64-apple-macosx15.0

echo "-> Done"
echo "Next:"
echo "  git status -sb"
echo "  git diff"
echo "  # optional local smoke checks:"
echo "  Resources/npm/waxmcp/dist/darwin-arm64/wax-cli vector-health --store-path /tmp/waxmcp-release.wax --format text"
echo "  Resources/npm/waxmcp/dist/darwin-arm64/wax-cli mcp doctor --server-path Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp --store-path /tmp/waxmcp-release.wax"
