#!/usr/bin/env python3
"""Run prompts through Claude with `claude -p`, in parallel, resumably.

Input JSONL, one request per line:
  {"id": "...", "prompt": "...", "system": "optional system prompt"}
Output JSONL, one line per finished request:
  {"id": "...", "response": "...", "model": "...", "input_tokens": 0, ...}

Requests already present in the output without an error are skipped, so an
interrupted run continues where it stopped. Failed calls are retried with
exponential backoff; a request that still fails is written with "error" set
and retried on the next run.

Each call runs in an empty working directory with no settings, MCP servers,
tools or slash commands, so the model sees only the given system prompt and
user prompt.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

DEFAULT_SYSTEM = "You are a helpful assistant."


def call_claude(request: dict, model: str, workdir: str, timeout_s: int) -> dict:
    command = [
        "claude", "-p",
        "--model", model,
        "--system-prompt", request.get("system") or DEFAULT_SYSTEM,
        "--tools", "",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format", "json",
    ]
    completed = subprocess.run(
        command, input=request["prompt"], capture_output=True, text=True, cwd=workdir, timeout=timeout_s, check=False
    )
    if completed.returncode != 0 and not completed.stdout.strip():
        raise RuntimeError(f"claude exited {completed.returncode}: {completed.stderr.strip()[:300]}")
    payload = json.loads(completed.stdout)
    if payload.get("is_error"):
        raise RuntimeError(f"claude error: {str(payload.get('result'))[:300]}")
    usage = payload.get("usage", {})
    return {
        "id": request["id"],
        "response": payload.get("result", ""),
        "model": next(iter(payload.get("modelUsage", {}) or {model: None})),
        "input_tokens": usage.get("input_tokens", 0)
        + usage.get("cache_read_input_tokens", 0)
        + usage.get("cache_creation_input_tokens", 0),
        "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "duration_ms": payload.get("duration_ms"),
    }


def run_with_retries(request: dict, args: argparse.Namespace, workdir: str) -> dict:
    delay = 5.0
    last_error = ""
    for attempt in range(args.max_retries + 1):
        try:
            return call_claude(request, args.model, workdir, args.timeout)
        except (RuntimeError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
            last_error = str(error)
            if attempt < args.max_retries:
                time.sleep(delay)
                delay = min(delay * 2, 300)
    return {"id": request["id"], "error": last_error, "model": args.model}


def load_done(path: str) -> set:
    done = set()
    try:
        with open(path) as handle:
            for line in handle:
                entry = json.loads(line)
                if not entry.get("error"):
                    done.add(entry["id"])
    except FileNotFoundError:
        pass
    return done


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", required=True, help="e.g. claude-haiku-5-5")
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--max-retries", type=int, default=6)
    parser.add_argument("--timeout", type=int, default=600, help="seconds per call")
    args = parser.parse_args()

    done = load_done(args.output)
    with open(args.input) as handle:
        requests = [json.loads(line) for line in handle]
    pending = [request for request in requests if request["id"] not in done]
    print(f"{len(requests)} requests, {len(done)} done, {len(pending)} to run", file=sys.stderr)

    lock = threading.Lock()
    failures = 0
    with (
        tempfile.TemporaryDirectory(prefix="llm-run-") as workdir,
        open(args.output, "a") as out,
        ThreadPoolExecutor(max_workers=args.workers) as pool,
    ):
        futures = [pool.submit(run_with_retries, request, args, workdir) for request in pending]
        for index, future in enumerate(as_completed(futures), start=1):
            result = future.result()
            with lock:
                out.write(json.dumps(result) + "\n")
                out.flush()
                if result.get("error"):
                    failures += 1
            if index % 50 == 0 or index == len(pending):
                print(f"{index}/{len(pending)} done, {failures} failed", file=sys.stderr)
    if failures:
        sys.exit(f"{failures} requests failed; rerun to retry them")


if __name__ == "__main__":
    main()
