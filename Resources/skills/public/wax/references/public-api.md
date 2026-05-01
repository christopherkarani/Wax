# Wax Public API Reference

This file tracks the public API that external packages can compile against from
the `Wax` product. Package-internal implementation types are listed separately
so they are not accidentally used in public snippets.

## Public External API

**Memory**
Source: `Sources/Wax/Memory.swift`

- `public actor Memory`
- `public init(at url: URL, config: Config = .default) async throws`
- `public init(at url: URL, configure: (inout Config) -> Void) async throws`
- `public init(at url: URL, config: Config = .default, embedding: some EmbeddingProvider) async throws`
- `public init(at url: URL, embedding: some EmbeddingProvider, configure: (inout Config) -> Void) async throws`
- `public func save(_ text: String, metadata: [String: String] = [:]) async throws`
- `public func search(_ query: String, options: SearchOptions = .default) async throws -> RAGContext`
- `public func search(_ query: String, configure: (inout SearchOptions) -> Void) async throws -> RAGContext`
- `public func close() async throws`

**Memory.Config**

- `enableTextSearch`
- `enableVectorSearch`
- `enableStructuredMemory`
- `enableAccessStatsScoring`
- `enableAsyncEnrichment`
- `ingestConcurrency`
- `ingestBatchSize`
- `requireOnDeviceProviders`

**Memory.SearchOptions**

- `topK`
- `includeSurrogates`
- `timeRange`
- `mode` (`.textOnly` or `.hybrid`)

**RAGContext**
Source: `Sources/Wax/RAG/RAGContext.swift`

- `public struct RAGContext`
- `public var query: String`
- `public var items: [Item]`
- `public var totalTokens: Int`
- `RAGContext.Item` exposes `kind`, `frameId`, `score`, `sources`, `text`, and `metadata`.

**Search Extension Points**
Source: `Sources/Wax/Memory.swift`

- `public protocol SearchStrategy`
- `public protocol ResultReranker`

**EmbeddingProvider**
Source: `Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift`

- `public protocol EmbeddingProvider`
- `var dimensions: Int { get }`
- `var normalize: Bool { get }`
- `var identity: EmbeddingIdentity? { get }`
- `func embed(_ text: String) async throws -> [Float]`
- Related public API: `BatchEmbeddingProvider` and `EmbeddingIdentity`.

**Memory semantics**
Source: `Sources/Wax/MemorySemantics.swift`

- `MemoryType`
- `MemoryDurability`
- `MemoryScopeContext`

## Package-Internal Implementation Types

These are not external API in the current Wax target:

- `MemoryOrchestrator`
- `OrchestratorConfig`
- `QueryEmbeddingPolicy`
- `WaxSession`
- `SearchRequest`
- `SearchResponse`
- `SearchMode`
- `FrameFilter`
- `FastRAGConfig`
- `FastRAGContextBuilder`
- `MiniLMEmbedder`
- `WaxPrewarm`
- `PhotoRAGOrchestrator`
- `PhotoRAGConfig`
- `VideoRAGOrchestrator`
- `VideoRAGConfig`
- `VideoTranscriptProvider`
- `VideoFile`
- `VideoQuery`

Public docs and public skills may mention these for architecture, but snippets
must either use `Memory` or clearly state that they are package-internal.
