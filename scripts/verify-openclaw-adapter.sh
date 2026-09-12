#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: scripts/verify-openclaw-adapter.sh

Runs a repeatable OpenClaw adapter verification pass:
1. Asserts canonical/npm OpenClaw plugin src↔dist lockstep and forbids the
   shared-port spawn fallback.
2. Builds the MCP server and CLI.
3. Runs a direct stdio bootstrap smoke flow against wax-mcp and asserts the OpenClaw adapter tools are published.
4. Runs the stable targeted MCP/unit test slices sequentially.

This is intentionally not a single giant grouped process-test run because the
shared MCP process harness is still intermittently flaky when many broker-backed
process tests execute in one batch.
EOF
  exit 0
fi

echo "==> OpenClaw plugin src↔dist lockstep"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
canonical = root / "Resources/openclaw/wax-memory-plugin"
npm = root / "Resources/npm/waxmcp/plugins/openclaw"

required = [
    canonical / "src/index.ts",
    canonical / "dist/index.js",
    npm / "src/index.ts",
    npm / "dist/index.js",
]
missing = [str(path) for path in required if not path.is_file()]
if missing:
    raise SystemExit("missing OpenClaw plugin file(s): " + ", ".join(missing))

canonical_src = (canonical / "src/index.ts").read_text(encoding="utf-8")
canonical_dist = (canonical / "dist/index.js").read_text(encoding="utf-8")
npm_src = (npm / "src/index.ts").read_text(encoding="utf-8")
npm_dist = (npm / "dist/index.js").read_text(encoding="utf-8")

if canonical_src != canonical_dist:
    raise SystemExit("canonical src/index.ts and dist/index.js drifted")
if npm_src != npm_dist:
    raise SystemExit("npm src/index.ts and dist/index.js drifted")
if canonical_src != npm_src:
    raise SystemExit("canonical and npm OpenClaw plugin src drifted")
if canonical_dist != npm_dist:
    raise SystemExit("canonical and npm OpenClaw plugin dist drifted")

forbidden = (
    "--no-embedder",
    "pluginConfig?.command",
    "pluginConfig?.args",
    '"mcp",\n        "serve"',
    "mcp serve",
)
for label, text in (("src", canonical_src), ("dist", canonical_dist)):
    for needle in forbidden:
        if needle in text:
            raise SystemExit(f"OpenClaw plugin {label} still contains spawn fallback {needle!r}")
    if "http://127.0.0.1:3000/mcp" not in text:
        raise SystemExit(f"OpenClaw plugin {label} must default to the shared HTTP endpoint")
    if 'id: PLUGIN_ID' not in text and 'id: "wax-memory"' not in text:
        raise SystemExit(f"OpenClaw plugin {label} must keep exclusive id wax-memory")

print("OpenClaw plugin src↔dist lockstep ok")
PY

TEST_FILTERS=(
  "toolsListContainsExpectedTools"
  "sessionStartEndAndScopedRecallSearchWork"
  "vectorFallbackIsSurfacedInSearchAndStats"
  "corpusSearchBuildsAcrossSessionStoresAndReturnsProvenance"
  "brokerBackedMemorySearchAndGetExposeStableMemoryIDs"
  "brokerBackedSessionResumeReopensPersistedSessionAfterRestart"
  "brokerBackedCompactContextDoesNotLoseSessionMemoryAcrossRepeatedCheckpoints"
  "brokerBackedMarkdownExportProjectsCompatibilityFiles"
  "brokerBackedMemorySearchDoesNotLeakAcrossSessions"
  "brokerBackedHighVolumeWorkingMemoryRemainsSearchable"
  "brokerAutoStartHandlesConcurrentFirstAccess"
  "waxMCPStartupReusesBrokerForSharedStore"
  "corpusSearchSkipsLockedBrokerManagedSessionStore"
)

run_filter() {
  local filter="$1"
  local attempt
  for attempt in 1 2; do
    echo "---- $filter (attempt $attempt)"
    if swift test --traits default,MCPServer --filter "$filter" --disable-automatic-resolution; then
      sleep 1
      return 0
    fi
    if [[ "$attempt" -eq 1 ]]; then
      echo "retrying $filter after a transient MCP process-test failure..."
      sleep 2
    fi
  done
  return 1
}

echo "==> Build wax-mcp + wax-cli"
swift build --product wax-cli --product wax-mcp --traits default,MCPServer --disable-automatic-resolution

echo "==> Direct MCP bootstrap smoke"
python3 - "$ROOT" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
wax_mcp = root / ".build" / "debug" / "wax-mcp"
if not wax_mcp.exists():
    wax_mcp = root / ".build" / "arm64-apple-macosx" / "debug" / "wax-mcp"
if not wax_mcp.exists():
    raise SystemExit("error: built wax-mcp binary not found")

tmp = Path(tempfile.mkdtemp(prefix="wov-", dir="/tmp"))
home = tmp / "home"
home.mkdir(parents=True, exist_ok=True)
store = tmp / "openclaw-adapter-smoke.wax"
export_dir = tmp / "markdown-export"
broker_dir = tmp / "b"
env = os.environ.copy()
env["HOME"] = str(home)
env["WAX_BROKER_DIR"] = str(broker_dir)
env["WAX_BROKER_IDLE_TIMEOUT_SECS"] = "1"

def start_proc():
    return subprocess.Popen(
        [str(wax_mcp), "--store-path", str(store), "--no-embedder"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
    )

def send(proc, payload):
    line = json.dumps(payload, separators=(",", ":"))
    assert proc.stdin is not None
    proc.stdin.write(line + "\n")
    proc.stdin.flush()

def recv(proc, expected_id):
    assert proc.stdout is not None
    while True:
        line = proc.stdout.readline()
        if not line:
            stderr = proc.stderr.read() if proc.stderr is not None else ""
            raise RuntimeError(f"EOF waiting for response {expected_id}; stderr={stderr}")
        msg = json.loads(line)
        if msg.get("id") == expected_id:
            return msg

def bootstrap(proc, tools_id):
    send(proc, {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "openclaw-adapter-verifier", "version": "1.0"},
        },
    })
    send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    send(proc, {"jsonrpc": "2.0", "id": tools_id, "method": "tools/list", "params": {}})
    init_msg = recv(proc, 1)
    tools_msg = recv(proc, tools_id)
    if "result" not in init_msg or "result" not in tools_msg:
        raise RuntimeError("bootstrap failed")
    tool_names = {tool["name"] for tool in tools_msg["result"]["tools"]}
    if os.environ.get("WAX_MCP_TOOLS", "daily").strip().lower() == "full":
        required = {
            "memory_append", "memory_search", "memory_get", "session_start",
            "session_resume", "compact_context", "handoff", "markdown_export", "markdown_sync",
        }
    else:
        required = {"remember", "recall", "stats"}
    missing = sorted(required - tool_names)
    if missing:
        raise RuntimeError(f"missing tool(s): {missing}")

def call_tool(proc, req_id, name, arguments):
    send(proc, {
        "jsonrpc": "2.0",
        "id": req_id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    })
    msg = recv(proc, req_id)
    result = msg.get("result", {})
    if result.get("isError"):
        raise RuntimeError(f"{name} failed: {msg}")
    return msg

def parse_text_json(msg):
    for item in msg["result"]["content"]:
        if item.get("type") == "text":
            return json.loads(item["text"])
    raise RuntimeError(f"missing text payload: {msg}")

def parse_resource_json(msg, suffix):
    for item in msg["result"]["content"]:
        resource = item.get("resource")
        if item.get("type") == "resource" and resource and resource.get("uri", "").endswith(suffix):
            return json.loads(resource["text"])
    raise RuntimeError(f"missing resource payload {suffix}: {msg}")

def close_proc(proc):
    try:
        if proc.stdin:
            proc.stdin.close()
    except Exception:
        pass
    try:
        proc.terminate()
        proc.wait(timeout=2)
    except Exception:
        proc.kill()
        proc.wait(timeout=2)

first = start_proc()
try:
    bootstrap(first, 2)
finally:
    close_proc(first)

full_env_store = tmp / "openclaw-adapter-full.wax"
env["WAX_MCP_TOOLS"] = "full"
second = subprocess.Popen(
    [str(wax_mcp), "--store-path", str(full_env_store), "--no-embedder"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    env=env,
)
try:
    bootstrap(second, 2)
finally:
    close_proc(second)
    shutil.rmtree(tmp, ignore_errors=True)

print("direct MCP bootstrap smoke passed")
PY

echo "==> Targeted test slices"
for filter in "${TEST_FILTERS[@]}"; do
  run_filter "$filter"
done

echo
echo "OpenClaw adapter verification passed."
