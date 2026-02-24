---
sidebar_position: 1
title: "MiniLM Embedder"
sidebar_label: "MiniLM Embedder"
---

Set up, configure, and optimize the on-device MiniLM embedding provider.

## Overview

`MiniLMEmbedder` is an actor that implements both `EmbeddingProvider` and `BatchEmbeddingProvider`. It manages CoreML model loading, tokenization, and inference with automatic batch optimization.

## Setup

Create an embedder with default settings:

```swift
let embedder = try MiniLMEmbedder()
```

Or customize the batch size and CoreML configuration:

```swift
var config = MiniLMEmbedder.Config()
config.batchSize = 128  // Default is 256

let mlConfig = MLModelConfiguration()
mlConfig.computeUnits = .cpuAndNeuralEngine

config.modelConfiguration = mlConfig

let embedder = try MiniLMEmbedder(config: config)
```

## Prewarming

The first inference triggers JIT compilation of the CoreML model, which adds latency. Prewarm the model during app launch to avoid this:

```swift
try await embedder.prewarm(batchSize: 16)
```

The batch size is clamped to 1...32 for prewarming.

## Single vs. Batch Embedding

For individual queries, use the single-text API:

```swift
let vector = try await embedder.embed("search query")
```

For bulk ingestion, batch embedding is significantly faster:

```swift
let texts = ["doc 1", "doc 2", /* ... thousands more ... */]
let vectors = try await embedder.embed(batch: texts)
```

### Batch Planning

The embedder splits large batches into chunks based on the configured `batchSize` (default 256). Each chunk is processed as a single CoreML prediction with buffer reuse to minimize allocations.

For a batch of 1,000 texts with `batchSize = 256`:
- 3 full batches of 256
- 1 remainder batch of 232
- Size-1 batches fall back to single-text inference

## Tokenization

Text is tokenized using the full BERT WordPiece pipeline:

1. **Basic tokenization** — Whitespace/punctuation splitting, diacritic normalization, lowercasing
2. **WordPiece tokenization** — Greedy longest-match subword splitting with `##` continuation prefix
3. **Special token wrapping** — `[CLS]` prepended, `[SEP]` appended
4. **Padding** — Zero-padded to the selected sequence length

### Sequence Length Optimization

Instead of always padding to 512 tokens, the tokenizer selects the smallest bucket that fits the longest text in each batch:

| Bucket | Use Case |
|--------|----------|
| 32 | Short phrases |
| 64 | Single sentences |
| 128 | Short paragraphs |
| 256 | Long paragraphs |
| 384 | Multi-paragraph text |
| 512 | Maximum (full BERT limit) |

This reduces computation by 2-4x for typical inputs.

## CoreML Integration

### Compute Units

The default compute unit configuration is `.cpuAndNeuralEngine`, which routes transformer attention operations to Apple's Neural Engine for optimal throughput. This is 1.5-2x faster than `.all` (which includes the GPU) because it avoids GPU dispatch overhead.

### Diagnostics

Check which compute hardware is being used:

```swift
let usesANE = try await embedder.isUsingANE()
let units = try await embedder.currentComputeUnits()
```

### Model Output

The CoreML model outputs Float16 embeddings, which are converted to Float32 using Accelerate's `vDSP.convertElements` (8-16x faster than scalar conversion). The vectors are L2-normalized before returning.

## Performance Notes

| Operation | Typical Latency |
|-----------|----------------|
| Single embed | ~50-100ms (ANE) |
| Batch (256 texts) | ~2-4s (ANE) |
| Prewarming | ~500ms-1s |
| Model loading | ~200-500ms (cached after first load) |

### Memory Profile

| Component | Size |
|-----------|------|
| CoreML model | ~50 MiB |
| Tokenizer vocab | ~200 KiB |
| Batch buffers | ~1 MiB per 256-item batch |

### Thread Safety

`MiniLMEmbedder` is an actor, so all methods are safe to call concurrently from any context. The underlying CoreML model uses a thread-safe cache to prevent concurrent model loads (which can cause CoreML/Espresso deadlocks).

## Embedding Identity

The embedder reports its identity for provenance tracking:

```swift
embedder.identity
// EmbeddingIdentity(
//     provider: "Wax",
//     model: "MiniLMAll",
//     dimensions: 384,
//     normalized: true
// )
```

This identity is stored alongside vector indexes to detect embedding model changes between sessions.
