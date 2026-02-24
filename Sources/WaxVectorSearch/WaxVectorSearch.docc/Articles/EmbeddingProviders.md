# Embedding Providers

Implement the TextEmbeddingProvider protocol to supply vector embeddings from any source.

## Overview

The ``EmbeddingProvider`` protocol defines a pluggable interface for converting text into fixed-dimensional vector embeddings. Any conforming type can be used with Wax's vector search and RAG systems.

## The EmbeddingProvider Protocol

```swift
public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var normalize: Bool { get }
    var identity: EmbeddingIdentity? { get }
    var executionMode: ProviderExecutionMode { get }
    func embed(_ text: String) async throws -> [Float]
}
```

### Required Properties

| Property | Purpose |
|----------|---------|
| `dimensions` | Vector dimensionality (e.g., 384 for MiniLM, 1536 for OpenAI) |
| `normalize` | Whether output vectors are L2-normalized |
| `identity` | Optional metadata identifying the provider/model |
| `executionMode` | Whether the provider requires network access |

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
