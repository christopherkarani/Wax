"""Regenerate Tests/WaxIntegrationTests/Fixtures/minilm_baseline_embeddings.json.

Vectors come from the PyTorch sentence-transformers reference, never from Wax's
own output, so the Swift quality test compares against an independent baseline.

Usage:
    python Resources/scripts/models/generate_minilm_fixture.py FIXTURE.json [--weights-dir DIR]
"""
from __future__ import annotations

import argparse
import json

import minilm_reference as ref

SENTENCES = [
    "Swift concurrency makes structured parallelism practical.",
    "Vector search underpins modern retrieval-augmented generation.",
    "Core ML optimizations should balance accuracy and throughput.",
    "Batch embeddings improve ANE utilization on Apple silicon.",
    "Memory systems need fast ingestion and recall latencies.",
    "Structured logging helps debug RAG pipelines.",
    "Compression techniques like quantization reduce bandwidth.",
    "On-device inference keeps user data private.",
    # Longer than max_seq_length (256 tokens): checks truncation parity.
    " ".join(["Wax stores agent memory in one portable file and recalls it with hybrid search."] * 24),
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", help="Output JSON path")
    parser.add_argument("--weights-dir", help="Local directory with model.safetensors + tokenizer.json")
    args = parser.parse_args()

    directory = ref.resolve_weights(args.weights_dir)
    backbone = ref.load_backbone(directory)
    tokenizer = ref.load_tokenizer(directory)
    ref.check_anchor(backbone, tokenizer)

    vectors = ref.reference_embeddings(backbone, tokenizer, SENTENCES)
    fixture = {
        "dimensions": ref.HIDDEN_SIZE,
        "embeddings": [[float(x) for x in row.astype("float32")] for row in vectors],
        "maxSequenceLength": ref.MAX_SEQ_LENGTH,
        "sentences": SENTENCES,
        "source": f"{ref.REPO_ID}@{ref.REVISION}",
    }
    with open(args.fixture, "w") as handle:
        json.dump(fixture, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print("wrote", len(SENTENCES), "embeddings to", args.fixture)


if __name__ == "__main__":
    main()
