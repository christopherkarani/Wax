#!/usr/bin/env bash
set -euo pipefail

# publish-all.sh — Staged publishing pipeline for Wax deployment channels
# Usage: scripts/publish-all.sh [--tag <tag>] [--promote] [--dry-run]
#   --tag <tag>:  npm dist-tag to publish under (default: "next")
#   --promote:     promote current "next" tag to "latest" (no publish)
#   --dry-run:     preview what would be published without executing
#
# Channels published:
#   - waxmcp (npm package)
#   - @wax/openclaw-wax-memory (OpenClaw plugin)
#   - Homebrew formula (git push instructions)
#
# Staged workflow:
#   1. scripts/publish-all.sh --tag next     # publish to canary
#   2. [soak period: test, verify]           # manual or automated
#   3. scripts/publish-all.sh --promote      # promote to latest

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ───────────────────────────────────────────────────────────
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-congruency.sh"
NPM_PKG="$ROOT/Resources/npm/waxmcp"
OPENCLAW_PKG="$ROOT/Resources/openclaw/wax-memory-plugin"
HOMEBREW_REPO="$ROOT/Resources/npm/waxmcp/homebrew-wax"

TAG="next"
PROMOTE=false
DRY_RUN=false

# ── Helpers ─────────────────────────────────────────────────────────────────
usage() {
  echo "Usage: scripts/publish-all.sh [--tag <tag>] [--promote] [--dry-run]"
  echo "  --tag <tag>:  npm dist-tag (default: next)"
  echo "  --promote:     promote next → latest"
  echo "  --dry-run:     preview without publishing"
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

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      if [[ $# -lt 2 ]]; then
        fail "--tag requires a value"
      fi
      TAG="$2"
      shift 2
      ;;
    --promote) PROMOTE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

# ── Promote mode ────────────────────────────────────────────────────────────
if [[ "$PROMOTE" == true ]]; then
  phase "Promote: next → latest"

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [DRY-RUN] Would promote next → latest for waxmcp and @wax/openclaw-wax-memory"
    exit 0
  fi

  # Get current next version
  WAXMCP_NEXT=$(npm view waxmcp@next version 2>/dev/null || echo "")
  OPENCLAW_NEXT=$(npm view @wax/openclaw-wax-memory@next version 2>/dev/null || echo "")

  if [[ -z "$WAXMCP_NEXT" ]]; then
    fail "No 'next' tag found for waxmcp"
  fi

  info "Promoting waxmcp@$WAXMCP_NEXT → latest"
  npm dist-tag add "waxmcp@$WAXMCP_NEXT" latest
  npm dist-tag rm "waxmcp@$WAXMCP_NEXT" next

  if [[ -n "$OPENCLAW_NEXT" ]]; then
    info "Promoting @wax/openclaw-wax-memory@$OPENCLAW_NEXT → latest"
    npm dist-tag add "@wax/openclaw-wax-memory@$OPENCLAW_NEXT" latest
    npm dist-tag rm "@wax/openclaw-wax-memory@$OPENCLAW_NEXT" next
  fi

  echo ""
  echo "✅ Promotion complete"
  echo ""
  echo "  waxmcp@$WAXMCP_NEXT is now tagged as 'latest'"
  [[ -n "$OPENCLAW_NEXT" ]] && echo "  @wax/openclaw-wax-memory@$OPENCLAW_NEXT is now tagged as 'latest'"
  echo ""
  exit 0
fi

# ── Publish mode ────────────────────────────────────────────────────────────
phase "Publish mode (tag: $TAG)"

# ── Phase 1: Pre-flight checks ──────────────────────────────────────────────
phase "Phase 1: Pre-flight checks"

# Check git state
if ! git -C "$ROOT" diff --quiet 2>/dev/null; then
  echo ""
  echo "⚠️  Git working tree is dirty."
  echo "   Commit changes before publishing."
  echo ""
  git -C "$ROOT" status --short
  exit 1
fi
info "Git working tree is clean"

# Validate congruency
info "Validating version congruency..."
"$VALIDATE_SCRIPT" --quiet || fail "Version surfaces are incongruent. Run scripts/bump-version.sh to align."
info "All version surfaces are congruent"

# Read resolved version
RESOLVED_VERSION=$(node -p "require('$NPM_PKG/package.json').version")
info "Publishing version: $RESOLVED_VERSION"

# ── Phase 2: Publish npm packages ───────────────────────────────────────────
phase "Phase 2: Publish npm packages"

# Publish waxmcp
info "Publishing waxmcp@$RESOLVED_VERSION (tag: $TAG)..."
if [[ "$DRY_RUN" == true ]]; then
  echo "  [DRY-RUN] Would run: cd $NPM_PKG && npm publish --tag $TAG --access public"
else
  cd "$NPM_PKG"
  npm publish --tag "$TAG" --access public
  cd "$ROOT"
  info "waxmcp@$RESOLVED_VERSION published with tag '$TAG'"
fi

# Publish OpenClaw plugin
info "Publishing @wax/openclaw-wax-memory@$RESOLVED_VERSION (tag: $TAG)..."
if [[ "$DRY_RUN" == true ]]; then
  echo "  [DRY-RUN] Would run: cd $OPENCLAW_PKG && npm publish --tag $TAG --access public"
else
  cd "$OPENCLAW_PKG"
  npm publish --tag "$TAG" --access public
  cd "$ROOT"
  info "@wax/openclaw-wax-memory@$RESOLVED_VERSION published with tag '$TAG'"
fi

# ── Phase 3: Homebrew instructions ──────────────────────────────────────────
phase "Phase 3: Homebrew formula"

if [[ -d "$HOMEBREW_REPO/.git" ]]; then
  info "Homebrew tap repo found at $HOMEBREW_REPO"

  if [[ "$DRY_RUN" == true ]]; then
    echo "  [DRY-RUN] Would push homebrew-wax formula update"
  else
    cd "$HOMEBREW_REPO"
    if git diff --quiet 2>/dev/null; then
      info "No changes in homebrew-wax — nothing to push"
    else
      git add Formula/wax.rb
      git commit -m "bump wax to v$RESOLVED_VERSION"
      git push origin master
      info "Homebrew formula pushed to christopherkarani/homebrew-wax"
    fi
    cd "$ROOT"
  fi
else
  echo "  ⚠️  Homebrew tap repo not found at $HOMEBREW_REPO"
  echo "     Push manually: cd $HOMEBREW_REPO && git push"
fi

# ── Phase 4: Summary ────────────────────────────────────────────────────────
phase "Publish summary"

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "⚠️  DRY RUN — nothing was published."
  echo "   Run without --dry-run to publish."
else
  echo "✅ Published successfully"
  echo ""
  echo "  📦 waxmcp@$RESOLVED_VERSION (tag: $TAG)"
  echo "  📦 @wax/openclaw-wax-memory@$RESOLVED_VERSION (tag: $TAG)"
  echo "  🍺 Homebrew formula updated"
  echo ""
  echo "After soak period, promote to latest:"
  echo "  scripts/publish-all.sh --promote"
fi
echo ""
