# ``WaxVectorSearchMiniLM``

On-device sentence embeddings via CoreML with the all-MiniLM-L6-v2 transformer model.

## Overview

WaxVectorSearchMiniLM provides a production-ready `EmbeddingProvider` that runs entirely on-device using Apple's Neural Engine. It produces 384-dimensional, L2-normalized embeddings optimized for semantic similarity search.

The module wraps the [all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) sentence transformer as a compiled CoreML model with a full BERT WordPiece tokenizer.

```swift
import WaxVectorSearchMiniLM

let embedder = try MiniLMEmbedder()

// Single embedding
let vector = try await embedder.embed("What is Swift concurrency?")
// vector.count == 384

// Batch embedding (much faster for bulk ingestion)
let vectors = try await embedder.embed(batch: [
    "First document",
    "Second document",
    "Third document"
])
```

### Key Characteristics

| Property | Value |
|----------|-------|
| Dimensions | 384 |
| Normalization | L2-normalized |
| Max tokens | 512 (BERT limit) |
| Compute | Neural Engine + CPU (default) |
| Quantization | Float16 output, converted to Float32 |
| Execution mode | On-device only (no network) |

This module is conditionally compiled via the `MiniLMEmbeddings` package trait, which is enabled by default.

## Topics

### Essentials

- <doc:MiniLMEmbedder>
- ``MiniLMEmbedder``

### CoreML Integration

- ``MiniLMEmbeddings``
- ``BertTokenizer``
