# Embedding Providers

Implement the TextEmbeddingProvider protocol to supply vector embeddings from any source.

## Overview

The ``EmbeddingProvider`` protocol defines a pluggable interface for converting text into fixed-dimensional vector embeddings. Any conforming type can be used with Wax's vector search and RAG systems.

## The EmbeddingProvider Protocol

```swift
public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var normalize: Bool { get }
    var similarity: VectorSimilarity { get }   // default .cosine
    var identity: EmbeddingIdentity? { get }
    var executionMode: ProviderExecutionMode { get }
    func embed(_ text: String) async throws -> [Float]
}
```

### Required Properties

| Property | Purpose |
|----------|---------|
| `dimensions` | Vector dimensionality (e.g., 384 for MiniLM, 1536 for OpenAI) |
| `normalize` | Whether Wax L2-normalizes each vector before storing it and before searching with it |
| `similarity` | How stored vectors are ranked against a query: `.cosine` (default) or `.dotProduct` |
| `identity` | Optional metadata identifying the provider/model |
| `executionMode` | Whether the provider requires network access |

### Similarity

``VectorSimilarity`` picks how the store ranks vectors. It defaults to `.cosine`, so providers that do not declare it rank exactly as before.

| Similarity | Ranks by | Use for |
|------------|----------|---------|
| `.cosine` | Angle between vectors; length is ignored | Most sentence-embedding models (MiniLM, Arctic, OpenAI) |
| `.dotProduct` | Inner product; a longer vector can outrank a better-aligned one | Models trained with a dot-product objective, such as `facebook/contriever` |

`similarity` and `normalize` are separate settings:

| `similarity` | `normalize` | Result |
|--------------|-------------|--------|
| `.cosine` | `true` or `false` | Cosine ranking. Wax normalizes vectors inside the index either way. |
| `.dotProduct` | `false` | Raw inner product of the vectors the provider returns. Use this for dot-product models. |
| `.dotProduct` | `true` | Every vector has unit length, so the ranking equals cosine. Allowed, but it gives up what dot product adds. |

With `.dotProduct`, vector-lane scores are raw inner products, not values in `-1...1`.

A store records its similarity when it first commits vectors. Opening it with an embedder that declares a different similarity throws `WaxError.io` with a "vector similarity mismatch" message, the same way an embedder identity mismatch does. A provider that attaches later (for example after a built-in model finishes loading) is reported as `EmbeddingStatus.unavailable` instead, and search uses the text lane. The stored vectors cannot be converted, because a cosine index keeps only unit-length vectors. To switch similarity, ingest into a new store.

```swift
struct ContrieverEmbedder: EmbeddingProvider {
    let dimensions = 768
    let normalize = false
    let similarity = VectorSimilarity.dotProduct
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "MyApp", model: "contriever", dimensions: 768, normalized: false
    )

    func embed(_ text: String) async throws -> [Float] {
        // Call your model here.
    }
}
```

### Execution Mode

``ProviderExecutionMode`` controls whether a provider can be used in privacy-sensitive contexts:

| Mode | Description |
|------|-------------|
| `.onDeviceOnly` | All computation is local (e.g., CoreML models) |
| `.mayUseNetwork` | May call cloud services (e.g., OpenAI API) |

When `OrchestratorConfig.requireOnDeviceProviders` is `true` (the default), providers with `.mayUseNetwork` are rejected at initialization.

## Batch Embedding

For higher throughput during ingestion, implement ``BatchEmbeddingProvider``:

```swift
public protocol BatchEmbeddingProvider: EmbeddingProvider {
    func embed(batch texts: [String]) async throws -> [[Float]]
}
```

Batch providers amortize model initialization and data transfer overhead. The orchestrator automatically uses batch embedding when available.

## Embedding Identity

``EmbeddingIdentity`` provides metadata for provenance tracking:

```swift
public struct EmbeddingIdentity: Sendable, Equatable {
    public var provider: String?    // e.g., "Wax"
    public var model: String?       // e.g., "MiniLMAll"
    public var dimensions: Int?     // e.g., 384
    public var normalized: Bool?    // e.g., true
}
```

This identity is stored alongside the vector index to detect embedding model changes.

## Building a Custom Provider

Here's a minimal on-device provider:

```swift
public actor MyEmbedder: EmbeddingProvider, BatchEmbeddingProvider {
    public let dimensions = 384
    public let normalize = true
    public let executionMode = ProviderExecutionMode.onDeviceOnly

    public var identity: EmbeddingIdentity? {
        EmbeddingIdentity(
            provider: "MyApp",
            model: "custom-v1",
            dimensions: 384,
            normalized: true
        )
    }

    public func embed(_ text: String) async throws -> [Float] {
        // Your embedding logic here
    }

    public func embed(batch texts: [String]) async throws -> [[Float]] {
        // Batch embedding for throughput
    }
}
```

## Built-in Provider

The WaxVectorSearchMiniLM module provides a ready-to-use on-device provider based on the all-MiniLM-L6-v2 model. See the WaxVectorSearchMiniLM documentation for details.
