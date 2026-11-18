#!/usr/bin/env python3
"""Build the shared dataset for the Wax speed benchmark (`wax-bench perf`, perf_competitors.py).

Corpus:  MS MARCO passage collection, as published on Hugging Face in
         `sentence-transformers/msmarco-corpus` (config `passage`, shard 0 of 7).
         The first `--count` passages with distinct text and at most MAX_PASSAGE_TOKENS
         cl100k_base tokens, in collection order. Wax splits a text longer than 400 cl100k
         tokens into chunk frames (Sources/Wax/Ingest/TextChunker.swift), which would make it
         embed text other than the passage; the margin covers tokenizer differences. This
         drops about 3 passages in 100,000.
Queries: `--queries` MS MARCO dev queries (`sentence-transformers/msmarco-corpus`, config
         `queries`), restricted to the query ids in the dev qrels of `BeIR/msmarco-qrels`,
         sampled with a fixed seed. Queries are never part of the corpus.
Model:   sentence-transformers/all-MiniLM-L6-v2, L2-normalized, float32, 384 dimensions.

Output directory layout (everything a run needs; prefixes of the corpus are the N-subsets):
  corpus.npy        float32 [count, 384]
  corpus.txt        one passage per line (whitespace collapsed, so no embedded newlines)
  queries.npy       float32 [queries, 384]
  queries.txt       one query per line
  groundtruth-<N>.npy  int32 [queries, 10]: exact top-10 corpus rows by inner product
                    over the first N rows, for each N in --sizes
  meta.json         sources, model, counts, versions

Usage:
  python -I perf_prepare_data.py --download-dir DIR --out DIR [--count 1000000] [--device mps]
Embedding is checkpointed in blocks under <out>/blocks, named by a hash of their texts, so an
interrupted run resumes and a changed selection never reuses stale vectors.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import random
import time
from pathlib import Path

import numpy as np

CORPUS_REPO = "sentence-transformers/msmarco-corpus"
CORPUS_FILE = "passage/train-00000-of-00007.parquet"
QUERIES_FILE = "queries/train-00000-of-00001.parquet"
QRELS_REPO = "BeIR/msmarco-qrels"
QRELS_FILE = "dev.tsv"
MODEL = "sentence-transformers/all-MiniLM-L6-v2"
DIMENSIONS = 384
TOP_K = 10
BLOCK = 50_000
MAX_PASSAGE_TOKENS = 384


def collapse(text: str) -> str:
    return " ".join(text.split())


def download(download_dir: Path) -> tuple[Path, Path, Path]:
    from huggingface_hub import hf_hub_download

    def fetch(repo: str, name: str) -> Path:
        return Path(hf_hub_download(repo, name, repo_type="dataset", local_dir=download_dir))

    return fetch(CORPUS_REPO, CORPUS_FILE), fetch(CORPUS_REPO, QUERIES_FILE), fetch(QRELS_REPO, QRELS_FILE)


def load_corpus(path: Path, count: int) -> tuple[list[int], list[str]]:
    import pyarrow.parquet as pq
    import tiktoken

    encoding = tiktoken.get_encoding("cl100k_base")
    pids: list[int] = []
    texts: list[str] = []
    seen: set[str] = set()
    for batch in pq.ParquetFile(path).iter_batches(batch_size=100_000, columns=["pid", "text"]):
        candidates = [
            (pid, collapse(raw or ""))
            for pid, raw in zip(batch.column("pid").to_pylist(), batch.column("text").to_pylist())
        ]
        lengths = [len(tokens) for tokens in encoding.encode_ordinary_batch([text for _, text in candidates])]
        for (pid, text), length in zip(candidates, lengths):
            if not text or text in seen or length > MAX_PASSAGE_TOKENS:
                continue
            seen.add(text)
            pids.append(pid)
            texts.append(text)
            if len(texts) == count:
                return pids, texts
    raise SystemExit(f"corpus shard has only {len(texts)} distinct passages, need {count}")


def load_queries(queries_path: Path, qrels_path: Path, count: int, seed: int) -> tuple[list[int], list[str]]:
    import pyarrow.parquet as pq

    with qrels_path.open() as handle:
        next(handle)  # header
        dev_ids = sorted({int(line.split("\t", 1)[0]) for line in handle if line.strip()})
    table = pq.read_table(queries_path, columns=["qid", "text"])
    by_id = dict(zip(table.column("qid").to_pylist(), table.column("text").to_pylist()))
    candidates = [qid for qid in dev_ids if qid in by_id and collapse(by_id[qid])]
    if len(candidates) < count:
        raise SystemExit(f"only {len(candidates)} dev queries available, need {count}")
    chosen = sorted(random.Random(seed).sample(candidates, count))
    return chosen, [collapse(by_id[qid]) for qid in chosen]


def embed(texts: list[str], model, batch_size: int) -> np.ndarray:
    vectors = model.encode(
        texts,
        batch_size=batch_size,
        normalize_embeddings=True,
        convert_to_numpy=True,
        show_progress_bar=False,
    )
    return np.ascontiguousarray(vectors, dtype=np.float32)


def embed_corpus(texts: list[str], model, batch_size: int, blocks_dir: Path) -> np.ndarray:
    blocks_dir.mkdir(parents=True, exist_ok=True)
    parts = []
    start_time = time.time()
    for start in range(0, len(texts), BLOCK):
        digest = hashlib.sha256("\n".join(texts[start : start + BLOCK]).encode("utf-8")).hexdigest()[:16]
        block_path = blocks_dir / f"block-{start:09d}-{digest}.npy"
        expected = min(BLOCK, len(texts) - start)
        if block_path.exists():
            block = np.load(block_path)
            if block.shape == (expected, DIMENSIONS):
                parts.append(block)
                continue
        block = embed(texts[start : start + BLOCK], model, batch_size)
        np.save(block_path, block)
        parts.append(block)
        done = start + expected
        rate = done / max(time.time() - start_time, 1e-9)
        print(f"embedded {done}/{len(texts)} ({rate:.0f}/s in this run)", flush=True)
    return np.concatenate(parts)


def ground_truth(corpus: np.ndarray, queries: np.ndarray, n: int) -> np.ndarray:
    """Exact top-K rows by inner product (= cosine; vectors are normalized), best first.
    Ties break by lower row index, the order a stable sort gives."""
    result = np.empty((len(queries), TOP_K), dtype=np.int32)
    sub = corpus[:n]
    for start in range(0, len(queries), 100):
        scores = queries[start : start + 100] @ sub.T
        top = np.argpartition(-scores, TOP_K - 1, axis=1)[:, :TOP_K]
        for row, candidates in enumerate(top):
            order = sorted(candidates, key=lambda c: (-scores[row, c], c))
            result[start + row] = order
    return result


def write_lines(path: Path, lines: list[str]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(line)
            handle.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--download-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--count", type=int, default=1_000_000)
    parser.add_argument("--queries", type=int, default=1_000)
    parser.add_argument("--sizes", default="10000,100000,1000000")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--batch-size", type=int, default=256)
    args = parser.parse_args()

    sizes = sorted({int(size) for size in args.sizes.split(",") if int(size) <= args.count})
    args.out.mkdir(parents=True, exist_ok=True)
    corpus_path, queries_path, qrels_path = download(args.download_dir)

    pids, corpus_texts = load_corpus(corpus_path, args.count)
    qids, query_texts = load_queries(queries_path, qrels_path, args.queries, args.seed)
    write_lines(args.out / "corpus.txt", corpus_texts)
    write_lines(args.out / "queries.txt", query_texts)
    np.save(args.out / "corpus-pids.npy", np.asarray(pids, dtype=np.int64))
    np.save(args.out / "queries-qids.npy", np.asarray(qids, dtype=np.int64))

    import sentence_transformers
    import torch
    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(MODEL, device=args.device)
    started = time.time()
    query_vectors = embed(query_texts, model, args.batch_size)
    corpus_vectors = embed_corpus(corpus_texts, model, args.batch_size, args.out / "blocks")
    embed_seconds = time.time() - started
    np.save(args.out / "queries.npy", query_vectors)
    np.save(args.out / "corpus.npy", corpus_vectors)

    for n in sizes:
        np.save(args.out / f"groundtruth-{n}.npy", ground_truth(corpus_vectors, query_vectors, n))
        print(f"ground truth for N={n} written", flush=True)

    meta = {
        "corpus": {
            "repo": CORPUS_REPO,
            "file": CORPUS_FILE,
            "count": len(corpus_texts),
            "selection": "first passages with distinct whitespace-collapsed text and "
            f"<= {MAX_PASSAGE_TOKENS} cl100k_base tokens, collection order",
        },
        "queries": {
            "repo": CORPUS_REPO,
            "file": QUERIES_FILE,
            "qrels": f"{QRELS_REPO}/{QRELS_FILE}",
            "count": len(query_texts),
            "selection": f"random sample of dev query ids, seed {args.seed}",
        },
        "model": MODEL,
        "dimensions": DIMENSIONS,
        "normalized": True,
        "ground_truth": {"metric": "inner product", "top_k": TOP_K, "sizes": sizes},
        "embedding": {"device": args.device, "seconds": round(embed_seconds, 1)},
        "versions": {
            "sentence_transformers": sentence_transformers.__version__,
            "torch": torch.__version__,
            "numpy": np.__version__,
            "tiktoken": importlib.metadata.version("tiktoken"),
        },
    }
    (args.out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
