# ``WaxVectorSearch``

Vector search with CPU (Accelerate) and GPU (Metal/MetalANNS) backends for semantic similarity.

## Overview

WaxVectorSearch provides high-performance vector similarity search engines for Wax package internals. The ``VectorSearchEngine`` protocol is package-only and not public API; downstream applications should use the top-level Wax APIs instead of depending on this implementation module directly.

For package contributors, the module contains interchangeable backends:

- **``AccelerateVectorEngine``** — CPU-backed exact vector search using Accelerate when available. Supports cosine, dot product, and L2 distance metrics.
- **``MetalVectorEngine``** — GPU-accelerated brute-force search with SIMD-optimized Metal compute shaders. Supports cosine similarity with automatic kernel selection (SIMD4 or SIMD8).
- **``MetalANNSVectorEngine``** — GPU-backed approximate nearest neighbor search for larger Apple-platform indexes.

Both engines are actors with async APIs, automatic serialization, and Wax integration. They are constructed by Wax package internals, not by downstream application code.

The module also defines the ``EmbeddingProvider`` protocol for text-to-vector conversion, enabling pluggable embedding backends.

## Topics

### Essentials

- <doc:VectorSearchEngines>
- <doc:EmbeddingProviders>

### Engines

- ``AccelerateVectorEngine``
- ``MetalVectorEngine``
- ``MetalANNSVectorEngine``

### Metrics

- ``VectorMetric``

### Embedding Providers

- ``EmbeddingProvider``
- ``BatchEmbeddingProvider``
- ``EmbeddingIdentity``
- ``ProviderExecutionMode``

### Serialization

- ``VectorSerializer``
