#!/usr/bin/env bash
set -euo pipefail

VERSION_BUMP="${1:-}"
if [[ -z "$VERSION_BUMP" ]]; then
  echo "Usage: $0 <patch|minor|major|x.y.z>" >&2
  exit 64
fi

if ! [[ "$VERSION_BUMP" =~ ^([0-9]+\.[0-9]+\.[0-9]+|patch|minor|major)$ ]]; then
  echo "Usage: $0 <patch|minor|major|x.y.z>" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

npm --version >/dev/null
node --version >/dev/null

cd "$PROJECT_ROOT/npm/waxmcp"
npm version "$VERSION_BUMP" --no-git-tag-version --allow-same-version
cd "$PROJECT_ROOT"

VERSION="$(node -p "require('./npm/waxmcp/package.json').version")"
perl -0pi -e "s/let serverVersion = \"[0-9]+\\.[0-9]+\\.[0-9]+\"/let serverVersion = \"$VERSION\"/" Sources/WaxMCPServer/main.swift

if ! grep -q "let serverVersion = \"$VERSION\"" Sources/WaxMCPServer/main.swift; then
  echo "ERROR: failed to sync serverVersion in Sources/WaxMCPServer/main.swift" >&2
  exit 1
fi

echo "Preparing release binaries for version $VERSION"
./scripts/build-waxmcp-binaries.sh darwin-arm64 arm64-apple-macosx14.0

if ! ./scripts/build-waxmcp-binaries.sh darwin-x64 x86_64-apple-macosx14.0; then
  if [[ -f "$PROJECT_ROOT/npm/waxmcp/dist/darwin-x64/wax-cli" ]]; then
    echo "WARN: x64 cross-compile is unavailable on this host. Reusing checked-in darwin-x64 binary."
  else
    echo "ERROR: darwin-x64 binary missing and cross-compile is unavailable on this host." >&2
    exit 1
  fi
fi

echo "Done. Updated npm package and binaries for Wax MCP $VERSION"
