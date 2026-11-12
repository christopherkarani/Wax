#!/usr/bin/env python3
"""Reference retrieval baselines for LongMemEval and LoCoMo.

Each job is a private haystack: the retriever ranks every doc of that job against its
query and nothing else. A jobs line is either one query (LongMemEval:
{"qid", "query", "docs": [{"id", "text"}]}) or several queries sharing one haystack
(LoCoMo, one line per conversation: {"queries": [{"qid", "query"}], "docs": [...]}).
Output is one JSON object per query: {"qid": ..., "ranked": [all doc ids, best first]},
which longmemeval_score_retrieval.py and `locomo.py recall` read.

Retrievers mirror LongMemEval src/retrieval/run_retrieval.py (flat retrieval, K = V):

  bm25        flat-bm25: rank_bm25.BM25Okapi with default parameters over
              text.split(" ") (no lowercasing, no stemming); the query is split the
              same way; ranking is np.argsort(scores)[::-1].
  bm25norm    Not in the official repo: bm25 over lowercased text with punctuation
              replaced by spaces, split on whitespace (same for the query). Useful for
              short, punctuation-heavy turns such as LoCoMo's.
  contriever  flat-contriever: facebook/contriever, mean pooling over the attention
              mask, tokenizer truncation at 512, unnormalised dot product.
  stella      flat-stella: dunzhang/stella_en_1.5B_v5 (or --stella-model, e.g.
              dunzhang/stella_en_400M_v5), mean pooling, the 1024-d 2_Dense_1024
              projection, L2 normalisation, max_length 512. Like the official code,
              the query gets no instruction prompt.
  minilm      sentence-transformers/all-MiniLM-L6-v2 through SentenceTransformer
              (its default 256-token truncation), normalised, cosine. Not in the
              official repo; it is the embedding model Wax uses.

Haystack docs repeat heavily across questions, so the dense retrievers encode each
distinct text once (keyed by SHA-1) and keep the vectors in --cache-dir between runs.
Batching and padding can move scores in the last float digits compared with the
official per-question encoding; rankings are otherwise identical.

Usage:
  longmemeval_baselines.py --jobs lme_s_session.jobs.jsonl --retriever bm25 \
      --out baseline-bm25-session.ranked.jsonl [--cache-dir DIR] [--device mps]
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time

import numpy as np

MINILM = "sentence-transformers/all-MiniLM-L6-v2"
CONTRIEVER = "facebook/contriever"
STELLA = "dunzhang/stella_en_1.5B_v5"


def text_key(text):
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def load_jobs(path, limit):
    """One job per query; queries of a multi-query line share that line's docs list."""
    jobs = []
    with open(path) as handle:
        for line in handle:
            if not line.strip():
                continue
            entry = json.loads(line)
            for query in entry.get("queries", [entry]):
                jobs.append({"qid": query["qid"], "query": query["query"], "docs": entry["docs"]})
            if limit and len(jobs) >= limit:
                return jobs[:limit]
    return jobs


def official_tokens(text):
    return text.split(" ")


def normalized_tokens(text):
    return re.sub(r"[^\w\s]", " ", text.lower()).split()


def pick_device(requested):
    import torch

    if requested != "auto":
        return torch.device(requested)
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def bm25_rankings(jobs, tokenize):
    """Official flat-bm25 tie order; the index is built once per shared docs list."""
    from rank_bm25 import BM25Okapi

    index, index_docs = None, None
    for job in jobs:
        if job["docs"] is not index_docs:
            index_docs = job["docs"]
            index = BM25Okapi([tokenize(doc["text"]) for doc in index_docs])
        yield job, np.argsort(index.get_scores(tokenize(job["query"])))[::-1]


class Encoder:
    """Turns texts into vectors; similarity is a plain dot product of the outputs."""

    def __init__(self, name, device, batch_size, stella_model):
        import torch

        self.torch = torch
        self.name = name
        self.device = device
        self.batch_size = batch_size
        if name == "minilm":
            from sentence_transformers import SentenceTransformer

            self.model = SentenceTransformer(MINILM, device=str(device))
            self.model_id = MINILM
        elif name == "contriever":
            from transformers import AutoModel, AutoTokenizer

            self.tokenizer = AutoTokenizer.from_pretrained(CONTRIEVER)
            self.model = AutoModel.from_pretrained(CONTRIEVER).to(device).eval()
            self.model_id = CONTRIEVER
        elif name == "stella":
            self._load_stella(stella_model)
        else:
            raise ValueError(name)

    def _load_stella(self, model_id):
        from huggingface_hub import snapshot_download
        from transformers import AutoModel, AutoTokenizer

        torch = self.torch
        # Skip the ONNX export and the other projection sizes; only 2_Dense_1024 is used.
        model_dir = snapshot_download(
            model_id,
            allow_patterns=["*.json", "*.txt", "*.py", "model.safetensors", "2_Dense_1024/*"],
        )
        overrides = {}
        if "400M" in model_id:
            # The 400M model's remote code defaults to xformers kernels, which need CUDA.
            overrides = {"use_memory_efficient_attention": False, "unpad_inputs": False}
        self.tokenizer = AutoTokenizer.from_pretrained(model_dir, trust_remote_code=True)
        self.model = AutoModel.from_pretrained(model_dir, trust_remote_code=True, **overrides).to(self.device).eval()
        dense_dir = os.path.join(model_dir, "2_Dense_1024")
        if os.path.exists(os.path.join(dense_dir, "model.safetensors")):
            from safetensors.torch import load_file

            weights = load_file(os.path.join(dense_dir, "model.safetensors"))
        else:
            weights = torch.load(os.path.join(dense_dir, "pytorch_model.bin"), map_location="cpu")
        self.linear = torch.nn.Linear(self.model.config.hidden_size, 1024)
        self.linear.load_state_dict({k.replace("linear.", ""): v for k, v in weights.items()})
        self.linear.to(self.device).eval()
        self.model_id = model_id

    def _mean_pool(self, texts, max_length):
        inputs = self.tokenizer(texts, padding=True, truncation=True, max_length=max_length, return_tensors="pt")
        inputs = {k: v.to(self.device) for k, v in inputs.items()}
        hidden = self.model(**inputs)[0]
        mask = inputs["attention_mask"]
        hidden = hidden.masked_fill(~mask[..., None].bool(), 0.0)
        return hidden.sum(dim=1) / mask.sum(dim=1)[..., None]

    def encode(self, texts):
        torch = self.torch
        if self.name == "minilm":
            return self.model.encode(
                texts, batch_size=self.batch_size, normalize_embeddings=True, convert_to_numpy=True
            ).astype(np.float32)
        with torch.no_grad():
            if self.name == "contriever":
                vectors = self._mean_pool(texts, 512)
            else:
                vectors = torch.nn.functional.normalize(self.linear(self._mean_pool(texts, 512)), dim=-1)
        return vectors.float().cpu().numpy()


class VectorCache:
    """Doc vectors keyed by text hash, persisted as one .npz per model."""

    def __init__(self, path):
        self.path = path
        self.vectors = {}
        if path and os.path.exists(path):
            data = np.load(path)
            self.vectors = dict(zip(data["keys"].tolist(), data["vectors"]))

    def fill(self, encoder, texts_by_key):
        missing = [key for key in texts_by_key if key not in self.vectors]
        # Encode longest first so each batch pads to similar lengths.
        missing.sort(key=lambda key: len(texts_by_key[key]), reverse=True)
        started = time.time()
        for start in range(0, len(missing), encoder.batch_size):
            batch = missing[start : start + encoder.batch_size]
            for key, vector in zip(batch, encoder.encode([texts_by_key[key] for key in batch])):
                self.vectors[key] = vector
            done = start + len(batch)
            if done % (encoder.batch_size * 20) < encoder.batch_size or done == len(missing):
                rate = done / max(time.time() - started, 1e-9)
                print(f"  encoded {done}/{len(missing)} docs ({rate:.1f}/s)", file=sys.stderr, flush=True)
            if done % (encoder.batch_size * 200) < encoder.batch_size:
                self.save()
        self.save()

    def save(self):
        if not self.path or not self.vectors:
            return
        keys = list(self.vectors)
        tmp = self.path + ".tmp.npz"
        np.savez(tmp, keys=np.array(keys), vectors=np.stack([self.vectors[k] for k in keys]))
        os.replace(tmp, self.path)

    def matrix(self, texts):
        return np.stack([self.vectors[text_key(text)] for text in texts])


def dense_rankings(jobs, args):
    encoder = Encoder(args.retriever, pick_device(args.device), args.batch_size, args.stella_model)
    cache_name = f"{encoder.model_id.replace('/', '_')}.npz"
    cache = VectorCache(os.path.join(args.cache_dir, cache_name) if args.cache_dir else None)
    texts_by_key = {text_key(doc["text"]): doc["text"] for job in jobs for doc in job["docs"]}
    print(f"{len(texts_by_key)} distinct docs, {len(cache.vectors)} cached", file=sys.stderr)
    cache.fill(encoder, texts_by_key)
    queries = encoder.encode([job["query"] for job in jobs])
    for job, query in zip(jobs, queries):
        scores = cache.matrix([doc["text"] for doc in job["docs"]]) @ query
        yield job, np.argsort(-scores, kind="stable")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jobs", required=True)
    parser.add_argument("--retriever", required=True, choices=["bm25", "bm25norm", "contriever", "stella", "minilm"])
    parser.add_argument("--out", required=True)
    parser.add_argument("--cache-dir", help="directory for persisted doc vectors")
    parser.add_argument("--device", default="auto", help="auto, mps, cuda or cpu")
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--stella-model", default=STELLA, help="e.g. dunzhang/stella_en_400M_v5")
    parser.add_argument("--limit", type=int, default=0, help="only the first N jobs (smoke tests)")
    args = parser.parse_args()
    if args.cache_dir:
        os.makedirs(args.cache_dir, exist_ok=True)

    jobs = load_jobs(args.jobs, args.limit)
    started = time.time()
    if args.retriever == "bm25":
        results = bm25_rankings(jobs, official_tokens)
    elif args.retriever == "bm25norm":
        results = bm25_rankings(jobs, normalized_tokens)
    else:
        results = dense_rankings(jobs, args)
    with open(args.out, "w") as out:
        for job, order in results:
            ranked = [job["docs"][index]["id"] for index in order]
            out.write(json.dumps({"qid": job["qid"], "ranked": ranked}) + "\n")
    print(f"{args.retriever}: {len(jobs)} jobs in {time.time() - started:.1f}s -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
