#!/usr/bin/env bash
set -euo pipefail

# validate-congruency.sh — Assert all Wax deployment channels share the same version
# Usage: scripts/validate-congruency.sh [--json] [--quiet]
#   --json:  machine-parseable JSON output
#   --quiet: suppress output on success (only print on failure)
#
# Exit codes:
#   0 = all version surfaces are congruent
#   1 = version mismatch detected

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ───────────────────────────────────────────────────────────
NPM_PKG="$ROOT/Resources/npm/waxmcp"
SERVER_SWIFT="$ROOT/Sources/WaxMCPServer/main.swift"
OPENCLAW_PKG="$ROOT/Resources/openclaw/wax-memory-plugin"
OPENCODE_PKG="$ROOT/.pi/extensions/wax-agents"
HOMEBREW_FORMULA="$ROOT/Resources/npm/waxmcp/homebrew-wax/Formula/wax.rb"

JSON=false
QUIET=false

# ── Helpers ─────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: scripts/validate-congruency.sh [--json] [--quiet]"
  echo "  --json:  output machine-parseable JSON"
  echo "  --quiet: only output on failure"
  exit 2
}

# Read version from package.json
read_pkg_version() {
  node -p "require('$1/package.json').version" 2>/dev/null || echo "NOT_FOUND"
}

# Read version from main.swift
read_swift_version() {
  grep -oE 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' "$SERVER_SWIFT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND"
}

# Read waxmcp dependency from OpenClaw plugin
read_openclaw_dep() {
  node -p "require('$OPENCLAW_PKG/package.json').dependencies.waxmcp" 2>/dev/null || echo "NOT_FOUND"
}

# Read version from Homebrew formula URL
read_homebrew_version() {
  grep -oE 'waxmcp-v[0-9]+\.[0-9]+\.[0-9]+' "$HOMEBREW_FORMULA" | sed 's/waxmcp-v//' | head -n1 || echo "NOT_FOUND"
}

# ── Argument parsing ────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --json) JSON=true ;;
    --quiet) QUIET=true ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

# ── Read all versions ───────────────────────────────────────────────────────
NPM_VERSION=$(read_pkg_version "$NPM_PKG")
SWIFT_VERSION=$(read_swift_version)
OPENCLAW_VERSION=$(read_pkg_version "$OPENCLAW_PKG")
OPENCLAW_DEP=$(read_openclaw_dep)
HOMEBREW_VERSION=$(read_homebrew_version)
OPENCODE_VERSION=$(read_pkg_version "$OPENCODE_PKG")

# ── Determine canonical version ─────────────────────────────────────────────
# The npm package is the primary surface
CANONICAL="$NPM_VERSION"

# ── Check congruency ────────────────────────────────────────────────────────
CONGRUENT=true
MISMATCHES=()

if [[ "$SWIFT_VERSION" != "$CANONICAL" ]]; then
  CONGRUENT=false
  MISMATCHES+=("swift:$SWIFT_VERSION")
fi

if [[ "$OPENCLAW_VERSION" != "$CANONICAL" ]]; then
  CONGRUENT=false
  MISMATCHES+=("openclaw:$OPENCLAW_VERSION")
fi

if [[ "$OPENCLAW_DEP" != "$CANONICAL" ]]; then
  CONGRUENT=false
  MISMATCHES+=("openclaw-dep:$OPENCLAW_DEP")
fi

if [[ "$HOMEBREW_VERSION" != "$CANONICAL" ]]; then
  CONGRUENT=false
  MISMATCHES+=("homebrew:$HOMEBREW_VERSION")
fi

if [[ "$OPENCODE_VERSION" != "$CANONICAL" ]]; then
  CONGRUENT=false
  MISMATCHES+=("opencode:$OPENCODE_VERSION")
fi

# ── Output ──────────────────────────────────────────────────────────────────
if [[ "$JSON" == true ]]; then
  # Build JSON output
  echo "{"
  echo "  \"congruent\": $CONGRUENT,"
  echo "  \"canonical\": \"$CANONICAL\","
  echo "  \"versions\": {"
  echo "    \"npm\": \"$NPM_VERSION\","
  echo "    \"swift\": \"$SWIFT_VERSION\","
  echo "    \"openclaw\": \"$OPENCLAW_VERSION\","
  echo "    \"openclaw-dep\": \"$OPENCLAW_DEP\","
  echo "    \"homebrew\": \"$HOMEBREW_VERSION\","
  echo "    \"opencode\": \"$OPENCODE_VERSION\""
  echo "  },"
  if [[ ${#MISMATCHES[@]} -gt 0 ]]; then
    echo -n "  \"mismatches\": ["
    first=true
    for m in "${MISMATCHES[@]}"; do
      if [[ "$first" == true ]]; then
        first=false
      else
        echo -n ", "
      fi
      echo -n "\"$m\""
    done
    echo "]"
  else
    echo "  \"mismatches\": []"
  fi
  echo "}"
else
  # Human-readable output
  if [[ "$CONGRUENT" == true ]]; then
    if [[ "$QUIET" == false ]]; then
      echo "✅ All version surfaces are congruent at $CANONICAL"
    fi
  else
    if [[ "$QUIET" == false ]]; then
      echo "❌ Version incongruency detected"
      echo ""
      printf "  %-20s │ %-10s │ %s\n" "Surface" "Version" "Status"
      printf "  %-20s ├ %-10s ┼ %s\n" "$(printf '%*s' 20 '' | tr ' ' '-')" "$(printf '%*s' 10 '' | tr ' ' '-')" "$(printf '%*s' 8 '' | tr ' ' '-')"

      for surface in "npm:$NPM_VERSION" "swift:$SWIFT_VERSION" "openclaw:$OPENCLAW_VERSION" "openclaw-dep:$OPENCLAW_DEP" "homebrew:$HOMEBREW_VERSION" "opencode:$OPENCODE_VERSION"; do
        name="${surface%%:*}"
        version="${surface#*:}"
        if [[ "$version" == "$CANONICAL" ]]; then
          status="✅"
        else
          status="❌ expected $CANONICAL"
        fi
        printf "  %-20s │ %-10s │ %s\n" "$name" "$version" "$status"
      done
      echo ""
      echo "Run scripts/bump-version.sh $CANONICAL to align all surfaces."
    fi
  fi
fi

# Exit with appropriate code
if [[ "$CONGRUENT" == true ]]; then
  exit 0
else
  exit 1
fi
