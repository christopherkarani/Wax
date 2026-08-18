#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CANONICAL="$ROOT_DIR/Resources/hermes/wax-memory-plugin"
NPM_COPY="$ROOT_DIR/Resources/npm/waxmcp/plugins/hermes"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 -m unittest discover -s "$CANONICAL/tests" -p "test_*.py" -v \
  || fail "Hermes Wax memory provider tests failed"

grep -Fq 'hermes_agent.memory_providers' "$CANONICAL/pyproject.toml" \
  || fail "pip entry point must use hermes_agent.memory_providers"
grep -Fq 'wax-memory = "hermes_wax_memory:register"' "$CANONICAL/pyproject.toml" \
  || fail "pip entry point must point at register()"
grep -Fq 'HERMES_HOME' "$ROOT_DIR/Resources/npm/waxmcp/bin/waxmcp.js" \
  || fail "waxmcp install-hermes-plugin must honor HERMES_HOME"

runtime_files=(
  hermes_wax_memory.py
  wax_memory_schemas.py
  __init__.py
  plugin.yaml
  pyproject.toml
  README.md
  cli.py
)

for file in "${runtime_files[@]}"; do
  cmp -s "$CANONICAL/$file" "$NPM_COPY/$file" \
    || fail "npm Hermes plugin copy drifted: $file"
done

cmp -s "$CANONICAL/skills/maintenance/SKILL.md" "$NPM_COPY/skills/maintenance/SKILL.md" \
  || fail "npm Hermes plugin skill copy drifted"

echo "hermes_plugin_tests: ok"
