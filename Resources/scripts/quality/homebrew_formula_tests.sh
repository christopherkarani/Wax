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

[[ -n "$formula_version" ]] || fail "could not extract waxmcp tag version from Homebrew formula"
[[ "$formula_version" == "$package_version" ]] \
  || fail "Homebrew formula version $formula_version does not match npm package version $package_version"

echo "homebrew_formula_tests: ok"
