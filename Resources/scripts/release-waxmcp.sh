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

echo "-> Bump versions to $VERSION"
RELEASE_VERSION="$("$ROOT/Resources/scripts/sync-waxmcp-version.sh" "$VERSION")"
echo "-> Release version $RELEASE_VERSION"

cd "$ROOT"
for target in \
  "darwin-arm64 arm64-apple-macosx14.0" \
  "darwin-x64 x86_64-apple-macosx14.0"
do
  read -r platform triple <<<"$target"
  echo "-> Build release binaries ($platform)"
  "$ROOT/Resources/scripts/build-waxmcp-binaries.sh" "$platform" "$triple"
done

echo "-> Done"
echo "Next:"
echo "  git status -sb"
echo "  git diff"
echo "  # optional local smoke checks:"
echo "  Resources/npm/waxmcp/dist/darwin-arm64/wax-cli vector-health --store-path /tmp/waxmcp-release.wax --format text"
echo "  Resources/npm/waxmcp/dist/darwin-arm64/wax-cli mcp doctor --server-path Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp --store-path /tmp/waxmcp-release.wax"
