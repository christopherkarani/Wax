# ``WaxVectorSearch``

HNSW vector search with CPU (USearch) and GPU (Metal) backends for semantic similarity.

## Overview

WaxVectorSearch provides high-performance vector similarity search with two interchangeable backends that implement the ``VectorSearchEngine`` protocol:

- **``USearchVectorEngine``** — CPU-based HNSW (Hierarchical Navigable Small Worlds) index via [USearch](https://github.com/unum-cloud/USearch). Supports cosine, dot product, and L2 distance metrics.
- **``MetalVectorEngine``** — GPU-accelerated brute-force search with SIMD-optimized Metal compute shaders. Supports cosine similarity with automatic kernel selection (SIMD4 or SIMD8).

Both engines are actors with async APIs, automatic serialization, and Wax integration.

```swift
// CPU engine (works everywhere)
let cpu = try USearchVectorEngine(metric: .cosine, dimensions: 384)

// GPU engine (Apple Silicon)
if MetalVectorEngine.isAvailable {
    let gpu = try MetalVectorEngine(metric: .cosine, dimensions: 384)
}
```

The module also defines the ``EmbeddingProvider`` protocol for text-to-vector conversion, enabling pluggable embedding backends.

## Topics

### Essentials

- <doc:VectorSearchEngines>
- <doc:EmbeddingProviders>

### Engines

- ``VectorSearchEngine``
- ``USearchVectorEngine``
- ``MetalVectorEngine``
- ``VectorEnginePreference``

### Metrics

- ``VectorMetric``

### Embedding Providers

- ``EmbeddingProvider``
- ``BatchEmbeddingProvider``
- ``EmbeddingIdentity``
- ``ProviderExecutionMode``

### Serialization

- ``VectorSerializer``
