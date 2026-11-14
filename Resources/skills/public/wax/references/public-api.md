# Wax Public API Reference

This reference lists the **actually public** API surface of the Wax Swift package (`import Wax`). Types marked *package-only* are internal implementation details — they use Swift `package` access and cannot be named or constructed by downstream apps. Do not generate client code against package-only types.

## Memory (public facade)

Source: `Sources/Wax/Memory.swift`

- `public actor Memory`
- `public init(at url: URL, config: Memory.Config = .default) async throws`
  - Embedder selection lives on `config.embedding` (`Memory.EmbeddingSource`, default `.automatic`). With `.automatic` and `config.enableVectorSearch == true` (default), the store opens while a built-in provider loads (iOS 18/macOS 15+), then live-attaches: e5 for a new store (default `E5Embeddings` trait), and for an existing store the built-in that wrote its vectors (a MiniLM store keeps MiniLM). Hybrid search is text until attach; `vectorOnly` throws. If no provider activates, status is `unavailable` and any existing vector index remains. Check `stats().embeddingStatus` or `RAGContext.diagnostics`.
  - Opening waits for another process's lock on the store file for at most 30 seconds, then throws `WaxError.lockUnavailable`. Earlier releases waited indefinitely. Share one process (for example the MCP HTTP server) per store instead of opening it from several.
  - `Memory` owns the store it opens: if the text index is missing frames (after a crash, or frames written without one), opening indexes them and `close()` commits that. A store opened only to read can therefore still be written once on close.
- `public init(at url: URL, configure: (inout Memory.Config) -> Void) async throws` — convenience closure form of the above.
- `@discardableResult public func save(_ text: String, metadata: [String: String] = [:]) async throws -> UInt64` — returns the saved document's frame ID (pass it to `delete(frameID:)`). Re-saving identical text and metadata returns the existing ID. Text longer than one chunk is also indexed as chunk frames, whose IDs appear in search results.
- `@discardableResult public func save(contentsOf texts: some Sequence<String>, metadata: [String: String] = [:]) async throws -> [UInt64]` — saves many texts with shared metadata, embedding and writing them in batches. Returns one frame ID per text, in input order: what `save(_:metadata:)` would return for each in turn, including the existing ID for a text already stored or repeated earlier in the batch. **Not atomic**: if it throws, earlier texts may already be saved.
- `@discardableResult public func save(contentsOf documents: some Sequence<(text: String, metadata: [String: String])>) async throws -> [UInt64]` — the same with per-document metadata.
- `public func save<each S: StringProtocol>(_ texts: repeat each S) async throws` — saves each text in order. **Not atomic**: if one save throws, earlier texts stay saved.
- `public func search(_ query: String, options: Memory.SearchOptions = .default) async throws -> Memory.Results`
- `public func search(_ query: String, configure: (inout Memory.SearchOptions) -> Void) async throws -> Memory.Results`
- `public func search(_ query: String, strategy: (any SearchStrategy)?, reranker: (any ResultReranker)? = nil, options: Memory.SearchOptions = .default) async throws -> Memory.Results`
- Deprecated aliases: `search(_:strategy:options:)` and `search(_:strategy:options:reranker:)` (generic shims; use the existential form)
- `public func delete(frameID: UInt64) async throws` — soft-deletes the frame and removes it from enabled text and vector indexes (committed). Deleting a document frame (the ID `save` returns) also deletes its chunk frames and anything derived from them, even when the document itself was already deleted.
- `public func flush() async throws` — commits pending writes (WAL, FTS, vector index) to durable storage.
- `public func backfillUnembedded() async throws -> UInt64` — embeds live searchable frames that have no vectors using the attached provider. Idempotent. Throws `WaxError.missingEmbedder` when no provider is attached; never invents vectors. Call `flush()` to commit.
- `public func close() async throws` — flushes, then closes.
- `public func stats() async -> Memory.Stats`

### Memory.Config

`public struct Config: Sendable` with `enableTextSearch` (true), `enableVectorSearch` (true), `enableStructuredMemory` (false), `enableAccessStatsScoring` (true), `enableAsyncEnrichment` (false), `ingestConcurrency` (1), `ingestBatchSize` (32), `requireOnDeviceProviders` (true), `embedding` (`.automatic`), `reranking` (`.disabled`); `public static let .default`. `enableAccessStatsScoring` applies a bounded rank offset from stored access stats. Search and recall are non-mutating; stats accrue from explicit get/promote (`memory_get` / `memory_promote`). Access stats persist as a system frame, not a user-visible content frame.

### Memory.EmbeddingSource

`public enum EmbeddingSource: Sendable` — selects the embedder for a store:

- `.automatic` — open immediately while a built-in provider loads (e5 for a new store, the store's own built-in for an existing one); live-attach when compile finishes. Status `unavailable` if it cannot activate (index remains; hybrid is text).
- `.builtIn(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions = .default)` — force a built-in provider; store creation throws `BuiltInEmbeddingProviderError.unavailable` when the provider is missing on this OS/build, or `BuiltInEmbeddingProviderError.timedOut` when compile exceeds `timeoutSeconds`.
- `.custom(any EmbeddingProvider)` — bring your own embedder.

### Memory.RerankingSource

`public enum RerankingSource: Sendable` — selects the reranker, if any, that reorders each search's top candidates before context assembly (`config.reranking`):

- `.disabled` (default) — results keep their retrieval order.
- `.builtIn(BuiltInReranker, RerankingOptions = .default)` — a built-in reranker on the CPU; store creation throws `BuiltInRerankerError.unavailable` when its trait is not enabled or the OS is older than iOS 18/macOS 15.
- `.custom(any RerankingProvider, RerankingOptions = .default)` — your own reranker, or one from `BuiltInRerankers.make(_:computeUnit:timeoutSeconds:)` to run a built-in one on another compute unit.

The reranker scores the full frame text of the first `candidateCount` candidates (a chunk frame's chunk, otherwise the saved text). The search fetches at least `candidateCount` candidates even when `topK` is smaller, so reranking can promote a candidate into the results; candidates below the window keep their order after it. Item scores stay the retrieval scores (the order changes) and each reranked item gains a `rerank:` explanation. A reranker error, a score count that differs from the document count, or a non-finite score makes `search` throw.

### Memory.SearchOptions / RetrievalMode / TimeRange

- `public struct SearchOptions` with `topK` (10), `includeSurrogates` (false), `timeRange: TimeRange?` (nil), `mode: Memory.RetrievalMode` (unset), `maxContextTokens: Int?` (nil), `inferTimeRange: Bool` (true). The initializer takes `mode: Memory.RetrievalMode? = nil`.
  - `mode` — unset searches hybrid at the store's default text weight: 0.4 when the store's embedder is e5-small-v2, 0.5 otherwise. Reading an unset `mode` returns `.hybrid()`. A mode passed to the initializer or assigned to `mode` (`.hybrid()` included) is used as given. `RAGContext.Diagnostics` reports the weight that ran.
  - `maxContextTokens` — token budget for the returned `RAGContext`. `nil` uses the store default (1,500). Values are clamped to `Memory.SearchOptions.maxContextTokensRange` (`64...32_768`). Raise it when a large `topK` returns fewer items than requested.
  - `inferTimeRange` — when `true` and `timeRange` is `nil`, a past-looking phrase in the query ("yesterday", "last week", "last month") filters results to memories saved in that window. Future-looking phrases ("tomorrow", "next week") never filter, because they describe event time, not save time; a past phrase elsewhere in the same query still can. The applied window is reported in `RAGContext.Diagnostics.inferredTimeRange`. Set `false` to search all time.
- `public enum SearchMode: Sendable, Equatable, CustomStringConvertible { case textOnly, vectorOnly, hybrid(alpha: Float = 0.5) }` — module-scope canonical lane type. `Memory.RetrievalMode` is a public typealias of `SearchMode`; both names are valid in app code. `diagnosticsSummary` / `CustomStringConvertible` yield the stable `"text"` / `"vector"` / `"hybrid(alpha=0.500)"` form used by docs, MCP, and broker.
  - `.hybrid` degrades to the text lane when no embedder is available; `.vectorOnly` throws when vector search is unavailable. Check `RAGContext.diagnostics` for what actually ran.
- `public struct TimeRange { afterMs: Int64?, beforeMs: Int64? }` — milliseconds since 1970, `afterMs` inclusive, `beforeMs` exclusive.

### Memory.Results (RAGContext)

Source: `Sources/Wax/RAG/RAGContext.swift`

- `public typealias Memory.Results = RAGContext`
- `public struct RAGContext: Sendable, Equatable`
  - `public var query: String`, `public var items: [Item]`, `public var totalTokens: Int`
  - `public var diagnostics: RAGContext.Diagnostics?` — requested vs. effective retrieval mode plus query-embedding state. `nil` only for contexts built outside the retrieval pipeline.
- `RAGContext.Diagnostics`: closed retrieval record. Read computed `requestedMode: SearchMode`, `effectiveMode: SearchMode`, `queryEmbeddingState: QueryEmbeddingState`. There is no public memberwise init that accepts an arbitrary requested×effective×state triple — hybrid/vector **effective** retrieval always implies `queryEmbeddingState == .available`. `Memory.search` produces this value. Use `SearchMode.diagnosticsSummary` (or `String(describing:)`) for the historical wire/docs strings (`"text"`, `"vector"`, `"hybrid(alpha=…)"`). MCP JSON keys stay those strings via `diagnosticsSummary` / `QueryEmbeddingState.rawValue`.
- `RAGContext.Diagnostics.inferredTimeRange: Memory.TimeRange?` — the save-time window Wax inferred from the query and applied (see `SearchOptions.inferTimeRange`). `nil` when nothing was inferred, inference is off, or the caller passed `timeRange`.
- `RAGContext.QueryEmbeddingState`: `.notRequested`, `.available`, `.timeout`, `.circuitOpen`, `.noEmbedder`, `.vectorDisabled`, `.failed`, `.vectorsRebuilding` (stored vectors come from a superseded model revision and are being re-embedded; the text lane was used, and vector-only search throws `WaxError.vectorsRebuilding` until it finishes).
- `RAGContext.Item`: `kind` (`.snippet`/`.expanded`/`.surrogate`), `frameId`, `score`, `sources` (`.text`/`.vector`/`.timeline`/`.structured`/`.unknown`), `text`, `metadata`, `explanations`.
  - `score` is the rank key used to order hits. It is not a probability. Hybrid fusion may scale fused ranks to `0...1`; intent or semantic rerank may then write an unbounded composite onto the same field.

### Memory.Stats

`public struct Stats: Sendable, Equatable` with `frameCount`, `pendingFrames`, `vectorSearchEnabled`, `queryEmbedderConfigured`, `queryEmbeddingCircuitOpen`, `embedderIdentity: EmbeddingIdentity?`, `embeddingStatus: EmbeddingStatus`, `framesWithoutVectors` (`0` when vector coverage cannot be read; `embeddingStatus` is then `.degraded` with a "vector coverage unknown" reason), `walReplayTruncationCount` (1 when open dropped a torn tail of uncommitted writes after a crash).

`queryEmbedderConfigured` is derived: `true` only for `active` and `degraded`.

### EmbeddingStatus

`public enum EmbeddingStatus: Sendable, Equatable`

- `.disabled` — vector search was explicitly turned off
- `.loading` — a provider is compiling; text operations remain available
- `.active(EmbeddingIdentity?)` — provider ready
- `.degraded(EmbeddingIdentity?, reason: String)` — provider ready, but some existing frames have no vectors, or (reason `"vectors from superseded MiniLM revision"`) the stored vectors come from the pre-mean-pooling MiniLM. In that case the store re-embeds every frame that has a vector, starting when it opens, while search uses the text lane. Progress is committed as it goes, so a store closed mid-way resumes where it stopped. When it finishes, the store is rebound to `MiniLMAll-mean`; older Wax builds then refuse to open it.
- `.unavailable(reason: String)` — no provider could be activated; a vector index may still exist
- `isQueryEmbedderConfigured` — `true` only for `active` and `degraded`

## FrameStore (low-level payload store)

Source: `Sources/Wax/FrameStore.swift`

`public actor FrameStore` — durable frame storage without search indexes, for packages that need raw payloads on the Wax file format.

- `public static func create(at url: URL, walSize: UInt64 = FrameStore.defaultWalSize) async throws -> FrameStore`
- `public static func open(at url: URL) async throws -> FrameStore`
- `@discardableResult public func put(_ content: Data, kind: String, metadata: [String: String] = [:]) async throws -> UInt64` — writes and commits one frame.
- `public func frames() async throws -> [FrameStore.Frame]`, `public func content(frameID: UInt64) async throws -> Data`, `public func delete(frameID: UInt64) async throws`, `public func close() async throws`
- `FrameStore.Frame` (`id`, `kind`, `metadata`, `status: FrameStore.Status` (`.active` / `.deleted`), `supersededBy`)

Use `Memory` for text memory and search. `FrameStore` frames are not indexed.

## Built-in Embeddings

Source: `Sources/Wax/BuiltInEmbeddings.swift`

- `public enum BuiltInEmbeddingProvider { case miniLM, arctic, e5 }`
  - `.miniLM` — all-MiniLM-L6-v2 embedder; iOS 18/macOS 15+ (Core ML) or Linux, default `MiniLMEmbeddings` trait.
  - `.arctic` — Snowflake Arctic Embed Small; iOS 18/macOS 15+ (Core ML) or Linux, `ArcticEmbeddings` trait.
  - `.e5` — `intfloat/e5-small-v2` (MIT), mean pooling, `"query: "` / `"passage: "` prefixes; iOS 18/macOS 15+ (Core ML) or Linux, `E5Embeddings` trait.
  - On Linux the built-ins run the same bundled models on Wax's CPU interpreter and record the same `EmbeddingIdentity`, so stores move between platforms. Compute units in `BuiltInEmbeddingProviderOptions` apply to Core ML only and are ignored there.
- `public enum BuiltInEmbeddings { public static func make(_:options:) async throws -> any EmbeddingProvider }`
- `public struct BuiltInEmbeddingProviderOptions` (`batchSize`, `prewarmBatchSize`, `allowLowPrecisionGPU`, `timeoutSeconds`, `computeUnitsOrder`).
- `public enum BuiltInEmbeddingComputeUnit { cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all }`
- `public enum BuiltInEmbeddingProviderError: LocalizedError { case unavailable(BuiltInEmbeddingProvider), timedOut(BuiltInEmbeddingProvider) }`

## Built-in Reranking

Source: `Sources/Wax/Reranking/Reranking.swift`

- `public enum BuiltInReranker { case msMarcoMiniLM }` — `cross-encoder/ms-marco-MiniLM-L-6-v2` (Apache-2.0), 22 MB INT8 weights: Core ML with FP16 compute on iOS 18/macOS 15+, Wax's CPU interpreter with FP32 compute on Linux (`computeUnit` is ignored there); `MiniLMReranker` trait. Each document is cut into 288-token `[CLS] query [SEP] window [SEP]` rows that share 64 tokens, up to 16 per document, and scored as the maximum over its windows.
- `public struct RerankingOptions` — `candidateCount` (20, clamped to `RerankingOptions.candidateCountRange`, `1...200`) and `fusion` (`.reciprocalRank(k: 10)`).
- `public enum RerankingFusion { case rerankerOrder, reciprocalRank(k: Int) }` — order by reranker score alone, or fuse `1/(k + retrievalRank) + 1/(k + rerankerRank)`; ties keep the retrieval order.
- `public enum BuiltInRerankers { public static func make(_:computeUnit:timeoutSeconds:) async throws -> any RerankingProvider }` — loads are cached per compute unit for the process.
- `public enum BuiltInRerankerError: LocalizedError { case unavailable(BuiltInReranker), timedOut(BuiltInReranker) }`
- `public protocol RerankingProvider: Sendable` (WaxVectorSearch, `Sources/WaxVectorSearch/Reranking/RerankingProvider.swift`) — `func scores(query: String, documents: [String]) async throws -> [Float]`: one finite score per document, higher is more relevant, comparable within one call.

`Memory.search(_:strategy:reranker:options:)` and `ResultReranker` are a different hook: they reorder the finished `RAGContext` (its snippet text and `topK` items), after context assembly.

## Embedding Protocols (public, via WaxVectorSearch)

Source: `Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift`

- `public protocol EmbeddingProvider: Sendable` — `dimensions`, `normalize`, `identity`, `func embed(_:) async throws -> [Float]`. Optional `executionMode: ProviderExecutionMode` and `similarity: VectorSimilarity` (default `.cosine`).
- `public enum VectorSimilarity: String, Sendable, Equatable { case cosine, dotProduct }` — how the store ranks the provider's vectors. `.dotProduct` ranks by raw inner product (for dot-product-trained models such as `facebook/contriever`; pair it with `normalize = false`, since with `normalize = true` it ranks like cosine), and its vector-lane scores are not bounded to `-1...1`. A store records its similarity when it first commits vectors; opening it with an embedder that declares another one throws `WaxError.io` ("vector similarity mismatch"), and a provider that attaches later is reported `unavailable`. Changing similarity needs a new store.
- `public protocol BatchEmbeddingProvider: EmbeddingProvider` — `func embed(batch:) async throws -> [[Float]]`.
- `public protocol QueryAwareEmbeddingProvider: EmbeddingProvider` — `func embedQuery(_:) async throws -> [Float]` for retrieval-optimized query embeddings.
- `public struct EmbeddingIdentity` (`provider`, `model`, `dimensions`, `normalized`).

## Errors

- `public enum WaxError` (WaxCore) — `Memory.Error` typealias. Catchable cases include `featureDisabled(feature:)` (API requires a config feature that is off), `missingEmbedder` (vector search enabled but no embedder configured), `invalidEmbedding(reason:)` (provider returned a bad vector), `vectorIndexNotStaged` (a commit was attempted with pending embeddings before the store had a vector index or a declared dimension and similarity), `vectorsRebuilding(reason:progress:)` (vector-only search while vectors from a superseded model revision are re-embedded; `progress` is 0...1, text and hybrid search keep working), `frameNotFound(frameId:)`, `capacityExceeded(limit:requested:)`, `lockUnavailable`, `writerBusy`, `writerTimeout`, plus format/IO cases (`invalidHeader`, `invalidFooter`, `invalidToc`, `encodingError`, `decodingError`, `walCorruption`, `checksumMismatch`, `io`).

## Foundation Models Tools (iOS 26/macOS 26+)

When `canImport(FoundationModels)`: `memory.foundationModelsMemoryTool()`, `memory.foundationModelsTools(kit:)`, `memory.foundationModelsCombinedTools()` expose remember/recall/search as on-device model tools.

- `public enum Memory.EmbeddingPolicy { case automatic, always, never }` — retrieval lane for the tools and session config (`WaxMemoryToolConfig.embeddingPolicy`, session config `embeddingPolicy`): `.automatic` → hybrid, `.always` → vector-only, `.never` → text-only. `WaxMemoryToolConfig.init` takes `searchAlpha: Float? = nil`; with no `searchAlpha` and no per-call `alpha`, hybrid uses the store's default text weight (0.4 for e5-small-v2 stores, 0.5 otherwise), and reading `searchAlpha` returns 0.5.

## Photo and video memory (experimental, Darwin)

Sources: `Sources/Wax/PhotoRAG/PhotoMemory.swift`, `Sources/Wax/VideoRAG/VideoMemory.swift`, `Sources/Wax/Embeddings/BuiltInMultimodalEmbeddings.swift`

Available when `canImport(ImageIO)`. These are the public facades. Do not construct `PhotoRAGOrchestrator` or `VideoRAGOrchestrator`.

- `public actor PhotoMemory` — ingest Photos assets or local files, OCR, multimodal embeddings, ranked photo recall
- `public actor VideoMemory` — segment videos, embed keyframes, optional host-supplied transcripts, ranked segment recall
- `public enum BuiltInMultimodalEmbeddings { public static func make(_:options:) async throws -> any MultimodalEmbeddingProvider }`
- `public protocol MultimodalEmbeddingProvider` — shared image + text embedder for the photo/video facades
- Supporting public types: `PhotoID`, `PhotoRAGConfig`, `PhotoFile`, `PhotoQuery`, `PhotoScope`, `PhotoRAGContext`, `VideoID`, `VideoRAGConfig`, `VideoFile`, `VideoQuery`, `VideoScope`, `VideoRAGContext`, `VideoTranscriptProvider`, `VisionOCRProvider`
- `PhotoID` matches `VideoID` (`source` + `id`). Photo delete, filters, file ingest, and `PhotoRAGItem` use `PhotoID`. Wrap Photos `localIdentifier` as `PhotoID(source: .photos, id:)`. On-disk photo metadata stays strings.
- `VideoFile.id` is `VideoID`. Canonical init takes `VideoID`; `VideoFile(id: String, url:)` wraps `source: .file` (trim; empty id falls back to the file URL). `VideoScope.assetIDs` is `[VideoID]`. Wrap Photos `localIdentifier` as `VideoID(source: .photos, id:)`. On-disk video metadata stays strings.

```swift
let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
let photos = try await PhotoMemory(at: storeURL, embedder: embedder, ocr: VisionOCRProvider())
try await photos.ingest(files: [PhotoFile(id: PhotoID(source: .file, id: "receipt-1"), url: imageURL)])
let context = try await photos.recall(PhotoQuery(text: "coffee receipt"))
try await photos.delete(photoID: PhotoID(source: .file, id: "receipt-1"))
try await photos.close()
```

Video does not transcribe and does not store media bytes. The host supplies transcripts. If a `VideoTranscriptProvider` throws (anything but cancellation), that video is still indexed from keyframes; `VideoRAGContext.Diagnostics.transcriptUnavailableVideoCount` counts such videos among the recalled items.

## Migration

- `OrchestratorConfig.useMetalVectorSearch` is a deprecated `package` shim. Use `vectorEnginePreference` (`true` → `.auto`, `false` → `.cpuOnly`).
- Hybrid search may run as text-only; compare `RAGContext.diagnostics.requestedMode` with `effectiveMode` (and `queryEmbeddingState`).
- `RAGContext.Diagnostics(requestedMode:effectiveMode:queryEmbeddingState:)` is unavailable. Apps read diagnostics from `Memory.search`; they must not construct illegal triples such as hybrid/vector effective with `queryEmbeddingState == .notRequested`.
- `Memory.search(_:strategy:options:)` and `Memory.search(_:strategy:options:reranker:)` are deprecated shims. Use `search(_:strategy:reranker:options:)` with `any SearchStrategy` / `any ResultReranker`.

## Package-only (NOT public API)

The following are `package`-access internals. They are used by Wax's own CLI/MCP server and tests, but **cannot be imported or constructed by downstream apps**:

- `MemoryOrchestrator`, `OrchestratorConfig`, `FastRAGConfig` (the engine behind `Memory`)
- `PhotoRAGOrchestrator`, `VideoRAGOrchestrator` (engines behind `PhotoMemory` / `VideoMemory`)
- `WaxSession`, `Wax` actor, `SearchRequest`, `SearchResponse`, `FrameFilter`, structured-memory types (`EntityKey`, facts)
- `MiniLMEmbedder` (use `BuiltInEmbeddings.make(.miniLM)` or `Memory.Config.embedding = .builtIn(.miniLM)` instead)

Structured memory (entities/facts) stays MCP/broker-facing, not a public Swift CRUD API.
