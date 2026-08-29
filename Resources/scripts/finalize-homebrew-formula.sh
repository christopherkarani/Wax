#!/usr/bin/env bash
# finalize-homebrew-formula.sh — Set Homebrew sha256 from the GitHub tag archive.
#
# bump-version.sh can only hash a local git archive, which does not match
# GitHub's `archive/refs/tags/waxmcp-v*.tar.gz`. Call this after the release
# tag exists (locally or from CI) to write the brew-installable checksum, and
# optionally sync christopherkarani/homebrew-wax.
#
# Usage:
#   Resources/scripts/finalize-homebrew-formula.sh [version] [--push-tap] [--dry-run]
#   Resources/scripts/finalize-homebrew-formula.sh --push-tap   # version from package.json
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORMULA="$ROOT/Resources/npm/waxmcp/homebrew-wax/Formula/wax.rb"
PACKAGE_JSON="$ROOT/Resources/npm/waxmcp/package.json"
TAP_REPO="${HOMEBREW_TAP_REPO:-christopherkarani/homebrew-wax}"
TAP_URL="${HOMEBREW_TAP_URL:-https://github.com/${TAP_REPO}.git}"

VERSION=""
PUSH_TAP=false
DRY_RUN=false

usage() {
  echo "usage: Resources/scripts/finalize-homebrew-formula.sh [version] [--push-tap] [--dry-run]" >&2
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    --push-tap) PUSH_TAP=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage ;;
    *)
      if [[ -z "$VERSION" && "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        VERSION="$arg"
      else
        usage
      fi
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION="$(node -p "require('$PACKAGE_JSON').version")"
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: invalid version '$VERSION'" >&2
  exit 2
fi

[[ -f "$FORMULA" ]] || { echo "error: missing formula at $FORMULA" >&2; exit 2; }

ARCHIVE_URL="https://github.com/christopherkarani/Wax/archive/refs/tags/waxmcp-v${VERSION}.tar.gz"
echo "-> Fetching $ARCHIVE_URL"

TMP_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/wax-homebrew-github.XXXXXX.tar.gz")"
TAP_DIR=""
cleanup() {
  rm -f "$TMP_ARCHIVE"
  if [[ -n "$TAP_DIR" && -d "$TAP_DIR" ]]; then
    rm -rf "$TAP_DIR"
  fi
}
trap cleanup EXIT

if ! curl -fsSL -o "$TMP_ARCHIVE" "$ARCHIVE_URL"; then
  echo "error: failed to download GitHub archive for waxmcp-v${VERSION}" >&2
  echo "       url: $ARCHIVE_URL" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  NEW_SHA="$(shasum -a 256 "$TMP_ARCHIVE" | awk '{print $1}')"
else
  NEW_SHA="$(sha256sum "$TMP_ARCHIVE" | awk '{print $1}')"
fi

if ! [[ "$NEW_SHA" =~ ^[a-f0-9]{64}$ ]]; then
  echo "error: computed sha256 is not 64 hex chars: '$NEW_SHA'" >&2
  exit 1
fi

CURRENT_URL_VERSION="$(sed -nE 's/.*waxmcp-v([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz.*/\1/p' "$FORMULA" | head -n 1)"
CURRENT_SHA="$(sed -nE 's/.*sha256 "([a-f0-9]+)".*/\1/p' "$FORMULA" | head -n 1)"

echo "-> Formula version: ${CURRENT_URL_VERSION:-missing} → $VERSION"
echo "-> Formula sha256:  ${CURRENT_SHA:0:16}… → ${NEW_SHA:0:16}…"

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY-RUN] would update $FORMULA"
  [[ "$PUSH_TAP" == true ]] && echo "[DRY-RUN] would sync $TAP_REPO"
  exit 0
fi

# Portable in-place sed
sed_inplace() {
  local expr="$1"
  local file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i -E "$expr" "$file"
  else
    sed -i '' -E "$expr" "$file"
  fi
}

sed_inplace \
  "s|archive/refs/tags/waxmcp-v[0-9]+\\.[0-9]+\\.[0-9]+|archive/refs/tags/waxmcp-v${VERSION}|g" \
  "$FORMULA"
sed_inplace \
  "s|sha256 \"[a-f0-9]+\"|sha256 \"${NEW_SHA}\"|" \
  "$FORMULA"

echo "-> Updated vendored formula"

if [[ "$PUSH_TAP" != true ]]; then
  echo "-> Done (pass --push-tap to sync $TAP_REPO)"
  exit 0
fi

TAP_TOKEN="${HOMEBREW_TAP_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
TAP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wax-homebrew-tap.XXXXXX")"

clone_url="$TAP_URL"
if [[ -n "$TAP_TOKEN" ]]; then
  clone_url="https://x-access-token:${TAP_TOKEN}@github.com/${TAP_REPO}.git"
fi

echo "-> Syncing tap $TAP_REPO"
git clone --depth 1 "$clone_url" "$TAP_DIR"
mkdir -p "$TAP_DIR/Formula"
cp "$FORMULA" "$TAP_DIR/Formula/wax.rb"

git -C "$TAP_DIR" config user.name "wax-release[bot]"
git -C "$TAP_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git -C "$TAP_DIR" diff --quiet -- Formula/wax.rb; then
  echo "-> Tap already up to date at v$VERSION"
  exit 0
fi

git -C "$TAP_DIR" add Formula/wax.rb
git -C "$TAP_DIR" commit -m "bump wax to v${VERSION}"
git -C "$TAP_DIR" push origin HEAD
echo "-> Pushed Formula/wax.rb to $TAP_REPO"
