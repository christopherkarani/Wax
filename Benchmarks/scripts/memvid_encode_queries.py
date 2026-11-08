#!/usr/bin/env python3
"""Encode the queries of a jobs file with all-MiniLM-L6-v2, as longmemeval_baselines.py does.

Writes an .npz with qids and normalised float32 vectors. Run with the baselines venv
(sentence-transformers), not the memvid venv.

Usage: memvid_encode_queries.py --jobs locomo.jobs.jsonl --out locomo.queries.minilm.npz
"""
import argparse
import json

import numpy as np

MINILM = "sentence-transformers/all-MiniLM-L6-v2"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jobs", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()
    qids, texts = [], []
    with open(args.jobs) as handle:
        for line in handle:
            if line.strip():
                entry = json.loads(line)
                for query in entry.get("queries", [entry]):
                    qids.append(query["qid"])
                    texts.append(query["query"])
    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(MINILM, device=args.device)
    vectors = model.encode(texts, batch_size=64, normalize_embeddings=True, convert_to_numpy=True).astype(np.float32)
    np.savez(args.out, qids=np.array(qids), vectors=vectors)
    print(f"{len(qids)} queries -> {args.out}")


if __name__ == "__main__":
    main()
