#!/usr/bin/env bash
# Publish Resources/skills/public/wax to the christopherkarani/wax-skill repo.
# Usage:
#   Resources/scripts/publish-wax-skill.sh           # push to main
#   Resources/scripts/publish-wax-skill.sh --dry-run # print plan only
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Resources/skills/public/wax"
REPO_URL="${WAX_SKILL_REPO_URL:-https://github.com/christopherkarani/wax-skill.git}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$SOURCE_DIR/SKILL.md" ]]; then
  echo "error: missing skill at $SOURCE_DIR/SKILL.md" >&2
  exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/wax-skill-publish.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "source: $SOURCE_DIR"
echo "repo:   $REPO_URL"
echo "work:   $WORKDIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "dry-run: would clone $REPO_URL, sync skills/wax + README/LICENSE, commit, and push"
  find "$SOURCE_DIR" -type f | sort
  exit 0
fi

git clone --depth 1 "$REPO_URL" "$WORKDIR/repo"
mkdir -p "$WORKDIR/repo/skills"
rm -rf "$WORKDIR/repo/skills/wax"
cp -a "$SOURCE_DIR" "$WORKDIR/repo/skills/wax"

# Repo-level docs (kept next to the skill source in Wax)
cp "$ROOT_DIR/Resources/docs/wax-swift-skill.md" "$WORKDIR/repo/README.md"
if [[ -f "$ROOT_DIR/LICENSE" ]]; then
  cp "$ROOT_DIR/LICENSE" "$WORKDIR/repo/LICENSE"
fi

cd "$WORKDIR/repo"
git add -A
if git diff --cached --quiet; then
  echo "nothing to publish (already up to date)"
  exit 0
fi

git -c user.name="${GIT_AUTHOR_NAME:-Wax Publish}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-publish@wax.local}" \
    commit -m "sync: publish wax Apple-apps skill from Wax monorepo"

git push origin HEAD:main
echo "published to $REPO_URL"
