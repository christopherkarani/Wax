#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: scripts/benchmark-openclaw-memory.sh [output-json]

Runs a focused benchmark sweep for the OpenClaw-oriented Wax memory path:
- long-running session growth
- compact_context latency under load
- Markdown export/sync cost
- recovery after broker restart
- corpus_search with rebuild=true vs rebuild=false

Set WAX_OPENCLAW_BENCH_DOCS to change the number of session notes (default: 200).
If an output path is supplied, the benchmark report is written there.
EOF
  exit 0
fi

OUTPUT_PATH="${1:-}"

echo "==> Build wax-mcp"
swift build --product wax-mcp --traits default,MCPServer --disable-automatic-resolution >/dev/null

echo "==> Run benchmark sweep"
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
doc_count = int(os.environ.get("WAX_OPENCLAW_BENCH_DOCS", "200"))
wax_mcp = root / ".build" / "debug" / "wax-mcp"
if not wax_mcp.exists():
    wax_mcp = root / ".build" / "arm64-apple-macosx" / "debug" / "wax-mcp"
if not wax_mcp.exists():
    raise SystemExit("error: built wax-mcp binary not found")

tmp = Path(tempfile.mkdtemp(prefix="wobm-", dir="/tmp"))
home = tmp / "home"
home.mkdir(parents=True, exist_ok=True)
store = tmp / "openclaw-benchmark.wax"
broker_dir = tmp / "broker"
session_root = broker_dir / "sessions"
projection_root = tmp / "projection"
projection_root.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env["HOME"] = str(home)
env["WAX_BROKER_DIR"] = str(broker_dir)
env["WAX_SESSION_ROOT"] = str(session_root)
env["WAX_BROKER_IDLE_TIMEOUT_SECS"] = "1"


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
        assert self.proc and self.proc.stdin
        self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def _recv(self, expected_id, timeout=60):
        assert self.proc and self.proc.stdout
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
        init_id = self.next_id
        self.next_id += 1
        tools_id = self.next_id
        self.next_id += 1
        self._send({
            "jsonrpc": "2.0",
            "id": init_id,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "openclaw-benchmark", "version": "1.0"},
            },
        })
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        self._send({"jsonrpc": "2.0", "id": tools_id, "method": "tools/list", "params": {}})
        self._recv(init_id)
        self._recv(tools_id)

    def call(self, name, arguments, timeout=60):
        request_id = self.next_id
        self.next_id += 1
        self._send({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        })
        response = self._recv(request_id, timeout=timeout)
        if response.get("result", {}).get("isError"):
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


benchmark = {
    "doc_count": doc_count,
    "timings_ms": {},
}

server = MCPProc()
try:
    server.start()
    started = parse_text_json(server.call("session_start", {}, timeout=20))
    session_id = started["session_id"]

    t0 = time.perf_counter()
    for index in range(doc_count):
        server.call("memory_append", {
            "content": f"OPENCLAW_BENCH_{index:04d} benchmark task state for scalable session growth.",
            "session_id": session_id,
            "memory_type": "task_state",
        }, timeout=30)
    benchmark["timings_ms"]["append_total"] = round((time.perf_counter() - t0) * 1000, 2)
    benchmark["timings_ms"]["append_avg"] = round(benchmark["timings_ms"]["append_total"] / doc_count, 2)

    t0 = time.perf_counter()
    server.call("memory_search", {
        "query": "OPENCLAW_BENCH_0199" if doc_count >= 200 else f"OPENCLAW_BENCH_{doc_count - 1:04d}",
        "session_id": session_id,
        "mode": "text",
        "topK": 8,
    }, timeout=30)
    benchmark["timings_ms"]["memory_search_under_load"] = round((time.perf_counter() - t0) * 1000, 2)

    t0 = time.perf_counter()
    server.call("compact_context", {
        "query": "benchmark task state",
        "session_id": session_id,
        "token_budget": 1024,
        "mode": "text",
    }, timeout=30)
    benchmark["timings_ms"]["compact_context_under_load"] = round((time.perf_counter() - t0) * 1000, 2)

    server.call("remember", {
        "content": "Decision: OPENCLAW_BENCH_DREAM review durable promotion path.",
        "session_id": session_id,
        "memory_type": "decision",
    }, timeout=20)

    t0 = time.perf_counter()
    export = parse_text_json(server.call("markdown_export", {
        "output_dir": str(projection_root),
        "session_id": session_id,
    }, timeout=30))
    benchmark["timings_ms"]["markdown_export"] = round((time.perf_counter() - t0) * 1000, 2)

    memory_path = Path(export["memory_md_path"])
    dreams_path = Path(export["dreams_path"])
    daily_path = Path(export["daily_note_paths"][0])
    memory_path.write_text(memory_path.read_text(encoding="utf-8") + "\n- OPENCLAW_BENCH_MEMORY_SYNC imported durable note.\n", encoding="utf-8")
    daily_path.write_text(daily_path.read_text(encoding="utf-8") + "\n- OPENCLAW_BENCH_DAILY_SYNC imported daily note.\n", encoding="utf-8")
    dreams_path.write_text(dreams_path.read_text(encoding="utf-8").replace("- [ ]", "- [x]", 1), encoding="utf-8")

    t0 = time.perf_counter()
    server.call("markdown_sync", {"root_dir": str(projection_root)}, timeout=60)
    benchmark["timings_ms"]["markdown_sync"] = round((time.perf_counter() - t0) * 1000, 2)

    server.close()

    restarted = MCPProc()
    try:
        restarted.start()
        t0 = time.perf_counter()
        restarted.call("session_resume", {"session_id": session_id}, timeout=20)
        benchmark["timings_ms"]["session_resume_after_restart"] = round((time.perf_counter() - t0) * 1000, 2)
        restarted.call("session_end", {"session_id": session_id}, timeout=20)

        t0 = time.perf_counter()
        restarted.call("corpus_search", {
            "query": "OPENCLAW_BENCH_0199" if doc_count >= 200 else f"OPENCLAW_BENCH_{doc_count - 1:04d}",
            "mode": "text",
            "topK": 8,
            "rebuild": True,
        }, timeout=30)
        benchmark["timings_ms"]["corpus_search_rebuild_true"] = round((time.perf_counter() - t0) * 1000, 2)

        t0 = time.perf_counter()
        restarted.call("corpus_search", {
            "query": "OPENCLAW_BENCH_0199" if doc_count >= 200 else f"OPENCLAW_BENCH_{doc_count - 1:04d}",
            "mode": "text",
            "topK": 8,
            "rebuild": False,
        }, timeout=30)
        benchmark["timings_ms"]["corpus_search_rebuild_false"] = round((time.perf_counter() - t0) * 1000, 2)
    finally:
        restarted.close()
finally:
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(benchmark, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    shutil.rmtree(tmp, ignore_errors=True)

if output_path is not None:
    print(f"Wrote benchmark report to {output_path}")
print(json.dumps(benchmark, indent=2, sort_keys=True))
PY
