#!/usr/bin/env bash
# Assert the public Wax tree has no git submodules.
# Submodules broke SwiftPM resolve when a gitlink pointed at an unpublished
# homebrew-wax commit (0.1.24). Formula lives as normal tracked files now.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ -e .gitmodules ]]; then
  fail ".gitmodules must not exist (Homebrew formula is vendored; no submodules)"
fi

while read -r mode _ _ path; do
  [[ "$mode" == "160000" ]] || continue
  fail "gitlink $path is not allowed (submodules break SwiftPM package resolve)"
done < <(git ls-files -s)

# Formula must remain a normal file at the stable path used by release scripts.
FORMULA="Resources/npm/waxmcp/homebrew-wax/Formula/wax.rb"
[[ -f "$FORMULA" ]] || fail "missing vendored Homebrew formula at $FORMULA"
mode="$(git ls-files -s -- "$FORMULA" | awk '{print $1}')"
[[ "$mode" == "100644" || "$mode" == "100755" ]] \
  || fail "Homebrew formula must be a normal tracked file (got mode ${mode:-missing})"

echo "submodule_contract_tests: ok"
