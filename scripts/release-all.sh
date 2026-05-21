#!/usr/bin/env bash
set -euo pipefail

# release-all.sh — Unified release orchestrator for Wax
# Usage: scripts/release-all.sh <version> [--dry-run] [--skip-build] [--allow-dirty]
#   <version>:      exact semver (0.1.23) or patch|minor|major
#   --dry-run:       preview the full pipeline without writing files
#   --skip-build:    skip binary compilation (useful if binaries already built)
#   --allow-dirty:   allow running with uncommitted changes
#
# Pipeline:
#   1. Bump all version surfaces (scripts/bump-version.sh)
#   2. Build darwin-arm64 + darwin-x64 binaries
#   3. Validate version congruency
#   4. Generate commit message
#   5. Print next steps

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ───────────────────────────────────────────────────────────
BUMP_SCRIPT="$SCRIPT_DIR/bump-version.sh"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-congruency.sh"
BUILD_SCRIPT="$ROOT/Resources/scripts/build-waxmcp-binaries.sh"

# Platform definitions: "PLATFORM TRIPLE"
PLATFORMS=(
  "darwin-arm64 arm64-apple-macosx14.0"
  "darwin-x64 x86_64-apple-macosx14.0"
)

VERSION_ARG=""
DRY_RUN=false
SKIP_BUILD=false
ALLOW_DIRTY=false

# ── Helpers ─────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: scripts/release-all.sh <version> [--dry-run] [--skip-build] [--allow-dirty]"
  echo "  <version>:      semver (0.1.23) or patch|minor|major"
  echo "  --dry-run:       preview without modifying files"
  echo "  --skip-build:    skip binary compilation"
  echo "  --allow-dirty:   allow uncommitted changes"
  exit 2
}

fail() {
  echo "❌ ERROR: $*" >&2
  exit 1
}

info() {
  echo "  → $*"
}

phase() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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

# ── Argument parsing ────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --skip-build) SKIP_BUILD=true ;;
    --allow-dirty) ALLOW_DIRTY=true ;;
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

# ── Phase 0: Pre-flight checks ──────────────────────────────────────────────
phase "Phase 0: Pre-flight checks"

# Check git state
if [[ "$ALLOW_DIRTY" == false ]] && ! git -C "$ROOT" diff --quiet 2>/dev/null; then
  echo ""
  echo "⚠️  Git working tree is dirty."
  echo "   Commit or stash changes first, or use --allow-dirty."
  echo ""
  git -C "$ROOT" status --short
  exit 1
fi
info "Git working tree is clean"

# Resolve target version early
if [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  TARGET_VERSION="$VERSION_ARG"
else
  # For patch/minor/major, compute what npm would resolve to
  TMPDIR=$(mktemp -d)
  cp "$ROOT/Resources/npm/waxmcp/package.json" "$TMPDIR/package.json"
  cd "$TMPDIR"
  npm version "$VERSION_ARG" --no-git-tag-version --allow-same-version >/dev/null 2>&1 || true
  TARGET_VERSION=$(node -p "require('$TMPDIR/package.json').version" 2>/dev/null || echo "")
  rm -rf "$TMPDIR"
  cd "$ROOT"
  if [[ -z "$TARGET_VERSION" ]]; then
    fail "Could not resolve version for increment '$VERSION_ARG'"
  fi
fi

info "Target version: $TARGET_VERSION"

# ── Phase 1: Bump versions ──────────────────────────────────────────────────
phase "Phase 1: Bump all version surfaces"

BUMP_ARGS=("$VERSION_ARG")
if [[ "$DRY_RUN" == true ]]; then
  BUMP_ARGS+=("--dry-run")
fi

"$BUMP_SCRIPT" "${BUMP_ARGS[@]}"

# After bump, read the resolved version
RESOLVED_VERSION=$(node -p "require('$ROOT/Resources/npm/waxmcp/package.json').version")
info "Resolved version: $RESOLVED_VERSION"

# ── Phase 2: Build binaries ─────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == false ]]; then
  phase "Phase 2: Build release binaries"

  for target in "${PLATFORMS[@]}"; do
    read -r platform triple <<<"$target"
    info "Building $platform ($triple)..."

    if [[ "$DRY_RUN" == true ]]; then
      echo "  [DRY-RUN] Would run: $BUILD_SCRIPT $platform $triple"
    else
      "$BUILD_SCRIPT" "$platform" "$triple"
    fi
  done

  info "All binaries built"
else
  phase "Phase 2: Build binaries [SKIPPED]"
  info "Using existing binaries in Resources/npm/waxmcp/dist/"
fi

# ── Phase 3: Validate congruency ────────────────────────────────────────────
phase "Phase 3: Validate version congruency"

if [[ "$DRY_RUN" == true ]]; then
  echo "  [DRY-RUN] Would run: $VALIDATE_SCRIPT"
else
  "$VALIDATE_SCRIPT" || fail "Version congruency check failed"
  info "All version surfaces are congruent at $RESOLVED_VERSION"
fi

# ── Phase 4: Generate commit message ────────────────────────────────────────
phase "Phase 4: Release summary"

echo ""
echo "  Commit message preview:"
echo "  ┌─────────────────────────────────────────────────────────────────────────┐"
echo "  │ release: waxmcp v$RESOLVED_VERSION"
echo "  │                                                                         │"
echo "  │ Changes:                                                                │"
echo "  │   - npm/waxmcp: bump to v$RESOLVED_VERSION"
echo "  │   - Swift server: bump to v$RESOLVED_VERSION"
echo "  │   - OpenClaw plugin: bump to v$RESOLVED_VERSION"
echo "  │   - OpenCode extension: bump to v$RESOLVED_VERSION"
echo "  │   - Homebrew formula: bump to v$RESOLVED_VERSION"
echo "  │   - darwin-arm64 + darwin-x64 binaries rebuilt                          │"
echo "  └─────────────────────────────────────────────────────────────────────────┘"
echo ""

# ── Phase 5: Next steps ─────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  echo "⚠️  DRY RUN — no files were modified."
  echo "   Run without --dry-run to execute the full release pipeline."
  echo ""
  exit 0
fi

echo "✅ Release v$RESOLVED_VERSION is ready"
echo ""
echo "Next steps:"
echo "  1. Review changes:"
echo "       git diff --stat"
echo ""
echo "  2. Commit and tag:"
echo "       git add -A"
echo "       git commit -m \"release: waxmcp v$RESOLVED_VERSION\""
echo "       git tag waxmcp-v$RESOLVED_VERSION"
echo ""
echo "  3. Push:"
echo "       git push origin main --tags"
echo ""
echo "  4. Publish (staged):"
echo "       scripts/publish-all.sh --tag next"
echo ""
echo "  5. After soak period, promote to latest:"
echo "       scripts/publish-all.sh --promote"
echo ""
