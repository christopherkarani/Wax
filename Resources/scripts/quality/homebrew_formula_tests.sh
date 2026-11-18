#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
PACKAGE_JSON="$ROOT_DIR/Resources/npm/waxmcp/package.json"
FORMULA="$ROOT_DIR/Resources/npm/waxmcp/homebrew-wax/Formula/wax.rb"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

package_version="$(node -p "require('$PACKAGE_JSON').version")"
formula_version="$(sed -nE 's/.*waxmcp-v([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz.*/\1/p' "$FORMULA" | head -n 1)"
xcode_version="$(sed -nE 's/.*depends_on xcode: \["([^"]+)".*/\1/p' "$FORMULA" | head -n 1)"
swift_tools_version="$(sed -nE 's#^// swift-tools-version: ([0-9]+\.[0-9]+).*#\1#p' "$ROOT_DIR/Package.swift" | head -n 1)"

[[ -n "$formula_version" ]] || fail "could not extract waxmcp tag version from Homebrew formula"
[[ "$formula_version" == "$package_version" ]] \
  || fail "Homebrew formula version $formula_version does not match npm package version $package_version"

[[ -n "$xcode_version" ]] || fail "could not extract Xcode dependency from Homebrew formula"
# Oldest Xcode whose Swift compiler reads each swift-tools-version. The formula
# builds the released tarball, which can trail HEAD by one tools version until
# the next release, so either minimum is accepted. When a release ships source
# with the newer tools version, raise the formula to that minimum with it.
case "$swift_tools_version" in
  6.1) accepted_xcode_minimums=("16.3") ;;
  6.2) accepted_xcode_minimums=("26.0" "16.3") ;;
  *) fail "no Xcode mapping for Swift tools $swift_tools_version; add one here" ;;
esac
version_at_least() { [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]; }
xcode_ok=false
for minimum in "${accepted_xcode_minimums[@]}"; do
  if version_at_least "$xcode_version" "$minimum"; then xcode_ok=true; break; fi
done
[[ "$xcode_ok" == true ]] \
  || fail "Homebrew formula Xcode dependency $xcode_version does not satisfy Swift tools $swift_tools_version (needs ${accepted_xcode_minimums[*]})"

if grep -q 'inreplace "Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift"' "$FORMULA"; then
  fail "Homebrew formula must build the shipped MiniLM defaults without source mutation"
fi

formula_sha="$(sed -nE 's/.*sha256 "([a-f0-9]+)".*/\1/p' "$FORMULA" | head -n 1)"
[[ "$formula_sha" =~ ^[a-f0-9]{64}$ ]] \
  || fail "Homebrew formula sha256 must be 64 lowercase hex chars (got '${formula_sha:-missing}')"

echo "homebrew_formula_tests: ok"
