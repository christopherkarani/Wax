# ``WaxVectorSearch``

HNSW vector search with CPU (USearch) and GPU (Metal) backends for semantic similarity.

## Overview

WaxVectorSearch provides high-performance vector similarity search engines for Wax package internals. The ``VectorSearchEngine`` protocol is package-only and not public API; downstream applications should use the top-level Wax APIs instead of depending on this implementation module directly.

For package contributors, the module contains two interchangeable backends:

- **``USearchVectorEngine``** — CPU-based HNSW (Hierarchical Navigable Small Worlds) index via [USearch](https://github.com/unum-cloud/USearch). Supports cosine, dot product, and L2 distance metrics.
- **``MetalVectorEngine``** — GPU-accelerated brute-force search with SIMD-optimized Metal compute shaders. Supports cosine similarity with automatic kernel selection (SIMD4 or SIMD8).

Both engines are actors with async APIs, automatic serialization, and Wax integration. They are constructed by Wax package internals, not by downstream application code.

The module also defines the ``EmbeddingProvider`` protocol for text-to-vector conversion, enabling pluggable embedding backends.

## Topics

### Essentials

- <doc:VectorSearchEngines>
- <doc:EmbeddingProviders>

### Engines

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
