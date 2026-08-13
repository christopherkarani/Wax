# Wax Public API Reference

This reference lists the **actually public** API surface of the Wax Swift package (`import Wax`). Types marked *package-only* are internal implementation details — they use Swift `package` access and cannot be named or constructed by downstream apps. Do not generate client code against package-only types.

## Memory (public facade)

Source: `Sources/Wax/Memory.swift`

- `public actor Memory`
- `public init(at url: URL, config: Memory.Config = .default) async throws`
  - Embedder selection lives on `config.embedding` (`Memory.EmbeddingSource`, default `.automatic`). With `.automatic` and `config.enableVectorSearch == true` (default), the built-in MiniLM embedder is wired on iOS 18/macOS 15+ (requires the default `MiniLMEmbeddings` package trait) using a 15s setup bound (`BuiltInEmbeddingProviderOptions.automatic`). Timeout or load failure falls back to text-only with `stats().embeddingStatus == .unavailable(reason:)`. `.builtIn(.miniLM)` still uses the 120s default and throws. On older OS versions or if the model is unavailable, the store runs text-only — check `stats()` or `RAGContext.diagnostics`.
- `public init(at url: URL, configure: @Sendable (inout Memory.Config) -> Void) async throws` — convenience closure form of the above. The configure closures on `init(at:configure:)` and `search(_:configure:)` are `@Sendable`.
- There is no `Memory(at:embedding:)` and no `Memory(at:config:embedding:)`.
- `public func save(_ text: String, metadata: [String: String] = [:]) async throws`
- `public func save<each S: StringProtocol>(_ texts: repeat each S) async throws`
- `public func search(_ query: String, options: Memory.SearchOptions = .default) async throws -> Memory.Results`
  - `SearchOptions.topK` (default 10) caps the returned item list and recomputes `totalTokens` from that list. Candidate depth for FastRAG assembly is `Memory.RAGConfig.searchTopK` (default 24), not `topK`.
- `public func search(_ query: String, configure: @Sendable (inout Memory.SearchOptions) -> Void) async throws -> Memory.Results`
- `public func search(_:strategy:options:)` / `search(_:strategy:options:reranker:)` with `SearchStrategy` / `ResultReranker`
- `public func delete(frameID: UInt64) async throws` — soft-deletes the frame and removes it from enabled text and vector indexes (committed).
- `public func flush() async throws` — commits pending writes (WAL, FTS, vector index) to durable storage. When enrichment is enabled, waits for the pipeline to drain.
- `public func close() async throws` — flushes with the same enrichment-drain contract as `flush()`, then closes. If the drain times out, `close()` throws and the store remains open.
- `public func stats() async -> Memory.Stats`

### Memory.Config

`public struct Config: Sendable` with `enableTextSearch` (true), `enableVectorSearch` (true), `enableStructuredMemory` (false), `enableAccessStatsScoring` (false), `enrichment: EnrichmentPolicy` (`.disabled`), `rag: RAGConfig` (`.default`), `ingestConcurrency` (1), `ingestBatchSize` (32), `requireOnDeviceProviders` (true), `embedding` (`.automatic`), `walSizeBytes` (`defaultWalSizeBytes` = 4 MiB); `public static let .default`.

### Memory.EmbeddingSource

`public enum EmbeddingSource: Sendable` — selects the embedder for a store:

- `.automatic` — built-in MiniLM when the platform/build supports it (15s setup bound); text-only fallback with `EmbeddingStatus.unavailable(reason:)` on timeout or load failure.
- `.builtIn(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions = .default)` — force a built-in provider; store creation throws `BuiltInEmbeddingProviderError.unavailable` when the provider is unavailable on this OS/build.
- `.custom(any EmbeddingProvider)` — bring your own embedder.

### Memory.RAGConfig / EnrichmentPolicy

- `Memory.RAGConfig`: `maxContextTokens` (1500), `searchTopK` (24), `answerRerankWindow` (12), `answerDistractorPenalty` (0.30). Clamped once into the package FastRAG builder.
- `Memory.EnrichmentPolicy`: `.disabled` / `.builtIn`. Selects whether the built-in keyword/entity enrichment pipeline runs.
- `Memory.EnrichmentStats`: `processedCount`, `pendingCount`, `isRunning` on `Memory.Stats.enrichment` when enrichment is `.builtIn`.

### Memory.SearchOptions / RetrievalMode / TimeRange

- `public struct SearchOptions` with `topK` (10; result cap only — see `search` above), `includeSurrogates` (false), `timeRange: TimeRange?` (nil), `mode: RetrievalMode` (`.hybrid()`).
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

`public struct Stats: Sendable, Equatable` with `frameCount`, `pendingFrames`, `vectorSearchEnabled`, `queryEmbedderConfigured`, `queryEmbeddingCircuitOpen`, `embedderIdentity: EmbeddingIdentity?`, `embeddingStatus`, `enrichment: EnrichmentStats?`.

## Structured memory (public on Memory)

Source: `Sources/Wax/Structured/Memory+Structured.swift`

Requires `config.enableStructuredMemory = true`. Otherwise throws `WaxError.featureDisabled(feature: "structured memory")`.

- `upsertEntity(key:kind:aliases:) -> EntityID`
- `resolveEntities(alias:limit:) -> [EntityMatch]`
- `assertFact(subject:predicate:object:relation:validFromMs:validToMs:) -> FactID`
- `retractFact(_:atMs:)`
- `facts(subject:predicate:systemAsOfMs:validAsOfMs:limit:) -> FactsResult` — field is `.hits`, not `.facts`
- `edges(for:direction:predicate:systemAsOfMs:validAsOfMs:limit:) -> EdgesResult`

DTOs: `Memory.EntityMatch`, `Memory.FactHit`, `Memory.FactsResult`, `Memory.FactID`, `Memory.EntityID`, `Memory.FactValue`, `Memory.FactRelation`, `Memory.Edge`, `Memory.EdgeDirection`.

## PhotoMemory / VideoMemory

Source: `Sources/Wax/PhotoRAG/PhotoMemory.swift`, `Sources/Wax/VideoRAG/VideoMemory.swift`

- `PhotoMemory.open(at:embedding:ocr:captioner:config:)` — owning facade. `ingest(files: [PhotoMemory.File])`, `search(PhotoMemory.Query) -> PhotoMemory.Results` with `assetID` and `thumbnail: Data?`.
- `VideoMemory.open(at:embedding:transcriptProvider:config:)` — analogous. Host supplies `VideoTranscriptProvider`; Wax does not transcribe.
- `MultimodalEmbeddingProvider`: `dimensions`, `normalize`, `identity`, `executionMode` (`.onDeviceOnly` / `.mayUseNetwork`), `embed(text:)`, `embed(imageData:format:)`.

## Built-in Embeddings

Source: `Sources/Wax/BuiltInEmbeddings.swift`

- `public enum BuiltInEmbeddingProvider { case miniLM, arctic }`
  - `.miniLM` — all-MiniLM-L6-v2 CoreML embedder; iOS 18/macOS 15+, default `MiniLMEmbeddings` trait (~43 MiB bundle).
  - `.arctic` — Snowflake Arctic Embed Small; iOS 18/macOS 15+, `ArcticEmbeddings` trait (~32 MiB bundle).
- `public enum BuiltInEmbeddings { public static func make(_:options:) async throws -> any EmbeddingProvider }`
- `public struct BuiltInEmbeddingProviderOptions` (`batchSize`, `prewarmBatchSize`, `allowLowPrecisionGPU`, `timeoutSeconds`, `computeUnitsOrder`).
- `public enum BuiltInEmbeddingComputeUnit { cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all }`
- `public enum BuiltInEmbeddingProviderError: LocalizedError { case unavailable(BuiltInEmbeddingProvider) }`

Package traits: default includes `MiniLMEmbeddings`. `traits: []` compiles no built-in model. GRDB, MetalANNS, swift-crypto, and swift-asn1 remain in the core graph. SwiftNIO / MCP SDK are not part of ordinary `import Wax` consumers.

## Embedding Protocols (public, via WaxVectorSearch)

Source: `Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift`

- `public protocol EmbeddingProvider: Sendable` — `dimensions`, `normalize`, `identity`, `func embed(_:) async throws -> [Float]`. Optional `executionMode: ProviderExecutionMode`.
- `public protocol BatchEmbeddingProvider: EmbeddingProvider` — `func embed(batch:) async throws -> [[Float]]`.
- `public struct EmbeddingIdentity` (`provider`, `model`, `dimensions`, `normalized`).
- `public enum ProviderExecutionMode { case onDeviceOnly, mayUseNetwork }`

## Errors

- `public enum WaxError` (WaxCore) — `Memory.Error` typealias. Catchable cases include `featureDisabled(feature:)` (API requires a config feature that is off), `missingEmbedder` (vector search enabled but no embedder configured), `invalidEmbedding(reason:)` (provider returned a bad vector), `frameNotFound(frameId:)`, `capacityExceeded(limit:requested:)`, `lockUnavailable`, `writerBusy`, `writerTimeout`, plus format/IO cases (`invalidHeader`, `invalidFooter`, `invalidToc`, `encodingError`, `decodingError`, `walCorruption`, `checksumMismatch`, `io`).
- `WaxFoundationModelsError` — typed Foundation Models adapter failures (`unavailable`, `generationInProgress`, `iteratorAlreadyCreated`, `contextWindowExceeded`, `cancelled`, `generationFailed`, …).

## Foundation Models Tools (iOS 26/macOS 26+)

When `canImport(FoundationModels)`:

- `memory.foundationModelsSession(...)` — nonthrowing, does not own `Memory`, does not preflight.
- `memory.makeFoundationModelsSession(...)` — preflights `WaxFoundationModelsAvailability`, prewarms, does not own `Memory`.
- `Memory.openFoundationModelsSession(...)` — owns the store; `close()` closes `Memory`.
- `memory.foundationModelsTools(kit:config:)` / `Memory.openFoundationModelsTools(...)` (owning `WaxFoundationModelsToolSession`).
- Streaming: `WaxGenerationStream` of `Event.content` / `Event.completed`.

## Package-only (NOT public API)

The following are `package`-access internals. They are used by Wax's own CLI/MCP server and tests, but **cannot be imported or constructed by downstream apps**:

- `MemoryOrchestrator`, `OrchestratorConfig`, `FastRAGConfig` (the engine behind `Memory`)
- `PhotoRAGOrchestrator`, `VideoRAGOrchestrator` (use `PhotoMemory` / `VideoMemory`)
- `WaxSession`, `Wax` actor, `SearchRequest`, `SearchResponse`, `FrameFilter`, core structured-memory types (`EntityKey`, …)
- `MiniLMEmbedder` (use `BuiltInEmbeddings.make(.miniLM)` or `Memory.Config.embedding = .builtIn(.miniLM)` instead)
