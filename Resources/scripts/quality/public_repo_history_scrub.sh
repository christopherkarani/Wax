#!/usr/bin/env bash
# Rewrite history on a MIRROR clone. Does not touch the working repo or remote.
# Usage: bash Resources/scripts/quality/public_repo_history_scrub.sh /path/to/wax-hygiene-mirror.git
set -euo pipefail

MIRROR="${1:?mirror bare or checkout path required}"
if [[ ! -e "$MIRROR" ]]; then
  echo "FAIL: mirror path does not exist: $MIRROR" >&2
  exit 1
fi

cd "$MIRROR"

# Drop non-branch junk refs that pin old trees (Codex turn-diff captures, etc.).
echo "Pruning non-standard refs ..."
git for-each-ref --format='%(refname)' |
  rg '^(refs/codex/|refs/pull/)' |
  while read -r ref; do
    git update-ref -d "$ref" || true
  done

# Exact path prefixes / files to strip from all history.
PATHS=(
  CONTEXT.md
  AUDIT_REPORT.md
  CLAUDE.md
  WAX_TECHNICAL_ANALYSIS.md
  spec
  tasks
  Tasks
  task
  Task
  marketing
  docs/plans
  docs/product
  docs/superpowers
  Resources/docs/plans
  Resources/docs/wax-mcp-reliability-plan.md
  Resources/skills/internal
  .ryk
  .skynex
  .pi
  .opencode
  .grok
  .claude
  .gemini
  .qwen
  .playwright-mcp
  memvid-main
  memvid
  website/node_modules
  Resources/website/node_modules
  Resources/npm/waxmcp/dist
  npm/waxmcp/dist
  Resources/npm/waxmcp/waxmcp-0.1.24.tgz
  Resources/docs/assets/wax-github-banner.png
  Resources/docs/assets/wax-github-image.png
)

GLOBS=(
  'docs/framework-audit-*.md'
  'Resources/docs/assets/wax-banner-*.png'
  '*.tgz'
)

ARGS=()
for p in "${PATHS[@]}"; do
  ARGS+=(--path "$p")
done
for g in "${GLOBS[@]}"; do
  ARGS+=(--path-glob "$g")
done

echo "Scrubbing paths from history in $MIRROR ..."
git filter-repo --force "${ARGS[@]}" --invert-paths

echo "Post-scrub object size:"
du -sh .
echo "public_repo_history_scrub: ok"
