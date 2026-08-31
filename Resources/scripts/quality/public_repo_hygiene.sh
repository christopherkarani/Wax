#!/usr/bin/env bash
# Fail if tracked paths look like private planning, agent tooling, or build junk.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PATTERN='(^(tasks|Tasks|task|Task)/|^marketing/|^spec/|^CONTEXT\.md$|^AUDIT_REPORT\.md$|^CLAUDE\.md$|^WAX_TECHNICAL_ANALYSIS\.md$|docs/plans/|docs/product/|docs/superpowers/|docs/framework-audit|Resources/docs/plans/|Resources/docs/wax-mcp-reliability-plan|Resources/skills/internal/|issue[0-9]+_|_snapshot\.md|screenshot|TECHNICAL_ANALYSIS|audit-.*ledger|lessons\.md|(^|/)todo\.md$|\.grok/|\.ryk/|\.skynex/|\.pi/|\.opencode/|waxmcp/dist/|(^|/)[^/]+\.tgz$|^website/node_modules/|^memvid(-main)?/)'

hits="$(git ls-files | rg -i "$PATTERN" || true)"
if [[ -n "$hits" ]]; then
  echo "$hits" >&2
  fail "tracked paths violate public repository hygiene (see AGENTS.md)"
fi

# Draft banner variants must stay untracked; the shipping banner is wax-banner.png.
draft_banners="$(git ls-files 'Resources/docs/assets/wax-banner-*.png' 'Resources/docs/assets/wax-github-banner.png' 'Resources/docs/assets/wax-github-image.png' || true)"
if [[ -n "$draft_banners" ]]; then
  echo "$draft_banners" >&2
  fail "draft banner assets must not be tracked"
fi

echo "public_repo_hygiene: ok"
