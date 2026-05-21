#!/usr/bin/env bash
set -euo pipefail

# bump-version.sh — Atomic version bump across ALL Wax deployment channels
# Usage: scripts/bump-version.sh <version> [--dry-run]
#   <version>: exact semver (0.1.23) or npm increment keyword (patch|minor|major)
#   --dry-run: print what would change without modifying files
#
# Surfaces managed:
#   1. Resources/npm/waxmcp/package.json (npm package)
#   2. Sources/WaxMCPServer/main.swift (Swift server)
#   3. Resources/openclaw/wax-memory-plugin/package.json (OpenClaw plugin version)
#   4. Resources/openclaw/wax-memory-plugin/package.json (OpenClaw waxmcp dependency)
#   5. Resources/npm/waxmcp/homebrew-wax/Formula/wax.rb (Homebrew URL)
#   6. Resources/npm/waxmcp/homebrew-wax/Formula/wax.rb (Homebrew SHA256)
#   7. .pi/extensions/wax-agents/package.json (OpenCode/pi extension)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ───────────────────────────────────────────────────────────
NPM_PKG="$ROOT/Resources/npm/waxmcp"
SERVER_SWIFT="$ROOT/Sources/WaxMCPServer/main.swift"
OPENCLAW_PKG="$ROOT/Resources/openclaw/wax-memory-plugin"
OPENCODE_PKG="$ROOT/.pi/extensions/wax-agents"
HOMEBREW_FORMULA="$ROOT/Resources/npm/waxmcp/homebrew-wax/Formula/wax.rb"
HOMEBREW_REPO="$ROOT/Resources/npm/waxmcp/homebrew-wax"
SYNC_SCRIPT="$ROOT/Resources/scripts/sync-waxmcp-version.sh"

DRY_RUN=false
VERSION_ARG=""

# ── Helpers ─────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: scripts/bump-version.sh <version> [--dry-run]"
  echo "  <version>: exact semver (0.1.23) or patch|minor|major"
  echo "  --dry-run: preview changes without writing files"
  exit 2
}

fail() {
  echo "❌ ERROR: $*" >&2
  exit 1
}

info() {
  echo "  → $*"
}

dry_info() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [DRY-RUN] $*"
  else
    info "$*"
  fi
}

# Validate semver format
validate_semver() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  case "$v" in
    patch|minor|major) return 0 ;;
  esac
  return 1
}

# Read current version from a package.json
read_pkg_version() {
  node -p "require('$1/package.json').version" 2>/dev/null || echo "NOT_FOUND"
}

# Read current version from main.swift
read_swift_version() {
  grep -oE 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' "$SERVER_SWIFT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "NOT_FOUND"
}

# Read current version from Homebrew formula URL
read_homebrew_version() {
  grep -oE 'waxmcp-v[0-9]+\.[0-9]+\.[0-9]+' "$HOMEBREW_FORMULA" | sed 's/waxmcp-v//' | head -n1 || echo "NOT_FOUND"
}

# Read current SHA from Homebrew formula
read_homebrew_sha() {
  grep -oE 'sha256 "[a-f0-9]+"' "$HOMEBREW_FORMULA" | grep -oE '[a-f0-9]+' || echo "NOT_FOUND"
}

# Print a nice table row
print_row() {
  printf "  %-50s │ %-10s │ %-10s\n" "$1" "$2" "$3"
}

# ── Argument parsing ────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage ;;
    *)
      if [[ -z "$VERSION_ARG" ]]; then
        VERSION_ARG="$arg"
      else
        usage
      fi
      ;;
  esac
done

if [[ -z "$VERSION_ARG" ]]; then
  usage
fi

if ! validate_semver "$VERSION_ARG"; then
  fail "version must be semver (0.1.23) or patch|minor|major (got '$VERSION_ARG')"
fi

# ── Phase 1: Read current state ─────────────────────────────────────────────
echo ""
echo "🔍 Reading current version state..."
echo ""

CURRENT_NPM=$(read_pkg_version "$NPM_PKG")
CURRENT_SWIFT=$(read_swift_version)
CURRENT_OPENCLAW=$(read_pkg_version "$OPENCLAW_PKG")
CURRENT_OPENCLAW_DEP=$(node -p "require('$OPENCLAW_PKG/package.json').dependencies.waxmcp" 2>/dev/null || echo "NOT_FOUND")
CURRENT_HOMEBREW=$(read_homebrew_version)
CURRENT_HOMEBREW_SHA=$(read_homebrew_sha)
CURRENT_OPCODE=$(read_pkg_version "$OPENCODE_PKG")

# ── Phase 2: Resolve target version ─────────────────────────────────────────
# Delegate to existing sync script to get the resolved version
# We use --dry-run first to get the resolved version without modifying
if [[ "$DRY_RUN" == true ]]; then
  # For dry-run, we need to compute what the version would be
  if [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    TARGET_VERSION="$VERSION_ARG"
  else
    # For patch/minor/major, we need npm to tell us what it would be
    # We do a temp copy to avoid modifying the real file
    TMPDIR=$(mktemp -d)
    cp "$NPM_PKG/package.json" "$TMPDIR/package.json"
    cd "$TMPDIR"
    npm version "$VERSION_ARG" --no-git-tag-version --allow-same-version >/dev/null 2>&1 || true
    TARGET_VERSION=$(node -p "require('$TMPDIR/package.json').version" 2>/dev/null || echo "")
    rm -rf "$TMPDIR"
    cd "$ROOT"
    if [[ -z "$TARGET_VERSION" ]]; then
      fail "Could not resolve version for increment '$VERSION_ARG'"
    fi
  fi
else
  # Real run: delegate to sync script, which bumps npm + Swift
  # It outputs the resolved version to stdout
  TARGET_VERSION=$("$SYNC_SCRIPT" "$VERSION_ARG")
fi

echo "📦 Target version: $TARGET_VERSION"
echo ""

# ── Idempotency check ───────────────────────────────────────────────────────
if [[ "$CURRENT_NPM" == "$TARGET_VERSION" ]] && \
   [[ "$CURRENT_SWIFT" == "$TARGET_VERSION" ]] && \
   [[ "$CURRENT_OPENCLAW" == "$TARGET_VERSION" ]] && \
   [[ "$CURRENT_OPENCLAW_DEP" == "$TARGET_VERSION" ]] && \
   [[ "$CURRENT_HOMEBREW" == "$TARGET_VERSION" ]] && \
   [[ "$CURRENT_OPCODE" == "$TARGET_VERSION" ]]; then
  echo "✅ All surfaces already at $TARGET_VERSION — nothing to do."
  exit 0
fi

# ── Phase 3: Compute what will change ───────────────────────────────────────
echo "📋 Planned changes:"
echo ""
printf "  %-50s │ %-10s │ %-10s\n" "Surface" "Old" "New"
printf "  %-50s ├ %-10s ┼ %-10s\n" "$(printf '%*s' 50 '' | tr ' ' '-')" "$(printf '%*s' 10 '' | tr ' ' '-')" "$(printf '%*s' 10 '' | tr ' ' '-')"

[[ "$CURRENT_NPM" != "$TARGET_VERSION" ]] && print_row "npm/waxmcp/package.json" "$CURRENT_NPM" "$TARGET_VERSION"
[[ "$CURRENT_SWIFT" != "$TARGET_VERSION" ]] && print_row "Sources/WaxMCPServer/main.swift" "$CURRENT_SWIFT" "$TARGET_VERSION"
[[ "$CURRENT_OPENCLAW" != "$TARGET_VERSION" ]] && print_row "openclaw plugin (version)" "$CURRENT_OPENCLAW" "$TARGET_VERSION"
[[ "$CURRENT_OPENCLAW_DEP" != "$TARGET_VERSION" ]] && print_row "openclaw plugin (waxmcp dep)" "$CURRENT_OPENCLAW_DEP" "$TARGET_VERSION"
[[ "$CURRENT_HOMEBREW" != "$TARGET_VERSION" ]] && print_row "homebrew formula (url)" "$CURRENT_HOMEBREW" "$TARGET_VERSION"
print_row "homebrew formula (sha256)" "${CURRENT_HOMEBREW_SHA:0:16}..." "(recompute)"
[[ "$CURRENT_OPCODE" != "$TARGET_VERSION" ]] && print_row ".pi/extensions/wax-agents" "$CURRENT_OPCODE" "$TARGET_VERSION"

echo ""

# ── Phase 4: Dry-run exit ───────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  echo "⚠️  DRY RUN — no files modified."
  echo "   Run without --dry-run to apply changes."
  exit 0
fi

# ── Phase 5: Apply changes ──────────────────────────────────────────────────
echo "📝 Applying version bumps..."
echo ""

# Surface 1+2: Already done by sync-waxmcp-version.sh (called above)
# We just verify it worked
NEW_NPM=$(read_pkg_version "$NPM_PKG")
NEW_SWIFT=$(read_swift_version)
if [[ "$NEW_NPM" != "$TARGET_VERSION" ]] || [[ "$NEW_SWIFT" != "$TARGET_VERSION" ]]; then
  fail "sync-waxmcp-version.sh did not bump correctly (npm=$NEW_NPM, swift=$NEW_SWIFT)"
fi
info "npm/waxmcp + Swift server → $TARGET_VERSION"

# Surface 3+4: OpenClaw plugin
if [[ "$CURRENT_OPENCLAW" != "$TARGET_VERSION" ]] || [[ "$CURRENT_OPENCLAW_DEP" != "$TARGET_VERSION" ]]; then
  cd "$OPENCLAW_PKG"
  npm version "$TARGET_VERSION" --no-git-tag-version --allow-same-version >/dev/null
  npm pkg set dependencies.waxmcp="$TARGET_VERSION"
  cd "$ROOT"
  info "OpenClaw plugin → $TARGET_VERSION (self + waxmcp dep)"
fi

# Surface 7: OpenCode extension
if [[ "$CURRENT_OPCODE" != "$TARGET_VERSION" ]]; then
  cd "$OPENCODE_PKG"
  npm version "$TARGET_VERSION" --no-git-tag-version --allow-same-version >/dev/null
  cd "$ROOT"
  info "OpenCode extension → $TARGET_VERSION"
fi

# Surfaces 5+6: Homebrew formula
if [[ "$CURRENT_HOMEBREW" != "$TARGET_VERSION" ]]; then
  # Update URL
  sed -i '' \
    "s|archive/refs/tags/waxmcp-v[0-9]\+\.[0-9]\+\.[0-9]\+|archive/refs/tags/waxmcp-v${TARGET_VERSION}|g" \
    "$HOMEBREW_FORMULA"
  
  # Compute SHA from local git archive
  # GitHub uses: git archive --format=tar.gz --prefix=repo-tag/ tag
  # We approximate this with the current HEAD
  TMP_ARCHIVE=$(mktemp -t wax-homebrew-sha.XXXXXX.tar.gz)
  git -C "$ROOT" archive --format=tar.gz \
    --prefix="Wax-waxmcp-v${TARGET_VERSION}/" \
    HEAD > "$TMP_ARCHIVE" 2>/dev/null || {
      rm -f "$TMP_ARCHIVE"
      fail "git archive failed — cannot compute Homebrew SHA"
    }
  
  NEW_SHA=$(shasum -a 256 "$TMP_ARCHIVE" | awk '{print $1}')
  rm -f "$TMP_ARCHIVE"
  
  sed -i '' \
    "s|sha256 \"[a-f0-9]\+\"|sha256 \"${NEW_SHA}\"|" \
    "$HOMEBREW_FORMULA"
  
  info "Homebrew formula → $TARGET_VERSION (SHA: ${NEW_SHA:0:16}...)"
  echo "     ⚠️  SHA computed from local git archive — verify after pushing tag:"
  echo "        curl -sL https://github.com/christopherkarani/Wax/archive/refs/tags/waxmcp-v${TARGET_VERSION}.tar.gz | shasum -a 256"
fi

# ── Phase 6: Summary ────────────────────────────────────────────────────────
echo ""
echo "✅ Version bump complete: $TARGET_VERSION"
echo ""
echo "Changed files:"
git -C "$ROOT" diff --name-only 2>/dev/null | sed 's/^/  /' || true
echo ""
echo "Next steps:"
echo "  1. Review: git diff"
echo "  2. Validate: scripts/validate-congruency.sh"
echo "  3. Build:    scripts/release-all.sh $TARGET_VERSION"
echo ""
