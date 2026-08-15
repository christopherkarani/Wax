# Wax Public API Reference

Public surface of `import Wax`. Nested types are shown qualified.

## Memory

- `public actor Memory`
- `init(at: URL, config: Memory.Config = .default) async throws`
- `init(at: URL, configure: (inout Memory.Config) -> Void) async throws`
- Embedder: `Memory.Config.embedding` (`Memory.EmbeddingSource`, default `.automatic`)
- `save(_ text: String, metadata: [String: String] = [:]) async throws`
- `save(_ texts: repeat each S) async throws` — no metadata
- `search(_ query: String, options: Memory.SearchOptions = .default) async throws -> Memory.Results`
- `search(_ query: String, configure: (inout Memory.SearchOptions) -> Void) async throws -> Memory.Results`
- Advanced strategy/reranker overloads exist
- `delete(frameID: UInt64) async throws` — id from `RAGContext.Item.frameId` only (`save` returns `Void`)
- `flush() async throws` / `close() async throws`
- `stats() async -> Memory.Stats`

### Memory.Config

`enableTextSearch` (true), `enableVectorSearch` (true), `enableStructuredMemory` (false),
`enableAccessStatsScoring` (false), `enableAsyncEnrichment` (false), `ingestConcurrency` (1),
`ingestBatchSize` (32), `requireOnDeviceProviders` (true), `embedding` (`.automatic`).

### Memory.EmbeddingSource

- `.automatic` — MiniLM when supported, else text-only on a **fresh** store
- `.builtIn(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions = .default)` — throws if unavailable
- `.custom(any EmbeddingProvider)`

### Memory.SearchOptions / RetrievalMode / TimeRange

- `Memory.SearchOptions(topK: Int = 10, includeSurrogates: Bool = false, timeRange: Memory.TimeRange? = nil, mode: Memory.RetrievalMode = .hybrid())`
- `Memory.RetrievalMode`: `.textOnly`, `.vectorOnly`, `.hybrid(alpha: Float = 0.5)`
  - **alpha weights the text lane** in RRF; `1 - alpha` weights vectors
- `Memory.TimeRange(afterMs: Int64? = nil, beforeMs: Int64? = nil)` — Unix milliseconds; either bound optional

### Memory.Results (= RAGContext)

- `query: String`, `items: [RAGContext.Item]`, `totalTokens: Int`, `diagnostics: RAGContext.Diagnostics?`
- `RAGContext.Diagnostics`: `requestedMode: String`, `effectiveMode: String`, `queryEmbeddingState: RAGContext.QueryEmbeddingState`
- `RAGContext.QueryEmbeddingState`: `.notRequested`, `.available`, `.timeout`, `.circuitOpen`, `.noEmbedder`, `.vectorDisabled`, `.failed`
- `RAGContext.Item`: `kind`, `frameId: UInt64`, `score: Float`, `sources: [RAGContext.Source]`, `text: String`, `metadata: [String: String]`, `explanations`
- `RAGContext.Source`: `.text`, `.vector`, `.timeline`, `.structured`, `.unknown` — use `item.sources.contains(.vector)`

### Memory.Stats

`frameCount: UInt64`, `pendingFrames: UInt64`, `vectorSearchEnabled: Bool`,
`queryEmbedderConfigured: Bool`, `queryEmbeddingCircuitOpen: Bool`,
`embedderIdentity: EmbeddingIdentity?`

## Embeddings

- `BuiltInEmbeddingProvider`: `.miniLM`, `.arctic`
- `BuiltInEmbeddings.make(_:options:)`
- `EmbeddingProvider` / `BatchEmbeddingProvider` / `EmbeddingIdentity` (`provider`/`model`/`dimensions`/`normalized` are optional fields)

## Errors

`Memory.Error` == `WaxError`. Common cases: `missingEmbedder`, `lockUnavailable`, `invalidEmbedding`,
`frameNotFound`, `featureDisabled`, `writerBusy`, `writerTimeout`, plus format/IO.
Many search-path failures surface as `WaxError.io(String)`.
`BuiltInEmbeddingProviderError.unavailable` when forcing a built-in that cannot load.

## Foundation Models (iOS 26 / macOS 26+)

See `references/foundation-models.md` for full integration.

- `Memory.foundationModelsSession(model:instructions:additionalTools:configuration:)` → `WaxFoundationModelSession`
- `Memory.foundationModelsTools(kit:config:)` / `foundationModelsMemoryTool(config:)` / `foundationModelsCombinedTools(config:)`
- `Memory.openFoundationModelsSession(at:…)` (session owns store; `close()` closes `Memory`)
- `WaxFoundationModelsAvailability.current()`
- Config: `FoundationModelsMemorySessionConfig` (`.default`, `.hybridBalanced`, `.toolsOnlyCompact`, `.promptOnlyLight`)
- Kits: `WaxMemoryToolKit` — `.focused`, `.compact`, `.combined`, `.focusedWithForget`

## Package-only (not for apps)

`MemoryOrchestrator`, Photo/Video RAG orchestrators, `Wax` actor, `WaxSession`, structured-memory types.
