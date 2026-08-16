# Wax Public API Reference

This reference lists the **actually public** API surface of the Wax Swift package (`import Wax`). Types marked *package-only* are internal implementation details — they use Swift `package` access and cannot be named or constructed by downstream apps. Do not generate client code against package-only types.

## Memory (public facade)

Source: `Sources/Wax/Memory.swift`

- `public actor Memory`
- `public init(at url: URL, config: Memory.Config = .default) async throws`
  - Embedder selection lives on `config.embedding` (`Memory.EmbeddingSource`, default `.automatic`). With `.automatic` and `config.enableVectorSearch == true` (default), the built-in MiniLM embedder is wired on iOS 18/macOS 15+ (requires the default `MiniLMEmbeddings` package trait). On older OS versions or if the model is unavailable, the store runs text-only — check `stats()` or `RAGContext.diagnostics`.
- `public init(at url: URL, configure: (inout Memory.Config) -> Void) async throws` — convenience closure form of the above.
- `public func save(_ text: String, metadata: [String: String] = [:]) async throws`
- `public func save<each S: StringProtocol>(_ texts: repeat each S) async throws`
- `public func search(_ query: String, options: Memory.SearchOptions = .default) async throws -> Memory.Results`
- `public func search(_ query: String, configure: (inout Memory.SearchOptions) -> Void) async throws -> Memory.Results`
- `public func search(_:strategy:options:)` / `search(_:strategy:options:reranker:)` with `SearchStrategy` / `ResultReranker`
- `public func delete(frameID: UInt64) async throws` — soft-deletes the frame and removes it from enabled text and vector indexes (committed).
- `public func flush() async throws` — commits pending writes (WAL, FTS, vector index) to durable storage.
- `public func close() async throws` — flushes, then closes.
- `public func stats() async -> Memory.Stats`

### Memory.Config

`public struct Config: Sendable` with `enableTextSearch` (true), `enableVectorSearch` (true), `enableStructuredMemory` (false), `enableAccessStatsScoring` (false), `enableAsyncEnrichment` (false), `ingestConcurrency` (1), `ingestBatchSize` (32), `requireOnDeviceProviders` (true), `embedding` (`.automatic`); `public static let .default`.

### Memory.EmbeddingSource

`public enum EmbeddingSource: Sendable` — selects the embedder for a store:

- `.automatic` — built-in MiniLM when the platform/build supports it, text-only fallback otherwise.
- `.builtIn(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions = .default)` — force a built-in provider; store creation throws `BuiltInEmbeddingProviderError.unavailable` when the provider is unavailable on this OS/build.
- `.custom(any EmbeddingProvider)` — bring your own embedder.

### Memory.SearchOptions / RetrievalMode / TimeRange

- `public struct SearchOptions` with `topK` (10), `includeSurrogates` (false), `timeRange: TimeRange?` (nil), `mode: RetrievalMode` (`.hybrid()`).
- `public enum RetrievalMode { case textOnly, vectorOnly, hybrid(alpha: Float = 0.5) }`
  - `.hybrid` degrades to the text lane when no embedder is available; `.vectorOnly` throws when vector search is unavailable. Check `RAGContext.diagnostics` for what actually ran.
- `public struct TimeRange { afterMs: Int64?, beforeMs: Int64? }`

### Memory.Results (RAGContext)

Source: `Sources/Wax/RAG/RAGContext.swift`

- `public typealias Memory.Results = RAGContext`
- `public struct RAGContext: Sendable, Equatable`
  - `public var query: String`, `public var items: [Item]`, `public var totalTokens: Int`
  - `public var diagnostics: RAGContext.Diagnostics?` — requested vs. effective retrieval mode plus query-embedding state. `nil` only for contexts built outside the retrieval pipeline.
- `RAGContext.Diagnostics`: `requestedMode: String`, `effectiveMode: String` (`"text"`, `"vector"`, `"hybrid(alpha=…)"`), `queryEmbeddingState: QueryEmbeddingState`.
- `RAGContext.QueryEmbeddingState`: `.notRequested`, `.available`, `.timeout`, `.circuitOpen`, `.noEmbedder`, `.vectorDisabled`, `.failed`.
- `RAGContext.Item`: `kind` (`.snippet`/`.expanded`/`.surrogate`), `frameId`, `score`, `sources` (`.text`/`.vector`/`.timeline`/`.structured`/`.unknown`), `text`, `metadata`, `explanations`.

### Memory.Stats

`public struct Stats: Sendable, Equatable` with `frameCount`, `pendingFrames`, `vectorSearchEnabled`, `queryEmbedderConfigured`, `queryEmbeddingCircuitOpen`, `embedderIdentity: EmbeddingIdentity?`.

## Built-in Embeddings

Source: `Sources/Wax/BuiltInEmbeddings.swift`

- `public enum BuiltInEmbeddingProvider { case miniLM, arctic }`
  - `.miniLM` — all-MiniLM-L6-v2 CoreML embedder; iOS 18/macOS 15+, default `MiniLMEmbeddings` trait.
  - `.arctic` — Snowflake Arctic Embed Small; iOS 18/macOS 15+, `ArcticEmbeddings` trait.
- `public enum BuiltInEmbeddings { public static func make(_:options:) async throws -> any EmbeddingProvider }`
- `public struct BuiltInEmbeddingProviderOptions` (`batchSize`, `prewarmBatchSize`, `allowLowPrecisionGPU`, `timeoutSeconds`, `computeUnitsOrder`).
- `public enum BuiltInEmbeddingComputeUnit { cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all }`
- `public enum BuiltInEmbeddingProviderError: LocalizedError { case unavailable(BuiltInEmbeddingProvider) }`

## Embedding Protocols (public, via WaxVectorSearch)

Source: `Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift`

- `public protocol EmbeddingProvider: Sendable` — `dimensions`, `normalize`, `identity`, `func embed(_:) async throws -> [Float]`. Optional `executionMode: ProviderExecutionMode`.
- `public protocol BatchEmbeddingProvider: EmbeddingProvider` — `func embed(batch:) async throws -> [[Float]]`.
- `public struct EmbeddingIdentity` (`provider`, `model`, `dimensions`, `normalized`).

## Errors

- `public enum WaxError` (WaxCore) — `Memory.Error` typealias. Catchable cases include `featureDisabled(feature:)` (API requires a config feature that is off), `missingEmbedder` (vector search enabled but no embedder configured), `invalidEmbedding(reason:)` (provider returned a bad vector), `frameNotFound(frameId:)`, `capacityExceeded(limit:requested:)`, `lockUnavailable`, `writerBusy`, `writerTimeout`, plus format/IO cases (`invalidHeader`, `invalidFooter`, `invalidToc`, `encodingError`, `decodingError`, `walCorruption`, `checksumMismatch`, `io`).

## Foundation Models Tools (iOS 26/macOS 26+)

When `canImport(FoundationModels)`: `memory.foundationModelsMemoryTool()`, `memory.foundationModelsTools(kit:)`, `memory.foundationModelsCombinedTools()` expose remember/recall/search as on-device model tools.

## Package-only (NOT public API)

The following are `package`-access internals. They are used by Wax's own CLI/MCP server and tests, but **cannot be imported or constructed by downstream apps**:

- `MemoryOrchestrator`, `OrchestratorConfig`, `FastRAGConfig` (the engine behind `Memory`)
- `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, `MultimodalEmbeddingProvider`, `VideoTranscriptProvider` (experimental multimodal pipelines; host apps cannot use them yet)
- `WaxSession`, `Wax` actor, `SearchRequest`, `SearchResponse`, `FrameFilter`, structured-memory types (`EntityKey`, facts)
- `MiniLMEmbedder` (use `BuiltInEmbeddings.make(.miniLM)` or `Memory.Config.embedding = .builtIn(.miniLM)` instead)

Agent-facing structured memory is available through Wax MCP tools (`entity_upsert`,
`fact_assert`, `facts_query`, `entity_resolve`, …), not through `import Wax`. Photo and
video pipelines remain package-only; there are no `photo_*` / `video_*` MCP tools. Store
transcripts or photo-derived text with MCP `remember` / `Memory.save` until a public
multimodal surface exists. Canonical MCP tool list: `Sources/WaxMCPServer/ToolSchemas.swift`.
