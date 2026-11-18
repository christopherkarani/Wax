#!/usr/bin/env python3
"""Print a Markdown table from the JSON results of `wax-bench perf` and perf_competitors.py.

Usage: python -I perf_summarize.py RESULTS_DIR
Wax results come in two files per N (wax-<N>-ingest.json, wax-<N>-query.json); competitor
results are one file per system and N.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path


def load(results: Path) -> dict[tuple[str, int], dict]:
    merged: dict[tuple[str, int], dict] = defaultdict(dict)
    for path in sorted(results.glob("*.json")):
        data = json.loads(path.read_text())
        if "system" not in data or "n" not in data:
            continue
        entry = merged[(data["system"], data["n"])]
        for key, value in data.items():
            if value is not None:
                entry[key] = value
    return merged


def row(system: str, n: int, data: dict) -> list[str]:
    ingest = data.get("ingest") or {}
    query = data.get("query") or {}
    size = query.get("store_bytes") or data.get("store_bytes") or ingest.get("store_bytes")
    cells = [
        system,
        f"{n:,}",
        f"{ingest['docs_per_second']:,.0f}" if ingest else "",
        f"{size / 1e6:,.1f}" if size else "",
        f"{query['open_ms'] + query['first_search_ms']:,.1f}" if query else "",
    ]
    modes = {mode["mode"]: mode for mode in query.get("modes", [])}
    for name in ("vector", "hybrid"):
        mode = modes.get(name)
        if mode:
            latency = mode["latency"]
            cells.append(f"{latency['p50_ms']:.3f} / {latency['p95_ms']:.3f} / {latency['p99_ms']:.3f}")
            cells.append(f"{mode['recall_at_k']:.4f}")
        else:
            cells.extend(["", ""])
    return cells


def main() -> None:
    results = Path(sys.argv[1])
    header = [
        "system",
        "N",
        "ingest docs/s",
        "disk MB",
        "cold open + 1st query ms",
        "vector p50/p95/p99 ms",
        "vector recall@10",
        "hybrid p50/p95/p99 ms",
        "hybrid overlap@10",
    ]
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for (system, n), data in sorted(
        load(results).items(), key=lambda item: (item[0][1], item[0][0] != "wax", item[0][0])
    ):
        print("| " + " | ".join(row(system, n, data)) + " |")


if __name__ == "__main__":
    main()
