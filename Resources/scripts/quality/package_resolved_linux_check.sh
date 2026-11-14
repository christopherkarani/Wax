#!/usr/bin/env bash
# Checks that SwiftPM on Linux resolved only pins the committed Package.resolved
# already has.
#
# Package.swift declares SwiftTUI and Noora (WaxRepo) under `#if os(macOS)`, so
# SwiftPM on Linux rewrites Package.resolved without them and their transitive
# pins, and without pins for dependencies the current traits do not use. That
# rewrite is expected and must never be committed. A pin that is new or moved
# to another revision means the committed file is stale for Linux, so fail.
#
# Usage: package_resolved_linux_check.sh [committed-ref]   (default: HEAD)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"
REF="${1:-HEAD}"

if [[ ! -f Package.resolved ]]; then
  echo "FAIL: Package.resolved is missing after resolution" >&2
  exit 1
fi

COMMITTED="$(mktemp)"
trap 'rm -f "$COMMITTED"' EXIT
git show "$REF:Package.resolved" >"$COMMITTED"

python3 - "$COMMITTED" Package.resolved <<'PY'
import json
import sys

def pins(path):
    with open(path, encoding="utf-8") as handle:
        return {pin["identity"]: pin for pin in json.load(handle)["pins"]}

committed = pins(sys.argv[1])
resolved = pins(sys.argv[2])
problems = []
for identity, pin in sorted(resolved.items()):
    if identity not in committed:
        problems.append(f"new pin {identity} ({pin.get('location')})")
    elif pin.get("state") != committed[identity].get("state"):
        problems.append(
            f"pin {identity} moved: committed {committed[identity].get('state')}, resolved {pin.get('state')}"
        )
if problems:
    print("FAIL: Linux resolution changed committed Package.resolved pins:", file=sys.stderr)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    sys.exit(1)
dropped = sorted(set(committed) - set(resolved))
print(f"package_resolved_linux_check: ok ({len(resolved)} pins match; not resolved here: {', '.join(dropped) or 'none'})")
PY
