#!/usr/bin/env python3
"""Speed benchmark of memvid (memvid-sdk, Rust core, one .mv2 file) on the perf_prepare_data.py dataset.

Same CLI, phases and output JSON as Benchmarks/scripts/perf_competitors.py, so the result
drops into the same summary table.

  memvid          memvid_sdk.create(enable_vec=True, enable_lex=True); put_many() with the
                  precomputed all-MiniLM-L6-v2 vectors (embeddings=..., so memvid's own
                  embedder is not run), text and a per-row uri; seal() persists the file.
                  Queries pass the precomputed query vector as query_embedding.

Query modes (find(mode=...)):
  vector  mode="sem" with query_embedding (memvid's HNSW vector index)
  hybrid  mode="hybrid" with query text + query_embedding (BM25 + vector fusion in core)
  text    mode="lex" with the raw query text (Tantivy BM25)
recall@10 is scored against exact inner-product ground truth for every mode, as wax-bench
perf does (for hybrid and text it is overlap with the vector ground truth, not quality).

Known issue (memvid-sdk 2.0.160, macOS arm64): vectors passed to one large put_many call
are stored (vec_index_bytes grows) but most of them are unreachable by vector search
(1,000 docs in one call: 495 never returned for their own vector; 10,000 in one call:
recall@10 = 0). Batches of 10 docs lose none. --batch-size picks the call size.

Telemetry: memvid_sdk sends anonymous usage events to memvid.com unless MEMVID_TELEMETRY=0;
this script sets it before importing the SDK.

Usage:
  python -I perf_memvid.py --data DIR --n 10000 --system memvid --phase all \
      --store-dir DIR --out result.json
"""

from __future__ import annotations

import os

os.environ["MEMVID_TELEMETRY"] = "0"

import argparse
import gc
import importlib.metadata
import json
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

TOP_K = 10
URI_PREFIX = "mv2://d/"
MODES = {"vector": "sem", "hybrid": "hybrid", "text": "lex"}


def package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def directory_bytes(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(entry.stat().st_size for entry in path.rglob("*") if entry.is_file())


def batches(count: int, size: int):
    for start in range(0, count, size):
        yield start, min(start + size, count)


class Memvid:
    name = "memvid"
    packages = ("memvid-sdk",)
    stores_text = True
    exact = False
    batch_size = 10_000

    def __init__(self, batch_size: int = 10_000) -> None:
        self.batch_size = batch_size

    def build(self, path: Path, vectors: np.ndarray, texts: list[str]) -> dict:
        import memvid_sdk

        memory = memvid_sdk.create(str(path / "store.mv2"), enable_vec=True, enable_lex=True)
        for start, end in batches(len(vectors), self.batch_size):
            memory.put_many(
                [
                    {"title": str(row), "label": "passage", "text": texts[row], "uri": f"{URI_PREFIX}{row}"}
                    for row in range(start, end)
                ],
                embeddings=vectors[start:end].tolist(),
                opts={"enable_embedding": False},
            )
        memory.seal()
        stats = memory.stats()
        memory.close()
        return {
            "batch_size": self.batch_size,
            "api": "put_many(embeddings=precomputed MiniLM), seal()",
            "tier": stats.get("tier"),
            "capacity_bytes": stats.get("capacity_bytes"),
            "frame_count": stats.get("frame_count"),
            "index_bytes": {
                key: stats.get(key) for key in ("lex_index_bytes", "vec_index_bytes", "time_index_bytes", "wal_bytes")
            },
        }

    def open(self, path: Path):
        import memvid_sdk

        memory = memvid_sdk.use("basic", str(path / "store.mv2"), mode="open", enable_vec=True, read_only=True)
        engines: dict[str, int] = {}

        def search(query: np.ndarray, text: str, mode: str = "vector") -> list[int]:
            try:
                result = memory.find(
                    text,
                    k=TOP_K,
                    mode=MODES[mode],
                    query_embedding=None if mode == "text" else query.tolist(),
                )
            except memvid_sdk.MemvidError as error:
                # 2.0.160 raises LexIndexDisabledError (MV004) for some lexical queries,
                # e.g. "computing definition"; counted and scored as an empty result.
                key = f"{mode}:error:{type(error).__name__}"
                engines[key] = engines.get(key, 0) + 1
                return []
            engines[f"{mode}:{result.get('engine')}"] = engines.get(f"{mode}:{result.get('engine')}", 0) + 1
            rows: list[int] = []
            for hit in result["hits"]:
                row = int(hit["uri"][len(URI_PREFIX) :])
                if row not in rows:
                    rows.append(row)
            return rows

        search.engines = engines
        return search


SYSTEMS = {Memvid.name: Memvid}


def latency_summary(samples_ms: list[float]) -> dict:
    ordered = sorted(samples_ms)

    def percentile(fraction: float) -> float:
        rank = int(np.ceil(fraction * len(ordered))) - 1
        return ordered[min(max(rank, 0), len(ordered) - 1)]

    return {
        "count": len(ordered),
        "mean_ms": float(np.mean(ordered)),
        "p50_ms": percentile(0.50),
        "p95_ms": percentile(0.95),
        "p99_ms": percentile(0.99),
        "max_ms": ordered[-1],
    }


def load_lines(path: Path, limit: int) -> list[str]:
    with path.open(encoding="utf-8") as handle:
        lines = [line.rstrip("\n") for _, line in zip(range(limit), handle)]
    if len(lines) != limit:
        raise SystemExit(f"{path} has {len(lines)} lines, need {limit}")
    return lines


def run_ingest(system, data: Path, n: int, store: Path) -> dict:
    vectors = np.ascontiguousarray(np.load(data / "corpus.npy", mmap_mode="r")[:n], dtype=np.float32)
    texts = load_lines(data / "corpus.txt", n) if system.stores_text else []
    if store.exists():
        shutil.rmtree(store)
    store.mkdir(parents=True)
    gc.collect()
    start = time.perf_counter()
    details = system.build(store, vectors, texts)
    seconds = time.perf_counter() - start
    return {
        "docs": n,
        "seconds": seconds,
        "docs_per_second": n / seconds,
        "store_bytes": directory_bytes(store),
        "api": "library batch insert",
        **details,
    }


def run_query(system, data: Path, n: int, store: Path, query_count: int, warmup: int) -> dict:
    queries = np.ascontiguousarray(np.load(data / "queries.npy")[:query_count], dtype=np.float32)
    texts = load_lines(data / "queries.txt", query_count)
    truth = np.load(data / f"groundtruth-{n}.npy")[:query_count, :TOP_K]

    start = time.perf_counter()
    search = system.open(store)
    open_ms = (time.perf_counter() - start) * 1_000
    start = time.perf_counter()
    search(queries[0], texts[0], "vector")
    first_ms = (time.perf_counter() - start) * 1_000

    modes = []
    for mode in MODES:
        for query, text in zip(queries[:warmup], texts[:warmup]):
            search(query, text, mode)
        search.engines.clear()
        latencies = []
        recall_sum = 0.0
        returned = 0
        for query, text, exact in zip(queries, texts, truth):
            start = time.perf_counter()
            rows = search(query, text, mode)
            latencies.append((time.perf_counter() - start) * 1_000)
            recall_sum += len(set(rows[:TOP_K]) & set(exact.tolist())) / TOP_K
            returned += len(rows)
        modes.append(
            {
                "mode": mode,
                "memvid_mode": MODES[mode],
                "effective_modes": dict(search.engines),
                "latency": latency_summary(latencies),
                "recall_at_k": recall_sum / query_count,
                "mean_returned": returned / query_count,
            }
        )
    return {
        "open_ms": open_ms,
        "first_search_ms": first_ms,
        "first_search_mode": "vector",
        "warmup_queries": min(warmup, query_count),
        "modes": modes,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--n", type=int, required=True)
    parser.add_argument("--system", choices=sorted(SYSTEMS), default="memvid")
    parser.add_argument("--phase", choices=["ingest", "query", "all"], default="all")
    parser.add_argument("--store-dir", type=Path, required=True, help="parent directory for the store")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--queries", type=int, default=1_000)
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument(
        "--batch-size",
        type=int,
        default=10_000,
        help="docs per put_many call; memvid 2.0.160 leaves most vectors of a large batch unreachable",
    )
    args = parser.parse_args()

    system = SYSTEMS[args.system](args.batch_size)
    store = args.store_dir / f"{system.name}-{args.n}-b{args.batch_size}"
    result = {
        "system": system.name,
        "n": args.n,
        "top_k": TOP_K,
        "queries": args.queries,
        "exact": system.exact,
        "stores_text": system.stores_text,
        "query_loop": "single caller, one query at a time",
        "put_many_batch_size": args.batch_size,
        "uptime": subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip(),
        "embedder": "precomputed all-MiniLM-L6-v2 (memvid's own embedder not used)",
        "versions": {name: package_version(name) for name in system.packages}
        | {"python": platform.python_version(), "numpy": np.__version__},
    }
    if args.phase in ("ingest", "all"):
        result["ingest"] = run_ingest(system, args.data, args.n, store)
        print(f"{system.name} N={args.n} ingest {result['ingest']['docs_per_second']:.0f} docs/s", file=sys.stderr)
    if args.phase == "all":
        # Query in a fresh process, so the cold open does not reuse the ingest's objects.
        command = [
            sys.executable,
            "-I",
            __file__,
            "--data",
            str(args.data),
            "--n",
            str(args.n),
            "--system",
            args.system,
            "--phase",
            "query",
            "--store-dir",
            str(args.store_dir),
            "--out",
            str(args.out.with_suffix(".query.json")),
            "--queries",
            str(args.queries),
            "--warmup",
            str(args.warmup),
            "--batch-size",
            str(args.batch_size),
        ]
        subprocess.run(command, check=True)
        query_path = args.out.with_suffix(".query.json")
        result["query"] = json.loads(query_path.read_text())["query"]
        query_path.unlink()
    elif args.phase == "query":
        result["query"] = run_query(system, args.data, args.n, store, args.queries, args.warmup)
        for mode in result["query"]["modes"]:
            print(
                f"{system.name} N={args.n} {mode['mode']} p50 {mode['latency']['p50_ms']:.3f} ms "
                f"recall@{TOP_K} {mode['recall_at_k']:.4f}",
                file=sys.stderr,
            )
    if args.phase != "ingest":
        result["uptime_after"] = subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()
        result["store_bytes"] = directory_bytes(store)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
