#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: Resources/scripts/sync-waxmcp-version.sh <version|patch|minor|major>" >&2
  exit 2
fi

REQUESTED_VERSION="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG_DIR="$ROOT/Resources/npm/waxmcp"
SERVER_SWIFT="$ROOT/Sources/WaxMCPServer/main.swift"

if [[ ! -f "$PKG_DIR/package.json" ]]; then
  echo "error: missing $PKG_DIR/package.json" >&2
  exit 2
fi

if [[ ! -f "$SERVER_SWIFT" ]]; then
  echo "error: missing $SERVER_SWIFT" >&2
  exit 2
fi

case "$REQUESTED_VERSION" in
  patch|minor|major|[0-9]*.[0-9]*.[0-9]*)
    ;;
  *)
    echo "error: version must be patch, minor, major, or semver like 0.1.18 (got '$REQUESTED_VERSION')" >&2
    exit 2
    ;;
esac

npm --prefix "$PKG_DIR" version "$REQUESTED_VERSION" --no-git-tag-version --allow-same-version >/dev/null
RELEASE_VERSION="$(node -p "require('$PKG_DIR/package.json').version")"

perl -0pi -e 's/static let version\s*=\s*"[^"]+"/static let version = "'"$RELEASE_VERSION"'"/' "$SERVER_SWIFT"

echo "$RELEASE_VERSION"
