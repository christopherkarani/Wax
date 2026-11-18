#!/usr/bin/env python3
"""Speed benchmark of local vector stores on the dataset from perf_prepare_data.py.

The counterpart of `wax-bench perf`: same vectors, queries, top-k and metrics.

  sqlite-vec      vec0 virtual table, exact scan (L2 on normalized vectors = cosine order)
  lancedb-flat    LanceDB table, no index (exact scan, dot)
  lancedb-ivfpq   LanceDB default index (create_index defaults: IVF_PQ), default nprobes
  chroma-hnsw     ChromaDB PersistentClient, HNSW with space "ip", default parameters
  faiss-flat      FAISS IndexFlatIP (exact), written with faiss.write_index
  faiss-hnsw      FAISS IndexHNSWFlat M=32, inner product, default efConstruction/efSearch
  usearch-hnsw    USearch Index, metric "ip", f32, default connectivity/expansion

Phases mirror wax-bench perf:
  ingest  build the store from the first N vectors with the library's batch insert API,
          persist it, and record throughput and on-disk size.
  query   in a fresh process: open the persisted store and run one query (cold start),
          then warm up and time each query one at a time from a single Python thread
          (single caller; a library may still use several threads inside one query).
          recall@10 is scored against exact inner-product ground truth.
Document stores (sqlite-vec, LanceDB, Chroma) also store and return the passage text, as
Wax does; FAISS and USearch hold vectors and ids only.

Usage:
  python -I perf_competitors.py --data DIR --n 10000 --system faiss-flat --phase all \
      --store-dir DIR --out result.json
"""

from __future__ import annotations

import argparse
import gc
import importlib.metadata
import json
import platform
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

TOP_K = 10


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


# MARK: - Systems
#
# Each system implements build(path, vectors, texts) and open(path) -> searcher, where
# searcher(query_vector) returns corpus row indices, best first.


class SqliteVec:
    name = "sqlite-vec"
    packages = ("sqlite-vec",)
    stores_text = True
    exact = True

    @staticmethod
    def _connect(path: Path) -> sqlite3.Connection:
        import sqlite_vec

        connection = sqlite3.connect(path)
        connection.enable_load_extension(True)
        sqlite_vec.load(connection)
        connection.enable_load_extension(False)
        return connection

    def build(self, path: Path, vectors: np.ndarray, texts: list[str]) -> dict:
        connection = self._connect(path / "store.db")
        connection.execute(f"CREATE VIRTUAL TABLE items USING vec0(embedding float[{vectors.shape[1]}], +text TEXT)")
        with connection:
            for start, end in batches(len(vectors), 10_000):
                connection.executemany(
                    "INSERT INTO items(rowid, embedding, text) VALUES (?, ?, ?)",
                    ((row, vectors[row].tobytes(), texts[row]) for row in range(start, end)),
                )
        connection.close()
        return {}

    def open(self, path: Path):
        connection = self._connect(path / "store.db")
        statement = "SELECT rowid, distance, text FROM items WHERE embedding MATCH ? AND k = ? ORDER BY distance"

        def search(query: np.ndarray) -> list[int]:
            return [row for row, _, _ in connection.execute(statement, (query.tobytes(), TOP_K))]

        return search


class LanceFlat:
    name = "lancedb-flat"
    packages = ("lancedb", "pylance", "pyarrow")
    stores_text = True
    exact = True

    def _table(self, path: Path, vectors: np.ndarray, texts: list[str]):
        import lancedb
        import pyarrow as pa

        dimensions = vectors.shape[1]
        table = pa.table(
            {
                "id": pa.array(np.arange(len(vectors), dtype=np.int64)),
                "text": pa.array(texts, type=pa.string()),
                "vector": pa.FixedSizeListArray.from_arrays(
                    pa.array(vectors.reshape(-1), type=pa.float32()), dimensions
                ),
            }
        )
        return lancedb.connect(path).create_table("items", table)

    def build(self, path: Path, vectors: np.ndarray, texts: list[str]) -> dict:
        self._table(path, vectors, texts)
        return {}

    def open(self, path: Path):
        import lancedb

        table = lancedb.connect(path).open_table("items")

        def search(query: np.ndarray) -> list[int]:
            result = (
                table.search(query, vector_column_name="vector")
                .distance_type("dot")
                .select(["id", "text"])
                .limit(TOP_K)
                .to_arrow()
            )
            return result.column("id").to_pylist()

        return search


class LanceIvfPq(LanceFlat):
    name = "lancedb-ivfpq"
    exact = False

    def build(self, path: Path, vectors: np.ndarray, texts: list[str]) -> dict:
        table = self._table(path, vectors, texts)
        start = time.perf_counter()
        table.create_index(metric="dot", vector_column_name="vector")
        return {"index_seconds": time.perf_counter() - start, "index": "IVF_PQ, create_index defaults"}


class ChromaHnsw:
    name = "chroma-hnsw"
    packages = ("chromadb",)
    stores_text = True
    exact = False

    @staticmethod
    def _client(path: Path):
        import chromadb
        from chromadb.config import Settings

        return chromadb.PersistentClient(path=str(path), settings=Settings(anonymized_telemetry=False))

    def build(self, path: Path, vectors: np.ndarray, texts: list[str]) -> dict:
        client = self._client(path)
        collection = client.create_collection("items", configuration={"hnsw": {"space": "ip"}})
        batch_size = client.get_max_batch_size()
        for start, end in batches(len(vectors), batch_size):
            collection.add(
                ids=[str(row) for row in range(start, end)],
                embeddings=vectors[start:end],
                documents=texts[start:end],
            )
        return {"batch_size": batch_size}

    def open(self, path: Path):
        collection = self._client(path).get_collection("items")

        def search(query: np.ndarray) -> list[int]:
            result = collection.query(query_embeddings=[query], n_results=TOP_K, include=["documents"])
            return [int(item) for item in result["ids"][0]]

        return search


class FaissFlat:
    name = "faiss-flat"
    packages = ("faiss-cpu",)
    stores_text = False
    exact = True

    def _index(self, dimensions: int):
        import faiss

        return faiss.IndexFlatIP(dimensions)

    def build(self, path: Path, vectors: np.ndarray, texts: list[str]) -> dict:
        import faiss

        index = self._index(vectors.shape[1])
        index.add(vectors)
        faiss.write_index(index, str(path / "index.faiss"))
        return {}

    def open(self, path: Path):
        import faiss

        index = faiss.read_index(str(path / "index.faiss"))

        def search(query: np.ndarray) -> list[int]:
            _, rows = index.search(query.reshape(1, -1), TOP_K)
            return [int(row) for row in rows[0] if row >= 0]

        return search


class FaissHnsw(FaissFlat):
    name = "faiss-hnsw"
    exact = False

    def _index(self, dimensions: int):
        import faiss

        return faiss.IndexHNSWFlat(dimensions, 32, faiss.METRIC_INNER_PRODUCT)


class USearchHnsw:
    name = "usearch-hnsw"
    packages = ("usearch",)
    stores_text = False
    exact = False

    def build(self, path: Path, vectors: np.ndarray, texts: list[str]) -> dict:
        from usearch.index import Index

        index = Index(ndim=vectors.shape[1], metric="ip", dtype="f32")
        index.add(np.arange(len(vectors), dtype=np.uint64), vectors)
        index.save(str(path / "index.usearch"))
        return {"connectivity": index.connectivity}

    def open(self, path: Path):
        from usearch.index import Index

        index = Index.restore(str(path / "index.usearch"))

        def search(query: np.ndarray) -> list[int]:
            return [int(key) for key in index.search(query, TOP_K).keys]

        return search


SYSTEMS = {
    system.name: system
    for system in [
        SqliteVec,
        LanceFlat,
        LanceIvfPq,
        ChromaHnsw,
        FaissFlat,
        FaissHnsw,
        USearchHnsw,
    ]
}


# MARK: - Phases


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
    truth = np.load(data / f"groundtruth-{n}.npy")[:query_count, :TOP_K]

    start = time.perf_counter()
    search = system.open(store)
    open_ms = (time.perf_counter() - start) * 1_000
    start = time.perf_counter()
    search(queries[0])
    first_ms = (time.perf_counter() - start) * 1_000

    for query in queries[:warmup]:
        search(query)
    latencies = []
    recall_sum = 0.0
    returned = 0
    for query, exact in zip(queries, truth):
        start = time.perf_counter()
        rows = search(query)
        latencies.append((time.perf_counter() - start) * 1_000)
        recall_sum += len(set(rows[:TOP_K]) & set(exact.tolist())) / TOP_K
        returned += len(rows)
    return {
        "open_ms": open_ms,
        "first_search_ms": first_ms,
        "warmup_queries": min(warmup, query_count),
        "modes": [
            {
                "mode": "vector",
                "latency": latency_summary(latencies),
                "recall_at_k": recall_sum / query_count,
                "mean_returned": returned / query_count,
            }
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--n", type=int, required=True)
    parser.add_argument("--system", choices=sorted(SYSTEMS), required=True)
    parser.add_argument("--phase", choices=["ingest", "query", "all"], default="all")
    parser.add_argument("--store-dir", type=Path, required=True, help="parent directory for the store")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--queries", type=int, default=1_000)
    parser.add_argument("--warmup", type=int, default=50)
    args = parser.parse_args()

    system = SYSTEMS[args.system]()
    store = args.store_dir / f"{system.name}-{args.n}"
    result = {
        "system": system.name,
        "n": args.n,
        "top_k": TOP_K,
        "queries": args.queries,
        "exact": system.exact,
        "stores_text": system.stores_text,
        "query_loop": "single caller, one query at a time",
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
        ]
        subprocess.run(command, check=True)
        query_path = args.out.with_suffix(".query.json")
        result["query"] = json.loads(query_path.read_text())["query"]
        query_path.unlink()
    elif args.phase == "query":
        result["query"] = run_query(system, args.data, args.n, store, args.queries, args.warmup)
        mode = result["query"]["modes"][0]
        print(
            f"{system.name} N={args.n} p50 {mode['latency']['p50_ms']:.3f} ms recall@{TOP_K} {mode['recall_at_k']:.4f}",
            file=sys.stderr,
        )
    if args.phase != "ingest":
        result["store_bytes"] = directory_bytes(store)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
