# Wax Public API Reference

This reference lists the **actually public** API surface of the Wax Swift package (`import Wax`). Types marked *package-only* are internal implementation details — they use Swift `package` access and cannot be named or constructed by downstream apps. Do not generate client code against package-only types.

## Memory (public facade)

Source: `Sources/Wax/Memory.swift`

- `public actor Memory`
- `public init(at url: URL, config: Memory.Config = .default) async throws`
  - Embedder selection lives on `config.embedding` (`Memory.EmbeddingSource`, default `.automatic`). With `.automatic` and `config.enableVectorSearch == true` (default), the store opens while the built-in MiniLM provider loads (default `MiniLMEmbeddings` trait, iOS 18/macOS 15+), then live-attaches. Hybrid search is text until attach; `vectorOnly` throws. If no provider activates, status is `unavailable` and any existing vector index remains. Check `stats().embeddingStatus` or `RAGContext.diagnostics`.
- `public init(at url: URL, configure: (inout Memory.Config) -> Void) async throws` — convenience closure form of the above.
- `public func save(_ text: String, metadata: [String: String] = [:]) async throws`
- `public func save<each S: StringProtocol>(_ texts: repeat each S) async throws`
- `public func search(_ query: String, options: Memory.SearchOptions = .default) async throws -> Memory.Results`
- `public func search(_ query: String, configure: (inout Memory.SearchOptions) -> Void) async throws -> Memory.Results`
- `public func search(_ query: String, strategy: (any SearchStrategy)?, reranker: (any ResultReranker)? = nil, options: Memory.SearchOptions = .default) async throws -> Memory.Results`
- Deprecated aliases: `search(_:strategy:options:)` and `search(_:strategy:options:reranker:)` (generic shims; use the existential form)
- `public func delete(frameID: UInt64) async throws` — soft-deletes the frame and removes it from enabled text and vector indexes (committed).
- `public func flush() async throws` — commits pending writes (WAL, FTS, vector index) to durable storage.
- `public func backfillUnembedded() async throws -> UInt64` — embeds live searchable frames that have no vectors using the attached provider. Idempotent. Throws `WaxError.missingEmbedder` when no provider is attached; never invents vectors. Call `flush()` to commit.
- `public func close() async throws` — flushes, then closes.
- `public func stats() async -> Memory.Stats`

### Memory.Config

`public struct Config: Sendable` with `enableTextSearch` (true), `enableVectorSearch` (true), `enableStructuredMemory` (false), `enableAccessStatsScoring` (true), `enableAsyncEnrichment` (false), `ingestConcurrency` (1), `ingestBatchSize` (32), `requireOnDeviceProviders` (true), `embedding` (`.automatic`); `public static let .default`. `enableAccessStatsScoring` applies a bounded rank offset from stored access stats. Search and recall are non-mutating; stats accrue from explicit get/promote (`memory_get` / `memory_promote`). Access stats persist as a system frame, not a user-visible content frame.

### Memory.EmbeddingSource

`public enum EmbeddingSource: Sendable` — selects the embedder for a store:

- `.automatic` — open immediately while the built-in MiniLM provider loads; live-attach when compile finishes. Status `unavailable` if it cannot activate (index remains; hybrid is text).
- `.builtIn(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions = .default)` — force a built-in provider; store creation throws `BuiltInEmbeddingProviderError.unavailable` when the provider is missing on this OS/build, or `BuiltInEmbeddingProviderError.timedOut` when compile exceeds `timeoutSeconds`.
- `.custom(any EmbeddingProvider)` — bring your own embedder.

### Memory.SearchOptions / RetrievalMode / TimeRange

- `public struct SearchOptions` with `topK` (10), `includeSurrogates` (false), `timeRange: TimeRange?` (nil), `mode: Memory.RetrievalMode` (`.hybrid()`).
- `public enum SearchMode: Sendable, Equatable, CustomStringConvertible { case textOnly, vectorOnly, hybrid(alpha: Float = 0.5) }` — module-scope canonical lane type. `Memory.RetrievalMode` is a public typealias of `SearchMode`; both names are valid in app code. `diagnosticsSummary` / `CustomStringConvertible` yield the stable `"text"` / `"vector"` / `"hybrid(alpha=0.500)"` form used by docs, MCP, and broker.
  - `.hybrid` degrades to the text lane when no embedder is available; `.vectorOnly` throws when vector search is unavailable. Check `RAGContext.diagnostics` for what actually ran.
- `public struct TimeRange { afterMs: Int64?, beforeMs: Int64? }`

### Memory.Results (RAGContext)

Source: `Sources/Wax/RAG/RAGContext.swift`

- `public typealias Memory.Results = RAGContext`
- `public struct RAGContext: Sendable, Equatable`
  - `public var query: String`, `public var items: [Item]`, `public var totalTokens: Int`
  - `public var diagnostics: RAGContext.Diagnostics?` — requested vs. effective retrieval mode plus query-embedding state. `nil` only for contexts built outside the retrieval pipeline.
- `RAGContext.Diagnostics`: `requestedMode: SearchMode`, `effectiveMode: SearchMode`, `queryEmbeddingState: QueryEmbeddingState`. Use `SearchMode.diagnosticsSummary` (or `String(describing:)`) for the historical wire/docs strings (`"text"`, `"vector"`, `"hybrid(alpha=…)"`).
- `RAGContext.QueryEmbeddingState`: `.notRequested`, `.available`, `.timeout`, `.circuitOpen`, `.noEmbedder`, `.vectorDisabled`, `.failed`.
- `RAGContext.Item`: `kind` (`.snippet`/`.expanded`/`.surrogate`), `frameId`, `score`, `sources` (`.text`/`.vector`/`.timeline`/`.structured`/`.unknown`), `text`, `metadata`, `explanations`.
  - `score` is the rank key used to order hits. It is not a probability. Hybrid fusion may scale fused ranks to `0...1`; intent or semantic rerank may then write an unbounded composite onto the same field.

### Memory.Stats

`public struct Stats: Sendable, Equatable` with `frameCount`, `pendingFrames`, `vectorSearchEnabled`, `queryEmbedderConfigured`, `queryEmbeddingCircuitOpen`, `embedderIdentity: EmbeddingIdentity?`, `embeddingStatus: EmbeddingStatus`, `framesWithoutVectors`.

`queryEmbedderConfigured` is derived: `true` only for `active` and `degraded`.

### EmbeddingStatus

`public enum EmbeddingStatus: Sendable, Equatable`

- `.disabled` — vector search was explicitly turned off
- `.loading` — a provider is compiling; text operations remain available
- `.active(EmbeddingIdentity?)` — provider ready
- `.degraded(EmbeddingIdentity?, reason: String)` — provider ready, some existing frames have no vectors
- `.unavailable(reason: String)` — no provider could be activated; a vector index may still exist
- `isQueryEmbedderConfigured` — `true` only for `active` and `degraded`

## Built-in Embeddings

Source: `Sources/Wax/BuiltInEmbeddings.swift`

- `public enum BuiltInEmbeddingProvider { case miniLM, arctic }`
  - `.miniLM` — all-MiniLM-L6-v2 CoreML embedder; iOS 18/macOS 15+, default `MiniLMEmbeddings` trait.
  - `.arctic` — Snowflake Arctic Embed Small; iOS 18/macOS 15+, `ArcticEmbeddings` trait.
- `public enum BuiltInEmbeddings { public static func make(_:options:) async throws -> any EmbeddingProvider }`
- `public struct BuiltInEmbeddingProviderOptions` (`batchSize`, `prewarmBatchSize`, `allowLowPrecisionGPU`, `timeoutSeconds`, `computeUnitsOrder`).
- `public enum BuiltInEmbeddingComputeUnit { cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all }`
- `public enum BuiltInEmbeddingProviderError: LocalizedError { case unavailable(BuiltInEmbeddingProvider), timedOut(BuiltInEmbeddingProvider) }`

## Embedding Protocols (public, via WaxVectorSearch)

Source: `Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift`

- `public protocol EmbeddingProvider: Sendable` — `dimensions`, `normalize`, `identity`, `func embed(_:) async throws -> [Float]`. Optional `executionMode: ProviderExecutionMode`.
- `public protocol BatchEmbeddingProvider: EmbeddingProvider` — `func embed(batch:) async throws -> [[Float]]`.
- `public protocol QueryAwareEmbeddingProvider: EmbeddingProvider` — `func embedQuery(_:) async throws -> [Float]` for retrieval-optimized query embeddings.
- `public struct EmbeddingIdentity` (`provider`, `model`, `dimensions`, `normalized`).

## Errors

- `public enum WaxError` (WaxCore) — `Memory.Error` typealias. Catchable cases include `featureDisabled(feature:)` (API requires a config feature that is off), `missingEmbedder` (vector search enabled but no embedder configured), `invalidEmbedding(reason:)` (provider returned a bad vector), `vectorIndexNotStaged` (a commit was attempted with pending embeddings but no staged vector index), `frameNotFound(frameId:)`, `capacityExceeded(limit:requested:)`, `lockUnavailable`, `writerBusy`, `writerTimeout`, plus format/IO cases (`invalidHeader`, `invalidFooter`, `invalidToc`, `encodingError`, `decodingError`, `walCorruption`, `checksumMismatch`, `io`).

## Foundation Models Tools (iOS 26/macOS 26+)

When `canImport(FoundationModels)`: `memory.foundationModelsMemoryTool()`, `memory.foundationModelsTools(kit:)`, `memory.foundationModelsCombinedTools()` expose remember/recall/search as on-device model tools.

## Photo and video memory (experimental, Darwin)

Sources: `Sources/Wax/PhotoRAG/PhotoMemory.swift`, `Sources/Wax/VideoRAG/VideoMemory.swift`, `Sources/Wax/Embeddings/BuiltInMultimodalEmbeddings.swift`

Available when `canImport(ImageIO)`. These are the public facades. Do not construct `PhotoRAGOrchestrator` or `VideoRAGOrchestrator`.

- `public actor PhotoMemory` — ingest Photos assets or local files, OCR, multimodal embeddings, ranked photo recall
- `public actor VideoMemory` — segment videos, embed keyframes, optional host-supplied transcripts, ranked segment recall
- `public enum BuiltInMultimodalEmbeddings { public static func make(_:options:) async throws -> any MultimodalEmbeddingProvider }`
- `public protocol MultimodalEmbeddingProvider` — shared image + text embedder for the photo/video facades
- Supporting public types: `PhotoRAGConfig`, `PhotoFile`, `PhotoQuery`, `PhotoScope`, `PhotoRAGContext`, `VideoRAGConfig`, `VideoFile`, `VideoQuery`, `VideoScope`, `VideoRAGContext`, `VideoTranscriptProvider`, `VisionOCRProvider`

```swift
let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
let photos = try await PhotoMemory(at: storeURL, embedder: embedder, ocr: VisionOCRProvider())
try await photos.ingest(files: [PhotoFile(id: "receipt-1", url: imageURL)])
let context = try await photos.recall(PhotoQuery(text: "coffee receipt"))
try await photos.close()
```

Video does not transcribe and does not store media bytes. The host supplies transcripts.

## Migration

- `OrchestratorConfig.useMetalVectorSearch` is a deprecated `package` shim. Use `vectorEnginePreference` (`true` → `.auto`, `false` → `.cpuOnly`).
- Hybrid search may run as text-only; compare `RAGContext.diagnostics.requestedMode` with `effectiveMode` (and `queryEmbeddingState`).
- `Memory.search(_:strategy:options:)` and `Memory.search(_:strategy:options:reranker:)` are deprecated shims. Use `search(_:strategy:reranker:options:)` with `any SearchStrategy` / `any ResultReranker`.

## Package-only (NOT public API)

The following are `package`-access internals. They are used by Wax's own CLI/MCP server and tests, but **cannot be imported or constructed by downstream apps**:

- `MemoryOrchestrator`, `OrchestratorConfig`, `FastRAGConfig` (the engine behind `Memory`)
- `PhotoRAGOrchestrator`, `VideoRAGOrchestrator` (engines behind `PhotoMemory` / `VideoMemory`)
- `WaxSession`, `Wax` actor, `SearchRequest`, `SearchResponse`, `FrameFilter`, structured-memory types (`EntityKey`, facts)
- `MiniLMEmbedder` (use `BuiltInEmbeddings.make(.miniLM)` or `Memory.Config.embedding = .builtIn(.miniLM)` instead)

Structured memory (entities/facts) stays MCP/broker-facing, not a public Swift CRUD API.
