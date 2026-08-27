#!/usr/bin/env bash
# Static contract tests for the LaunchAgent wrapper + plist.
# Do not start wax-mcp. Do not bind :3000. Do not run launchctl.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WRAP="$ROOT/start-wax-mcp-http.sh"
PLIST="$ROOT/ai.wax.mcp-http.plist.template"
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

pass() {
  echo "PASS: $*"
}

if [[ ! -f "$WRAP" ]]; then
  fail "missing wrapper $WRAP"
else
  if grep -q 'set -euo pipefail' "$WRAP"; then
    pass "wrapper has set -euo pipefail"
  else
    fail "wrapper missing set -euo pipefail"
  fi

  if grep -q 'wax-mcp' "$WRAP" \
    && grep -q -- '--transport http' "$WRAP" \
    && grep -q -- '--http-port 3000' "$WRAP"; then
    pass "wrapper execs wax-mcp with --transport http and --http-port 3000"
  else
    fail "wrapper must exec wax-mcp with --transport http and --http-port 3000"
  fi

  if grep -q '0.1.26' "$WRAP"; then
    fail "wrapper must not contain 0.1.26"
  else
    pass "wrapper does not contain 0.1.26"
  fi
fi

if [[ ! -f "$PLIST" ]]; then
  fail "missing plist template $PLIST"
else
  if grep -q '<string>ai.wax.mcp-http</string>' "$PLIST" \
    && grep -A1 '<key>KeepAlive</key>' "$PLIST" | grep -q '<true/>'; then
    pass "plist Label ai.wax.mcp-http and KeepAlive true"
  else
    fail "plist must have Label ai.wax.mcp-http and KeepAlive true"
  fi

  first="$(
    awk '
      /<key>ProgramArguments<\/key>/ { found=1; next }
      found && /<array>/ { inarr=1; next }
      inarr && /<string>/ {
        gsub(/.*<string>/, "")
        gsub(/<\/string>.*/, "")
        print
        exit
      }
    ' "$PLIST"
  )"
  case "$first" in
    *start-wax-mcp-http.sh)
      pass "plist ProgramArguments[0] ends with start-wax-mcp-http.sh"
      ;;
    *)
      fail "plist ProgramArguments[0] must end with start-wax-mcp-http.sh (got: ${first:-<empty>})"
      ;;
  esac
fi

if [[ "$failures" -ne 0 ]]; then
  echo "test.sh: $failures failure(s)" >&2
  exit 1
fi

echo "test.sh: all checks passed"
