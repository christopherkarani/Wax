#!/usr/bin/env python3
"""memvid retriever for the LongMemEval and LoCoMo retrieval jobs.

Reads the same jobs files as longmemeval_baselines.py and `wax-bench retrieve`
({"qid", "query", "docs"} or {"queries": [...], "docs": [...]}) and writes the same
ranked JSONL ({"qid", "ranked": [doc ids, best first], "search_ms"}), so
longmemeval_score_retrieval.py and `locomo.py recall` score it unchanged.

Each jobs line gets its own fresh .mv2 file (one per LongMemEval question, one per
LoCoMo conversation), as Wax does. Every doc is one put_many request; the store is
sealed, then each query runs in every requested mode against that one store:

  vector   find(mode="sem", query_embedding=...)
  hybrid   find(mode="hybrid", query text + query_embedding)
  text     find(mode="lex") with the raw query (memvid's default lexical behaviour)
  text-or  find(mode="lex") with the query's word tokens joined by " OR "
  hybrid-or  find(mode="hybrid") with the OR-joined text + query_embedding
Multi-word lexical queries behave as AND in 2.0.160 (the docs say OR), so the raw
query often matches nothing; the -or modes show what the lexical index can do.

Embedders:
  minilm   precomputed all-MiniLM-L6-v2 vectors: docs from the baselines' vector cache
           (sha1(text) -> vector, longmemeval_baselines.py --cache-dir), queries from
           memvid_encode_queries.py. Same vectors as the Wax MiniLM and baseline-minilm runs.
  builtin  memvid's own local embedder (put_many opts enable_embedding=True,
           embedding_model=bge-small; queries via query_embedding_model=bge-small).

skip_sync=True is passed to put_many: it only skips fsync and does not change rankings.

Usage:
  python -I retrieve_memvid.py --jobs lme_s_session.jobs.jsonl --embedder minilm \
      --doc-vectors sentence-transformers_all-MiniLM-L6-v2.npz --query-vectors q.npz \
      --modes vector,hybrid,text --out-prefix runs/memvid-minilm-session --store-dir DIR
"""
from __future__ import annotations

import os

os.environ["MEMVID_TELEMETRY"] = "0"

import argparse
import hashlib
import json
import re
import shutil
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

URI = "mv2://doc/"
MAX_K = 300
PUT_BATCH = 10
MODES = {"vector": "sem", "hybrid": "hybrid", "hybrid-or": "hybrid", "text": "lex", "text-or": "lex"}

_doc_vectors: dict[str, np.ndarray] = {}
_query_vectors: dict[str, np.ndarray] = {}
_settings: dict = {}


def text_key(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


QUERY_OPERATORS = {"and", "or", "not"}


def or_query(query: str) -> str:
    # The lexical parser treats and/or/not as operators in any case, so drop them.
    tokens = [token for token in re.findall(r"\w+", query) if token.lower() not in QUERY_OPERATORS]
    return " OR ".join(tokens) if tokens else query


def init_worker(settings: dict) -> None:
    _settings.update(settings)
    if settings["embedder"] == "minilm":
        data = np.load(settings["doc_vectors"])
        _doc_vectors.update(zip(data["keys"].tolist(), data["vectors"]))
        queries = np.load(settings["query_vectors"])
        _query_vectors.update(zip(queries["qids"].tolist(), queries["vectors"]))


def build_store(path: Path, docs: list[dict]):
    import memvid_sdk

    memory = memvid_sdk.create(str(path), enable_vec=True, enable_lex=True)
    requests = [
        {"title": doc["id"], "label": "doc", "text": doc["text"], "uri": f"{URI}{index}"}
        for index, doc in enumerate(docs)
    ]
    # Ten docs per put_many call: memvid-sdk 2.0.160 leaves most vectors of a large
    # put_many batch unreachable by vector search (see perf_memvid.py).
    for start in range(0, len(requests), PUT_BATCH):
        batch = requests[start : start + PUT_BATCH]
        if _settings["embedder"] == "minilm":
            vectors = [_doc_vectors[text_key(doc["text"])].tolist() for doc in docs[start : start + PUT_BATCH]]
            memory.put_many(batch, embeddings=vectors, opts={"enable_embedding": False, "skip_sync": True})
        else:
            memory.put_many(
                batch,
                opts={"enable_embedding": True, "embedding_model": "bge-small", "skip_sync": True},
            )
    memory.seal()
    return memory


def search(memory, mode: str, qid: str, query: str, k: int) -> tuple[list[int], str | None]:
    kwargs = {"k": k, "mode": MODES[mode]}
    if mode in ("vector", "hybrid", "hybrid-or"):
        if _settings["embedder"] == "minilm":
            kwargs["query_embedding"] = _query_vectors[qid].tolist()
        else:
            kwargs["query_embedding_model"] = "bge-small"
    text = or_query(query) if mode.endswith("-or") else query
    import memvid_sdk

    try:
        result = memory.find(text, **kwargs)
    except memvid_sdk.MemvidError as error:
        # 2.0.160 raises LexIndexDisabledError (MV004) for some lexical queries; scored as empty.
        return [], f"error:{type(error).__name__}"
    rows: list[int] = []
    seen: set[int] = set()
    for hit in result["hits"]:
        # Long docs are split into page frames whose uri is "<doc uri>#page-N".
        row = int(hit["uri"][len(URI) :].split("#", 1)[0])
        if row not in seen:
            seen.add(row)
            rows.append(row)
    return rows, result.get("engine")


def run_job(args: tuple[int, dict]) -> dict:
    index, entry = args
    docs = entry["docs"]
    queries = entry.get("queries", [entry])
    path = Path(_settings["store_dir"]) / f"job-{index}.mv2"
    if path.exists():
        path.unlink()
    started = time.perf_counter()
    memory = build_store(path, docs)
    ingest_s = time.perf_counter() - started
    k = min(len(docs), MAX_K)
    out: dict[str, list] = {mode: [] for mode in _settings["modes"]}
    engines: dict[str, int] = {}
    for query in queries:
        for mode in _settings["modes"]:
            started = time.perf_counter()
            rows, engine = search(memory, mode, query["qid"], query["query"], k)
            search_ms = (time.perf_counter() - started) * 1_000
            engines[f"{mode}:{engine}"] = engines.get(f"{mode}:{engine}", 0) + 1
            out[mode].append({"qid": query["qid"], "ranked": [docs[row]["id"] for row in rows], "search_ms": search_ms})
    memory.close()
    store_bytes = sum(p.stat().st_size for p in path.parent.glob(f"{path.stem}.*") if p.is_file())
    for extra in path.parent.glob(f"{path.stem}.*"):
        if extra.is_dir():
            shutil.rmtree(extra)
        else:
            extra.unlink()
    return {"index": index, "out": out, "engines": engines, "ingest_s": ingest_s, "docs": len(docs), "bytes": store_bytes}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jobs", required=True)
    parser.add_argument("--embedder", choices=["minilm", "builtin"], required=True)
    parser.add_argument("--doc-vectors")
    parser.add_argument("--query-vectors")
    parser.add_argument("--modes", default="vector,hybrid,hybrid-or,text,text-or")
    parser.add_argument("--out-prefix", required=True, help="writes <prefix>-<mode>.ranked.jsonl")
    parser.add_argument("--store-dir", required=True)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="only the first N jobs lines")
    args = parser.parse_args()
    modes = args.modes.split(",")
    for mode in modes:
        if mode not in MODES:
            raise SystemExit(f"unknown mode {mode}")
    if args.embedder == "minilm" and not (args.doc_vectors and args.query_vectors):
        raise SystemExit("--embedder minilm needs --doc-vectors and --query-vectors")
    os.makedirs(args.store_dir, exist_ok=True)

    entries = []
    with open(args.jobs) as handle:
        for line in handle:
            if line.strip():
                entries.append(json.loads(line))
            if args.limit and len(entries) >= args.limit:
                break
    settings = {
        "embedder": args.embedder,
        "doc_vectors": args.doc_vectors,
        "query_vectors": args.query_vectors,
        "modes": modes,
        "store_dir": args.store_dir,
    }
    started = time.time()
    results = [None] * len(entries)
    engines: dict[str, int] = {}
    ingest = []
    with ProcessPoolExecutor(max_workers=args.workers, initializer=init_worker, initargs=(settings,)) as pool:
        for done, result in enumerate(pool.map(run_job, enumerate(entries)), start=1):
            results[result["index"]] = result
            for key, value in result["engines"].items():
                engines[key] = engines.get(key, 0) + value
            ingest.append((result["docs"], result["ingest_s"], result["bytes"]))
            if done % 25 == 0 or done == len(entries):
                print(f"  {done}/{len(entries)} jobs, {time.time() - started:.0f}s", file=sys.stderr, flush=True)
    for mode in modes:
        path = f"{args.out_prefix}-{mode}.ranked.jsonl"
        with open(path, "w") as out:
            for result in results:
                for row in result["out"][mode]:
                    out.write(json.dumps(row) + "\n")
        print(f"wrote {path}", file=sys.stderr)
    summary = {
        "jobs": len(entries),
        "embedder": args.embedder,
        "modes": modes,
        "engines": engines,
        "docs": sum(d for d, _, _ in ingest),
        "ingest_seconds_total": sum(s for _, s, _ in ingest),
        "store_bytes_total": sum(b for _, _, b in ingest),
        "wall_seconds": time.time() - started,
    }
    with open(f"{args.out_prefix}.run.json", "w") as handle:
        json.dump(summary, handle, indent=2)
    print(json.dumps(summary), file=sys.stderr)


if __name__ == "__main__":
    main()
