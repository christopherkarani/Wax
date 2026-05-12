#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: scripts/verify-openclaw-native-memory.sh [output-json]

Runs an end-to-end native-memory verification flow against wax-mcp:
1. Starts a broker-backed stdio MCP server in an isolated temp environment.
2. Verifies session memory writes, search/get round-trips, and compacted context.
3. Exports Markdown projections, imports manual Markdown edits, and approves DREAMS.md.
4. Restarts the MCP server and verifies session resume + recovery.

If an output path is supplied, a JSON verification report is written there.
EOF
  exit 0
fi

OUTPUT_PATH="${1:-}"

echo "==> Build wax-mcp"
swift build --product wax-mcp --traits default,MCPServer --disable-automatic-resolution >/dev/null

echo "==> Run native-memory verification"
python3 - "$ROOT" "$OUTPUT_PATH" <<'PY'
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

root = Path(sys.argv[1])
output_path = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
wax_mcp = root / ".build" / "debug" / "wax-mcp"
if not wax_mcp.exists():
    wax_mcp = root / ".build" / "arm64-apple-macosx" / "debug" / "wax-mcp"
if not wax_mcp.exists():
    raise SystemExit("error: built wax-mcp binary not found")

tmp = Path(tempfile.mkdtemp(prefix="wonm-", dir="/tmp"))
home = tmp / "home"
home.mkdir(parents=True, exist_ok=True)
store = tmp / "openclaw-native-memory.wax"
broker_dir = tmp / "broker"
projection_root = tmp / "projection"
projection_root.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["HOME"] = str(home)
env["WAX_BROKER_DIR"] = str(broker_dir)
env["WAX_BROKER_IDLE_TIMEOUT_SECS"] = "1"

results = {
    "store_path": str(store),
    "projection_root": str(projection_root),
    "checks": {},
    "timings_ms": {},
}


class MCPProc:
    def __init__(self):
        self.proc = None
        self.next_id = 1

    def start(self):
        self.proc = subprocess.Popen(
            [str(wax_mcp), "--store-path", str(store), "--no-embedder"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self._initialize()

    def close(self):
        if self.proc is None:
            return
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=2)
        except Exception:
            self.proc.kill()
            self.proc.wait(timeout=2)
        self.proc = None

    def _send(self, payload):
        assert self.proc is not None
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def _recv(self, expected_id, timeout=30):
        assert self.proc is not None
        assert self.proc.stdout is not None
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = max(0.0, deadline - time.time())
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                break
            line = self.proc.stdout.readline()
            if not line:
                stderr = self.proc.stderr.read() if self.proc.stderr else ""
                raise RuntimeError(f"EOF waiting for response {expected_id}; stderr={stderr}")
            message = json.loads(line)
            if message.get("id") == expected_id:
                return message
        stderr = self.proc.stderr.read() if self.proc.stderr else ""
        raise RuntimeError(f"Timed out waiting for response {expected_id}; stderr={stderr}")

    def _initialize(self):
        initialize_id = self.next_id
        self.next_id += 1
        tools_id = self.next_id
        self.next_id += 1
        self._send({
            "jsonrpc": "2.0",
            "id": initialize_id,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "openclaw-native-memory-verifier", "version": "1.0"},
            },
        })
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        self._send({"jsonrpc": "2.0", "id": tools_id, "method": "tools/list", "params": {}})
        init = self._recv(initialize_id)
        tools = self._recv(tools_id)
        if init.get("result", {}).get("serverInfo", {}).get("name") != "wax-mcp":
            raise RuntimeError(f"unexpected initialize response: {init}")
        tool_names = {tool["name"] for tool in tools["result"]["tools"]}
        required = {
            "memory_append", "memory_search", "memory_get", "session_start", "session_resume",
            "compact_context", "markdown_export", "markdown_sync", "session_synthesize",
        }
        missing = sorted(required - tool_names)
        if missing:
            raise RuntimeError(f"missing tool(s): {missing}")

    def call(self, name, arguments, timeout=30):
        request_id = self.next_id
        self.next_id += 1
        self._send({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        })
        response = self._recv(request_id, timeout=timeout)
        result = response.get("result", {})
        if result.get("isError"):
            raise RuntimeError(f"{name} failed: {response}")
        return response


def parse_text_json(message):
    for item in message["result"]["content"]:
        if item.get("type") == "text":
            try:
                return json.loads(item["text"])
            except json.JSONDecodeError:
                continue
    for item in message["result"]["content"]:
        resource = item.get("resource")
        if item.get("type") == "resource" and resource and resource.get("mimeType") == "application/json":
            return json.loads(resource["text"])
    raise RuntimeError(f"missing text payload: {message}")


def parse_resource_json(message, suffix):
    for item in message["result"]["content"]:
        resource = item.get("resource")
        if item.get("type") == "resource" and resource and resource.get("uri", "").endswith(suffix):
            return json.loads(resource["text"])
    raise RuntimeError(f"missing resource payload {suffix}: {message}")


server = MCPProc()

try:
    server.start()

    started = parse_text_json(server.call("session_start", {}, timeout=20))
    session_id = started["session_id"]
    results["session_id"] = session_id

    working_anchor = "OPENCLAW_NATIVE_WORKING_ANCHOR"
    decision_anchor = "Decision: OPENCLAW_NATIVE_DREAM_PROMOTION_ANCHOR"
    durable_anchor = "OPENCLAW_NATIVE_MARKDOWN_MEMORY_ANCHOR"
    daily_anchor = "OPENCLAW_NATIVE_DAILY_NOTE_ANCHOR"

    start = time.perf_counter()
    server.call("memory_append", {
        "content": f"{working_anchor} working context should survive compact context and recovery.",
        "session_id": session_id,
        "memory_type": "task_state",
    }, timeout=20)
    results["timings_ms"]["session_append"] = round((time.perf_counter() - start) * 1000, 2)

    server.call("remember", {
        "content": decision_anchor,
        "session_id": session_id,
        "memory_type": "decision",
    }, timeout=20)

    start = time.perf_counter()
    working_search = server.call("memory_search", {
        "query": working_anchor,
        "session_id": session_id,
        "mode": "text",
        "topK": 5,
    }, timeout=20)
    results["timings_ms"]["memory_search"] = round((time.perf_counter() - start) * 1000, 2)
    working_search_json = parse_resource_json(working_search, "memory-search-summary")
    if not working_search_json["results"]:
        raise RuntimeError("memory_search returned no working-memory results")
    working_memory_id = working_search_json["results"][0]["memory_id"]
    results["checks"]["working_memory_search"] = True

    working_get = parse_text_json(server.call("memory_get", {"memory_id": working_memory_id}, timeout=20))
    if working_anchor not in working_get["text"]:
        raise RuntimeError("memory_get did not return the working-memory content")
    results["checks"]["memory_get_round_trip"] = True

    start = time.perf_counter()
    compact = parse_resource_json(server.call("compact_context", {
        "query": working_anchor,
        "session_id": session_id,
        "token_budget": 768,
        "mode": "text",
    }, timeout=20), "compact-context-summary")
    results["timings_ms"]["compact_context"] = round((time.perf_counter() - start) * 1000, 2)
    compact_text = json.dumps(compact)
    if working_anchor not in compact_text:
        raise RuntimeError("compact_context did not include the working-memory anchor")
    results["checks"]["compact_context_includes_working_memory"] = True

    synth = parse_resource_json(server.call("session_synthesize", {
        "session_id": session_id,
    }, timeout=20), "session-synthesize-summary")
    if len(synth.get("durable_candidates", [])) < 1:
        raise RuntimeError("session_synthesize did not surface any promotion candidates")
    results["checks"]["session_synthesize_candidates"] = True

    start = time.perf_counter()
    export = parse_text_json(server.call("markdown_export", {
        "output_dir": str(projection_root),
        "session_id": session_id,
    }, timeout=20))
    results["timings_ms"]["markdown_export"] = round((time.perf_counter() - start) * 1000, 2)

    memory_path = Path(export["memory_md_path"])
    dreams_path = Path(export["dreams_path"])
    daily_path = Path(export["daily_note_paths"][0])

    memory_text = memory_path.read_text(encoding="utf-8")
    memory_text += f"\n- {durable_anchor} imported from Markdown.\n"
    memory_path.write_text(memory_text, encoding="utf-8")

    daily_text = daily_path.read_text(encoding="utf-8")
    daily_text += f"\n- {daily_anchor} imported from Markdown.\n"
    daily_path.write_text(daily_text, encoding="utf-8")

    dreams_text = dreams_path.read_text(encoding="utf-8")
    dreams_text = dreams_text.replace("- [ ]", "- [x]", 1)
    dreams_path.write_text(dreams_text, encoding="utf-8")

    start = time.perf_counter()
    dry_sync = parse_text_json(server.call("markdown_sync", {
        "root_dir": str(projection_root),
        "dry_run": True,
    }, timeout=60))
    results["timings_ms"]["markdown_sync_dry_run"] = round((time.perf_counter() - start) * 1000, 2)
    dry_counts = dry_sync["counts"]
    if dry_counts["created"] < 2 or dry_counts["approved_dreams"] < 1:
        raise RuntimeError(f"markdown_sync dry-run did not report expected mutations: {dry_counts}")
    results["checks"]["markdown_sync_dry_run_preview"] = True

    start = time.perf_counter()
    sync = parse_text_json(server.call("markdown_sync", {
        "root_dir": str(projection_root),
    }, timeout=60))
    results["timings_ms"]["markdown_sync"] = round((time.perf_counter() - start) * 1000, 2)
    counts = sync["counts"]
    if counts["created"] < 2 or counts["approved_dreams"] < 1:
        raise RuntimeError(f"markdown_sync did not import and approve expected entries: {counts}")
    results["checks"]["markdown_sync_imports_and_approvals"] = True

    durable_search = server.call("search", {"query": durable_anchor, "topK": 5}, timeout=20)
    if durable_anchor not in json.dumps(parse_resource_json(durable_search, "search-summary")):
        raise RuntimeError("search did not find the Markdown-imported durable memory")
    results["checks"]["markdown_memory_imported"] = True

    daily_search = server.call("search", {"query": daily_anchor, "topK": 5}, timeout=20)
    if daily_anchor not in json.dumps(parse_resource_json(daily_search, "search-summary")):
        raise RuntimeError("search did not find the Markdown-imported daily note")
    results["checks"]["daily_note_imported"] = True

    dream_search = server.call("search", {"query": decision_anchor, "topK": 5}, timeout=20)
    if "DREAM" not in json.dumps(parse_resource_json(dream_search, "search-summary")):
        raise RuntimeError("search did not find the DREAMS-approved durable memory")
    results["checks"]["dream_approval_promoted"] = True

    server.close()

    recovered = MCPProc()
    try:
        recovered.start()
        start = time.perf_counter()
        resumed = parse_text_json(recovered.call("session_resume", {"session_id": session_id}, timeout=20))
        results["timings_ms"]["session_resume_after_restart"] = round((time.perf_counter() - start) * 1000, 2)
        if not resumed.get("resumed"):
            raise RuntimeError(f"session_resume did not reopen the persisted session: {resumed}")
        results["checks"]["session_resume_after_restart"] = True

        recovered_get = parse_text_json(recovered.call("memory_get", {"memory_id": working_memory_id}, timeout=20))
        if working_anchor not in recovered_get["text"]:
            raise RuntimeError("memory_get after session resume did not recover working memory")
        results["checks"]["working_memory_recovered_after_restart"] = True

        recovered.call("handoff", {
            "session_id": session_id,
            "content": "OpenClaw native-memory verifier handoff.",
            "project": "Wax",
            "pending_tasks": ["confirm native memory recovery"],
        }, timeout=20)
    finally:
        recovered.close()

    results["status"] = "ok"
finally:
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    shutil.rmtree(tmp, ignore_errors=True)

if output_path is not None:
    print(f"Wrote verification report to {output_path}")
print(json.dumps(results, indent=2, sort_keys=True))
PY
