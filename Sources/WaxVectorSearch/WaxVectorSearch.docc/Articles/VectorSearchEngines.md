# Vector Search Engines

Compare the CPU and GPU backends and understand their performance characteristics.

## Overview

WaxVectorSearch ships two ``VectorSearchEngine`` implementations. Both are actors with the same async API, making them interchangeable at runtime.

## USearchVectorEngine (CPU)

``USearchVectorEngine`` uses the USearch library's HNSW (Hierarchical Navigable Small Worlds) graph index. HNSW provides approximate nearest neighbor search with sub-linear query time.

### Configuration

| Parameter | Value |
|-----------|-------|
| Connectivity | 16 (HNSW graph edges per node) |
| Quantization | Float32 |
| Initial capacity | 64 vectors |
| Capacity growth | Doubling strategy |
| Metrics | Cosine, Dot Product, L2 |

### When to Use

- Cross-platform deployments (no Metal required)
- Small to medium index sizes (up to ~1M vectors)
- When you need dot product or L2 metrics
- When approximate results are acceptable

```swift
let engine = try USearchVectorEngine(metric: .cosine, dimensions: 384)
try await engine.add(frameId: 1, vector: embedding)

let results = try await engine.search(vector: query, topK: 10)
```

## MetalVectorEngine (GPU)

``MetalVectorEngine`` uses Metal compute shaders for brute-force cosine distance computation on the GPU. It achieves high throughput through SIMD vectorization and Unified Memory.

### Metal Shader Pipeline

The search pipeline has two stages:

1. **Distance computation** — Each GPU thread computes the cosine distance between the query vector and one stored vector. The engine selects between two kernels:

   | Kernel | Dimensions | Strategy |
   |--------|------------|----------|
   | SIMD4 | < 384 | Process 4 floats per iteration |
   | SIMD8 | >= 384 | Process 8 floats with dual accumulators for ILP |

2. **Top-K reduction** — For large indexes (>= 1,000 vectors), GPU-side top-K reduction avoids transferring all distances to the CPU:
   - **Stage 1**: Per-threadgroup partial top-K via bitonic sort or heap
   - **Stage 2**: Iterative merge across threadgroups until a single top-K remains
   - **Fallback**: For smaller indexes, CPU-side O(n log k) heap selection

### Unified Memory

Vectors are stored directly in an `MTLBuffer` using Apple Silicon's Unified Memory Architecture. This eliminates CPU-to-GPU copies — the CPU writes vectors directly to the buffer, and the GPU reads them without any transfer.

### Buffer Pooling

Transient buffers (query vectors, distance arrays) are pooled and reused across searches to avoid per-query allocation overhead.

### Availability

```swift
if MetalVectorEngine.isAvailable {
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 384)
}
```

`MetalVectorEngine.isAvailable` checks for a Metal-capable GPU device. It is always available on Apple Silicon Macs and iPhones.

### Limitations

- **Cosine similarity only** — The Metal kernels assume the query vector is pre-normalized
- **Brute-force search** — O(n) per query, best for indexes under ~100K vectors where GPU parallelism compensates

## Choosing an Engine

Use ``VectorEnginePreference`` to let the system decide:

```swift
let preference: VectorEnginePreference = .auto
```

| Preference | Behavior |
|------------|----------|
| `.auto` | Metal if available, otherwise USearch |
| `.metalPreferred` | Metal if available, otherwise USearch |
| `.cpuOnly` | Always USearch |

## Common Operations

Both engines share the ``VectorSearchEngine`` protocol:

```swift
// Add vectors
try await engine.add(frameId: 1, vector: embedding)
try await engine.addBatch(frameIds: ids, vectors: vectors)

// Streaming for large ingestions (prevents lock starvation)
try await engine.addBatchStreaming(
    frameIds: ids,
    vectors: vectors,
    chunkSize: 256
)

// Search
let results = try await engine.search(vector: queryVector, topK: 10)
// Returns: [(frameId: UInt64, score: Float)]
// Score: higher is better (1.0 = identical for cosine)

// Remove
try await engine.remove(frameId: 1)

// Persist
try await engine.stageForCommit(into: waxStore)
```

## Score Interpretation

The ``VectorMetric`` converts raw distances to similarity scores:

| Metric | Formula | Range |
|--------|---------|-------|
| Cosine | `1 - distance` | 0 (orthogonal) to 1 (identical) |
| Dot Product | `-distance` | Unbounded |
| L2 | `-distance` | Unbounded (0 = identical) |

## Serialization Format

Both engines serialize to the MV2V binary format:

```
[Magic: 4B "MV2V"][Version: 2B][Encoding: 1B][Similarity: 1B]
[Dimensions: 4B][VectorCount: 8B][PayloadLength: 8B][Reserved: 8B]
[Payload: variable]
```

The `Encoding` byte distinguishes USearch (1) from Metal (2) format. Cross-format deserialization is supported — a Metal engine can load a USearch-serialized index by re-inserting vectors.
