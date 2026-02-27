# Wax Public API Reference

**MemoryOrchestrator**  
Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`

Public API:
- `public actor MemoryOrchestrator`
- `public enum QueryEmbeddingPolicy { case never, ifAvailable, always }`
- `public init(at url: URL, config: OrchestratorConfig = .default, embedder: (any EmbeddingProvider)? = nil) async throws`
- `public func startSession() -> UUID`
- `public func endSession()`
- `public func remember(_ content: String, metadata: [String: String] = [:]) async throws`
- `public func recall(query: String) async throws -> RAGContext`
- `public func recall(query: String, embedding: [Float]) async throws -> RAGContext`
- `public func recall(query: String, embeddingPolicy: QueryEmbeddingPolicy) async throws -> RAGContext`
- `public func flush() async throws`
- `public func close() async throws`

Policy constraints (verified):
- `init`: if `config.enableVectorSearch == true` and `embedder == nil` and there is no committed vector index, initialization throws `WaxError.io(...)`. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`
- `QueryEmbeddingPolicy.never`: no query embedding is produced. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`
- `QueryEmbeddingPolicy.ifAvailable`: returns `nil` when vector search is disabled or no embedder is configured. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`
- `QueryEmbeddingPolicy.always`: throws if vector search is disabled or no embedder is configured. Source: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`

**OrchestratorConfig**  
Source: `Sources/Wax/Orchestrator/OrchestratorConfig.swift`

Public API:
- `public struct OrchestratorConfig: Sendable`
- `public init()`
- `public static let default: OrchestratorConfig`
- `public var enableTextSearch: Bool`
- `public var enableVectorSearch: Bool`
- `public var rag: FastRAGConfig`
- `public var chunking: ChunkingStrategy`
- `public var ingestConcurrency: Int`
- `public var ingestBatchSize: Int`
- `public var embeddingCacheCapacity: Int`
- `public var useMetalVectorSearch: Bool` (prefers Metal when available)

**Prewarm and MiniLM Helpers**  
Sources: `Sources/Wax/Orchestrator/MemoryOrchestrator+Prewarm.swift`, `Sources/Wax/Adapters/MemoryOrchestrator+MiniLM.swift`

Public API:
- `public enum WaxPrewarm`
- `public static func tokenizer() async`
- `public static func miniLM(sampleText: String = "hello") async throws` (only when `canImport(WaxVectorSearchMiniLM)`)
- `public static func openMiniLM(at url: URL, config: OrchestratorConfig = .default) async throws -> MemoryOrchestrator` (only when `canImport(WaxVectorSearchMiniLM)`)
- `public static func openMiniLM(at url: URL, config: OrchestratorConfig = .default, overrides: MiniLMEmbeddings.Overrides) async throws -> MemoryOrchestrator` (only when `canImport(WaxVectorSearchMiniLM)`)

**VideoRAGOrchestrator**  
Source: `Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`

Public API:
- `public actor VideoRAGOrchestrator`
- `public let config: VideoRAGConfig`
- `public init(storeURL: URL, config: VideoRAGConfig = .default, embedder: any MultimodalEmbeddingProvider, transcriptProvider: (any VideoTranscriptProvider)? = nil) async throws`
- `public func ingest(files: [VideoFile]) async throws`
- `public func recall(_ query: VideoQuery) async throws -> VideoRAGContext`
- `public func delete(videoID: VideoID) async throws`
- `public func flush() async throws`
- `public enum VideoScope { case fullLibrary, assetIDs([String]) }` (only when `canImport(Photos)`)
- `public func syncLibrary(scope: VideoScope) async throws` (only when `canImport(Photos)`)

Policy constraints (verified):
- `init`: if `config.vectorEnginePreference != .cpuOnly` and `embedder.normalize == false`, initialization throws `WaxError.io(...)` (Metal vector search requires normalized embeddings). Source: `Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`

**VideoRAGConfig**  
Source: `Sources/Wax/VideoRAG/VideoRAGConfig.swift`

Public API:
- `public struct VideoRAGConfig: Sendable, Equatable`
- `public init(...)` with defaults
- `public static let default: VideoRAGConfig`
- Ingest: `pipelineVersion`, `segmentDurationSeconds`, `segmentOverlapSeconds`, `maxSegmentsPerVideo`, `segmentWriteBatchSize`, `embedMaxPixelSize`, `maxTranscriptBytesPerSegment`
- Search: `searchTopK`, `hybridAlpha`, `vectorEnginePreference`, `timelineFallbackLimit`
- Output: `includeThumbnailsInContext`, `thumbnailMaxPixelSize`
- Caching: `queryEmbeddingCacheCapacity`

Policy constraints (verified):
- `init` clamps values to non-negative and enforces minimums for batch sizes and pixel sizes; `hybridAlpha` is clamped to `[0, 1]`. Source: `Sources/Wax/VideoRAG/VideoRAGConfig.swift`

**Video RAG Types**  
Source: `Sources/Wax/VideoRAG/VideoRAGTypes.swift`

Public API (selected):
- `public struct VideoID` with `Source` (`.photos`, `.file`), `source`, `id`
- `public struct VideoFile` with `id`, `url`, `captureDate`
- `public struct VideoContextBudget` with `maxTextTokens`, `maxThumbnails`, `maxTranscriptLinesPerSegment`
- `public struct VideoQuery` with `text`, `timeRange`, `videoIDs`, `resultLimit`, `segmentLimitPerVideo`, `contextBudget`
- `public struct VideoThumbnail` with `data`, `format`, `width`, `height`
- `public struct VideoSegmentHit` with `startMs`, `endMs`, `score`, `evidence`, `transcriptSnippet`, `thumbnail`
- `public struct VideoRAGItem` with `videoID`, `score`, `evidence`, `summaryText`, `segments`
- `public struct VideoRAGContext` with `query`, `items`, `diagnostics`
- `public enum VideoIngestError` cases: `fileMissing`, `unsupportedPlatform`, `invalidVideo`, `embedderDimensionMismatch`

**Protocols**

**EmbeddingProvider**  
Source: `Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift`

Public API:
- `public protocol EmbeddingProvider: Sendable`
- `var dimensions: Int { get }`
- `var normalize: Bool { get }`
- `var identity: EmbeddingIdentity? { get }`
- `func embed(_ text: String) async throws -> [Float]`

Related public API:
- `public protocol BatchEmbeddingProvider: EmbeddingProvider`
- `func embed(batch texts: [String]) async throws -> [[Float]]`
- `public struct EmbeddingIdentity` with `provider`, `model`, `dimensions`, `normalized` and `public init(...)`

**MultimodalEmbeddingProvider**  
Source: `Sources/Wax/VideoRAG/VideoRAGProtocols.swift`

Public API:
- `public protocol MultimodalEmbeddingProvider: Sendable`
- `var dimensions: Int { get }`
- `var normalize: Bool { get }`
- `var identity: EmbeddingIdentity? { get }`
- `func embed(text: String) async throws -> [Float]`
- `func embed(image: CGImage) async throws -> [Float]`

**VideoTranscriptProvider**  
Source: `Sources/Wax/VideoRAG/VideoRAGProtocols.swift`

Public API:
- `public protocol VideoTranscriptProvider: Sendable`
- `func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk]`

Related public API:
- `public struct VideoTranscriptRequest` (`videoID`, `localFileURL`, `durationMs`) and `public init(...)`
- `public struct VideoTranscriptChunk` (`startMs`, `endMs`, `text`) and `public init(...)`

**Maintenance**  
Sources: `Sources/Wax/Orchestrator/MemoryOrchestrator+Maintenance.swift`, `Sources/Wax/Maintenance/*.swift`

Public API (selected):
- `public protocol MaintenableMemory` with `optimizeSurrogates(...)` and `compactIndexes(...)`
- `public extension MemoryOrchestrator` methods:
- `func optimizeSurrogates(options: MaintenanceOptions = .init(), generator: (any SurrogateGenerator)? = nil) async throws -> MaintenanceReport`
- `func compactIndexes(options: MaintenanceOptions = .init()) async throws -> MaintenanceReport`
- `public struct MaintenanceOptions` (`maxFrames`, `maxWallTimeMs`, `surrogateMaxTokens`, `overwriteExisting`, `enableHierarchicalSurrogates`, `tierConfig`)
- `public struct MaintenanceReport` (`scannedFrames`, `eligibleFrames`, `generatedSurrogates`, `supersededSurrogates`, `skippedUpToDate`, `didTimeout`)
- `public struct SurrogateTierConfig` (`fullMaxTokens`, `gistMaxTokens`, `microMaxTokens`) and presets (`default`, `compact`, `verbose`)
- `public protocol SurrogateGenerator` and `public protocol HierarchicalSurrogateGenerator`

**Fast RAG**  
Sources: `Sources/Wax/RAG/FastRAGContextBuilder.swift`, `Sources/Wax/RAG/FastRAGConfig.swift`

Public API (selected):
- `public struct FastRAGContextBuilder`
- `public func build(query: String, embedding: [Float]? = nil, vectorEnginePreference: VectorEnginePreference = .auto, wax: Wax, session: WaxSession? = nil, config: FastRAGConfig = .init()) async throws -> RAGContext`
- `public struct FastRAGConfig` with `mode`, token budgets, `searchTopK`, `searchMode`, `rrfK`, `previewMaxBytes`, `tierSelectionPolicy`, `enableQueryAwareTierSelection`
- `public enum SurrogateTier` (`full`, `gist`, `micro`)
- `public enum TierSelectionPolicy` and thresholds (`AgeThresholds`, `ImportanceThresholds`)

**SearchRequest / SearchMode**  
Source: `Sources/Wax/UnifiedSearch/SearchRequest.swift`, `Sources/Wax/UnifiedSearch/SearchMode.swift`

Public API:
- `public struct SearchRequest: Sendable, Equatable`
- `public init(...)` with defaults
- Core fields: `query`, `embedding`, `vectorEnginePreference`, `mode`, `topK`, `minScore`, `timeRange`, `frameFilter`, `asOfMs`, `structuredMemory`
- Fusion fields: `rrfK`, `previewMaxBytes`, `allowTimelineFallback`, `timelineFallbackLimit`
- `public enum SearchMode { case textOnly, vectorOnly, hybrid(alpha: Float) }`

Related public API:
- `public struct StructuredMemorySearchOptions` (`weight`, `maxEntityCandidates`, `maxFacts`, `maxEvidenceFrames`, `requireEvidenceSpan`) and `public init(...)`
- `public struct TimeRange` (`after`, `before`) and `public init(...)`, `public func contains(_:) -> Bool`
- `public struct FrameFilter` (`includeDeleted`, `includeSuperseded`, `includeSurrogates`, `frameIds`) and `public init(...)`

**SearchResponse / TextSearchResult**  
Sources: `Sources/Wax/UnifiedSearch/SearchResponse.swift`, `Sources/WaxTextSearch/TextSearchResult.swift`

Public API:
- `public struct SearchResponse` with `results` (`[SearchResponse.Result]`)
- `public struct SearchResponse.Result` with `frameId`, `score`, `previewText`, `sources`
- `public enum SearchResponse.Source { case text, vector, timeline, structuredMemory }`
- `public struct TextSearchResult` with `frameId`, `score`, `snippet`

**RAGContext**  
Source: `Sources/Wax/RAG/RAGContext.swift`

Public API:
- `public struct RAGContext: Sendable, Equatable`
- `public enum ItemKind { case snippet, expanded, surrogate }`
- `public struct Item` with `kind`, `frameId`, `score`, `sources`, `text` and `public init(...)`
- `public var query: String`
- `public var items: [Item]`
- `public var totalTokens: Int`
- `public init(query: String, items: [Item], totalTokens: Int)`

**Wax**  
Source: `Sources/WaxCore/Wax.swift`, `Sources/Wax/UnifiedSearch/UnifiedSearch.swift`

Public API (selected):
- `public actor Wax`
- Lifecycle: `public static func create(at: URL, walSize: UInt64 = ..., options: WaxOptions = .init()) async throws -> Wax`, `public static func open(at: URL, options: WaxOptions = .init()) async throws -> Wax`, `public static func open(at: URL, repair: Bool, options: WaxOptions = .init()) async throws -> Wax`, `public func close() async throws`
- Writer lease: `public func acquireWriterLease(policy: WaxWriterPolicy) async throws -> UUID`, `public func releaseWriterLease(_:)`
- Search: `public func search(_ request: SearchRequest) async throws -> SearchResponse` (extension)
- Frames: `public func put(...) async throws -> UInt64` (overloads), `public func putBatch(...) async throws -> [UInt64]` (overloads)
- Embeddings: `public func putEmbedding(frameId: UInt64, vector: [Float]) async throws`, `public func putEmbeddingBatch(frameIds: [UInt64], vectors: [[Float]]) async throws`
- Pending embeddings: `public func pendingEmbeddingMutations() async -> [PutEmbedding]`, `public func pendingEmbeddingMutations(since: UInt64?) async -> PendingEmbeddingSnapshot`
- Deletes and superseding: `public func delete(frameId: UInt64) async throws`, `public func supersede(supersededId: UInt64, supersedingId: UInt64) async throws`
- Index staging/commit: `public func stageLexIndexForNextCommit(...) async throws`, `public func stageVecIndexForNextCommit(...) async throws`, `public func commit() async throws`
- Frame read APIs: `public func frameMetas() async -> [FrameMeta]`, `public func frameMetas(frameIds: [UInt64]) async -> [UInt64: FrameMeta]`, `public func frameMetasIncludingPending(frameIds: [UInt64]) async -> [UInt64: FrameMeta]`, `public func frameMeta(frameId: UInt64) async throws -> FrameMeta`, `public func frameMetaIncludingPending(frameId: UInt64) async throws -> FrameMeta`, `public func frameContent(frameId: UInt64) async throws -> Data`, `public func frameContentIncludingPending(frameId: UInt64) async throws -> Data`, `public func frameContents(frameIds: [UInt64]) async throws -> [UInt64: Data]`, `public func framePreview(frameId: UInt64, maxBytes: Int) async throws -> Data`, `public func framePreviews(frameIds: [UInt64], maxBytes: Int) async throws -> [UInt64: Data]`, `public func frameStoredContent(frameId: UInt64) async throws -> Data`, `public func frameStoredPreview(frameId: UInt64, maxBytes: Int) async throws -> Data`
- Timeline, stats, verify: `public func timeline(_ query: TimelineQuery) async -> [FrameMeta]`, `public func stats() async -> WaxStats`, `public func verify() async throws`, `public func verify(deep: Bool) async throws`

**WaxSession**  
Source: `Sources/Wax/WaxSession.swift`

Public API:
- `public actor WaxSession`
- `public enum Mode { case readOnly, readWrite(WriterPolicy = .wait) }`
- `public enum WriterPolicy { case wait, fail, timeout(Duration) }`
- `public struct Config` with `enableTextSearch`, `enableVectorSearch`, `enableStructuredMemory`, `vectorEnginePreference`, `vectorMetric`, `vectorDimensions`, `public init(...)`, `public static let default`
- `public init(wax: Wax, mode: Mode = .readOnly, config: Config = .default) async throws`
- Lifecycle: `public func close() async`
- Search: `public func search(_ request: SearchRequest) async throws -> SearchResponse`, `public func searchText(query: String, topK: Int) async throws -> [TextSearchResult]`
- Text write: `public func indexText(frameId: UInt64, text: String) async throws`, `public func indexTextBatch(frameIds: [UInt64], texts: [String]) async throws`, `public func removeText(frameId: UInt64) async throws`
- Structured memory: `public func upsertEntity(...) async throws -> EntityRowID`, `public func resolveEntities(matchingAlias: String, limit: Int) async throws -> [StructuredEntityMatch]`, `public func assertFact(...) async throws -> FactRowID`, `public func retractFact(factId: FactRowID, atMs: Int64) async throws`, `public func facts(...) async throws -> StructuredFactsResult`
- Frames: `public func put(...) async throws -> UInt64` (overloads), `public func putBatch(...) async throws -> [UInt64]` (overloads)
- Persistence: `public func stage(compact: Bool = false) async throws`, `public func commit(compact: Bool = false) async throws`
- `public extension Wax { func openSession(_ mode: WaxSession.Mode = .readOnly, config: WaxSession.Config = .default) async throws -> WaxSession }`

**Deprecated Sessions (still used in README/tests)**  
Sources: `Sources/Wax/TextSearchSession.swift`, `Sources/Wax/VectorSearchSession.swift`, `Sources/Wax/StructuredMemorySession.swift`

Public API:
- `public actor WaxTextSearchSession` with `index`, `indexBatch`, `remove`, `search`, `stageForCommit`, `commit`
- `public actor WaxVectorSearchSession` with `add`, `remove`, `search`, `putWithEmbedding`, `putWithEmbeddingBatch`, `stageForCommit`, `commit`
- `public actor WaxStructuredMemorySession` with `upsertEntity`, `resolveEntities`, `assertFact`, `retractFact`, `facts`, `stageForCommit`, `commit`
- `public extension Wax { @available(*, deprecated, message: "Use Wax.openSession(...)") func enableTextSearch() }`
- `public extension Wax { @available(*, deprecated, message: "Use Wax.openSession(...)") func enableVectorSearch(...) }`
- `public extension Wax { @available(*, deprecated, message: "Use Wax.openSession(...)") func structuredMemory() }`
