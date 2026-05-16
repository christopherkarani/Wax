#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while read -r mode _ _ path; do
  [[ "$mode" == "160000" ]] || continue

  name="$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' \
    | awk -v target="$path" '$2 == target { print $1 }' \
    | sed -E 's/^submodule\.([^.]*)\.path$/\1/' \
    | head -n 1 || true)"

  [[ -n "$name" ]] || fail "gitlink $path has no .gitmodules path entry"

  git config --file .gitmodules --get "submodule.$name.url" >/dev/null \
    || fail "gitlink $path has no .gitmodules url entry"
done < <(git ls-files -s)

echo "submodule_contract_tests: ok"
