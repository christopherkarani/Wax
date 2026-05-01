#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${WAX_MCP_HTTP_PORT:-3101}"
HOST="${WAX_MCP_HTTP_HOST:-127.0.0.1}"
ENDPOINT="${WAX_MCP_HTTP_ENDPOINT:-/mcp}"
AUTH_TOKEN="${WAX_MCP_HTTP_AUTH_TOKEN:-}"
MAX_BODY_BYTES="${WAX_MCP_HTTP_MAX_BODY_BYTES:-1048576}"
STORE="$(mktemp -u "${TMPDIR:-/tmp}/wax-http-XXXXXX.wax")"
LOG="$(mktemp "${TMPDIR:-/tmp}/wax-http-log-XXXXXX.txt")"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$STORE" "$LOG"
}
trap cleanup EXIT

cd "$ROOT"
swift build --product wax-mcp --traits default,MCPServer --disable-automatic-resolution >/dev/null

./.build/debug/wax-mcp \
  --store-path "$STORE" \
  --no-embedder \
  --transport http \
  --http-host "$HOST" \
  --http-port "$PORT" \
  --http-endpoint "$ENDPOINT" \
  --http-max-body-bytes "$MAX_BODY_BYTES" \
  >"$LOG" 2>&1 &
SERVER_PID=$!

python3 - "$HOST" "$PORT" "$ENDPOINT" "$AUTH_TOKEN" "$MAX_BODY_BYTES" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

host, port, endpoint, auth_token, max_body_bytes_raw = sys.argv[1:6]
max_body_bytes = int(max_body_bytes_raw)
url = f"http://{host}:{port}{endpoint}"

def post(payload, session_id=None, timeout=15):
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2024-11-05",
    }
    if auth_token:
        headers["Authorization"] = f"Bearer {auth_token}"
    if session_id:
        headers["MCP-Session-Id"] = session_id
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        session_id = response.getheader("MCP-Session-Id") or response.getheader("Mcp-Session-Id")
        body = response.read().decode()
        return session_id, body

def post_raw(body, timeout=15, include_auth=True):
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2024-11-05",
    }
    if auth_token and include_auth:
        headers["Authorization"] = f"Bearer {auth_token}"
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()

def extract_json(sse_body):
    for line in sse_body.splitlines():
        if line.startswith("data: "):
            return json.loads(line[6:])
    raise RuntimeError(f"missing SSE data frame: {sse_body}")

session_id = None
initialize_body = None
initialize_payload = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "wax-http-verifier", "version": "1.0"},
    },
}

last_error = None
for _ in range(50):
    try:
        session_id, initialize_body = post(initialize_payload, timeout=2)
        break
    except (ConnectionRefusedError, TimeoutError, urllib.error.URLError) as exc:
        last_error = exc
        time.sleep(0.2)

if initialize_body is None:
    raise RuntimeError(f"HTTP MCP server did not become ready: {last_error}")

if not session_id:
    raise RuntimeError("initialize response missing MCP-Session-Id header")
initialize_json = extract_json(initialize_body)
if initialize_json.get("result", {}).get("serverInfo", {}).get("name") != "wax-mcp":
    raise RuntimeError(f"unexpected initialize response: {initialize_json}")

if auth_token:
    status, body = post_raw(json.dumps(initialize_payload).encode(), include_auth=False)
    if status != 401:
        raise RuntimeError(f"expected 401 for missing bearer token, got {status}: {body}")

large_body = b"{" + b'"method":"' + (b"x" * max_body_bytes) + b'"}'
status, body = post_raw(large_body)
if status != 413:
    raise RuntimeError(f"expected 413 for oversized request body, got {status}: {body}")

_, tools_body = post({
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
    "params": {},
}, session_id=session_id)
tools_json = extract_json(tools_body)
tool_names = {tool["name"] for tool in tools_json["result"]["tools"]}
required = {"memory_search", "compact_context", "markdown_export", "markdown_sync"}
missing = sorted(required - tool_names)
if missing:
    raise RuntimeError(f"missing HTTP MCP tool(s): {missing}")

print("Wax MCP HTTP verification passed.")
PY
