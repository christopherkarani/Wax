#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "" ]]; then
  echo "usage: Resources/scripts/sync-waxmcp-version.sh <version|patch|minor|major>" >&2
  exit 2
fi

REQUESTED_VERSION="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG_DIR="$ROOT/Resources/npm/waxmcp"
# wax-mcp and wax-cli both read WaxReleaseInfo.version; this is the only Swift literal.
VERSION_SWIFT="$ROOT/Sources/Wax/WaxReleaseInfo.swift"

if [[ ! -f "$PKG_DIR/package.json" ]]; then
  echo "error: missing $PKG_DIR/package.json" >&2
  exit 2
fi

if [[ ! -f "$VERSION_SWIFT" ]]; then
  echo "error: missing $VERSION_SWIFT" >&2
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

perl -0pi -e 's/static let version\s*=\s*"[^"]+"/static let version = "'"$RELEASE_VERSION"'"/' "$VERSION_SWIFT"

# Plugin trees shipped in (or alongside) the npm package track the release:
# Hermes client info and pip/plugin metadata, OpenClaw manifest and package.
# Each pair of trees gets identical edits, so byte-identical copies stay so.
for tree in "$ROOT/Resources/hermes/wax-memory-plugin" "$PKG_DIR/plugins/hermes"; do
  perl -pi -e 's/^PLUGIN_VERSION = "[^"]+"$/PLUGIN_VERSION = "'"$RELEASE_VERSION"'"/' "$tree/hermes_wax_memory.py"
  perl -pi -e 's/^version = "[^"]+"$/version = "'"$RELEASE_VERSION"'"/' "$tree/pyproject.toml"
  perl -pi -e 's/^version: \S+$/version: '"$RELEASE_VERSION"'/' "$tree/plugin.yaml"
done
for tree in "$ROOT/Resources/openclaw/wax-memory-plugin" "$PKG_DIR/plugins/openclaw"; do
  perl -0pi -e 's/"version": "[^"]+"/"version": "'"$RELEASE_VERSION"'"/' "$tree/openclaw.plugin.json" "$tree/package.json"
  perl -0pi -e 's/"waxmcp": "[^"]+"/"waxmcp": "'"$RELEASE_VERSION"'"/' "$tree/package.json"
done

echo "$RELEASE_VERSION"
