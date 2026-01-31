import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

public actor WaxSession {
    public enum Mode: Sendable, Equatable {
        case readOnly
        case readWrite(WriterPolicy = .wait)
    }

    public enum WriterPolicy: Sendable, Equatable {
        case wait
        case fail
        case timeout(Duration)
    }

    public struct Config: Sendable, Equatable {
        public var enableTextSearch: Bool
        public var enableVectorSearch: Bool
        public var enableStructuredMemory: Bool
        public var vectorEnginePreference: VectorEnginePreference
        public var vectorMetric: VectorMetric
        public var vectorDimensions: Int?

        public init(
            enableTextSearch: Bool = true,
            enableVectorSearch: Bool = true,
            enableStructuredMemory: Bool = true,
            vectorEnginePreference: VectorEnginePreference = .auto,
            vectorMetric: VectorMetric = .cosine,
            vectorDimensions: Int? = nil
        ) {
            self.enableTextSearch = enableTextSearch
            self.enableVectorSearch = enableVectorSearch
            self.enableStructuredMemory = enableStructuredMemory
            self.vectorEnginePreference = vectorEnginePreference
            self.vectorMetric = vectorMetric
            self.vectorDimensions = vectorDimensions
        }

        public static let `default` = Config()
    }

    public let wax: Wax
    public let mode: Mode
    public let config: Config

    private let textEngine: FTS5SearchEngine?
    private let vectorEngine: (any VectorSearchEngine)?
    private var lastPendingEmbeddingSequence: UInt64?
    private var writerLeaseId: UUID?
    private var isClosed = false

    public init(wax: Wax, mode: Mode = .readOnly, config: Config = .default) async throws {
        self.wax = wax
        self.mode = mode
        self.config = config

        if case .readWrite(let policy) = mode {
            let lease = try await wax.acquireWriterLease(policy: Self.mapWriterPolicy(policy))
            self.writerLeaseId = lease
        }

        if config.enableTextSearch || config.enableStructuredMemory {
            self.textEngine = try await FTS5SearchEngine.load(from: wax)
        } else {
            self.textEngine = nil
        }

        if config.enableVectorSearch {
            let dimensions = try await Self.resolveVectorDimensions(for: wax, config: config)
            if let dimensions {
                self.vectorEngine = try await Self.loadVectorEngine(
                    wax: wax,
                    metric: config.vectorMetric,
                    dimensions: dimensions,
                    preference: config.vectorEnginePreference
                )
                let snapshot = await wax.pendingEmbeddingMutations(since: nil)
                self.lastPendingEmbeddingSequence = snapshot.latestSequence
            } else {
                self.vectorEngine = nil
            }
        } else {
            self.vectorEngine = nil
        }
    }

    deinit {
        if let leaseId = writerLeaseId {
            let wax = wax
            Task { await wax.releaseWriterLease(leaseId) }
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if let leaseId = writerLeaseId {
            writerLeaseId = nil
            await wax.releaseWriterLease(leaseId)
        }
    }

    // MARK: - Search

    public func search(_ request: SearchRequest) async throws -> SearchResponse {
        let overrides = UnifiedSearchEngineOverrides(
            textEngine: textEngine,
            vectorEngine: nil,
            structuredEngine: textEngine
        )
        return try await wax.search(request, engineOverrides: overrides)
    }

    public func searchText(query: String, topK: Int) async throws -> [TextSearchResult] {
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        return try await textEngine.search(query: query, topK: topK)
    }

    // MARK: - Text Search (write)

    public func indexText(frameId: UInt64, text: String) async throws {
        try ensureWritable()
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        try await textEngine.index(frameId: frameId, text: text)
    }

    public func indexTextBatch(frameIds: [UInt64], texts: [String]) async throws {
        try ensureWritable()
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        try await textEngine.indexBatch(frameIds: frameIds, texts: texts)
    }

    public func removeText(frameId: UInt64) async throws {
        try ensureWritable()
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        try await textEngine.remove(frameId: frameId)
    }

    // MARK: - Structured Memory

    public func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String],
        nowMs: Int64
    ) async throws -> EntityRowID {
        try ensureWritable()
        guard config.enableStructuredMemory, let textEngine else {
            throw WaxError.io("structured memory is disabled")
        }
        return try await textEngine.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs)
    }

    public func resolveEntities(matchingAlias alias: String, limit: Int) async throws -> [StructuredEntityMatch] {
        guard config.enableStructuredMemory, let textEngine else {
            throw WaxError.io("structured memory is disabled")
        }
        return try await textEngine.resolveEntities(matchingAlias: alias, limit: limit)
    }

    public func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        valid: StructuredTimeRange,
        system: StructuredTimeRange,
        evidence: [StructuredEvidence]
    ) async throws -> FactRowID {
        try ensureWritable()
        guard config.enableStructuredMemory, let textEngine else {
            throw WaxError.io("structured memory is disabled")
        }
        return try await textEngine.assertFact(
            subject: subject,
            predicate: predicate,
            object: object,
            valid: valid,
            system: system,
            evidence: evidence
        )
    }

    public func retractFact(factId: FactRowID, atMs: Int64) async throws {
        try ensureWritable()
        guard config.enableStructuredMemory, let textEngine else {
            throw WaxError.io("structured memory is disabled")
        }
        try await textEngine.retractFact(factId: factId, atMs: atMs)
    }

    public func facts(
        about subject: EntityKey?,
        predicate: PredicateKey?,
        asOf: StructuredMemoryAsOf,
        limit: Int
    ) async throws -> StructuredFactsResult {
        guard config.enableStructuredMemory, let textEngine else {
            throw WaxError.io("structured memory is disabled")
        }
        return try await textEngine.facts(about: subject, predicate: predicate, asOf: asOf, limit: limit)
    }

    // MARK: - Frames

    public func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain
    ) async throws -> UInt64 {
        try ensureWritable()
        return try await wax.put(content, options: options, compression: compression)
    }

    public func put(
        _ content: Data,
        embedding: [Float],
        identity: EmbeddingIdentity? = nil,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain
    ) async throws -> UInt64 {
        try ensureWritable()
        let merged = try mergeOptions(options, identity: identity, embeddingCount: embedding.count)
        let frameId = try await wax.put(content, options: merged, compression: compression)
        try await wax.putEmbedding(frameId: frameId, vector: embedding)
        return frameId
    }

    public func putBatch(
        contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        try ensureWritable()
        return try await wax.putBatch(contents, options: options, compression: compression)
    }

    public func putBatch(
        contents: [Data],
        embeddings: [[Float]],
        identity: EmbeddingIdentity? = nil,
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        try ensureWritable()
        var mergedOptions = options
        if let identity {
            for (index, embedding) in embeddings.enumerated() {
                mergedOptions[index] = try mergeOptions(
                    mergedOptions[index],
                    identity: identity,
                    embeddingCount: embedding.count
                )
            }
        }
        let frameIds = try await wax.putBatch(contents, options: mergedOptions, compression: compression)
        guard frameIds.count == embeddings.count else {
            throw WaxError.encodingError(reason: "putBatch: embeddings.count != frameIds.count")
        }
        for (index, frameId) in frameIds.enumerated() {
            try await wax.putEmbedding(frameId: frameId, vector: embeddings[index])
        }
        return frameIds
    }

    // MARK: - Lifecycle

    public func stage(compact: Bool = false) async throws {
        try ensureWritable()

        let localTextEngine = textEngine
        let localVectorEngine = vectorEngine
        let localWax = wax
        let localConfig = config

        async let textStaging: Void = {
            if let engine = localTextEngine {
                try await engine.stageForCommit(into: localWax, compact: compact)
            }
        }()

        async let vectorStaging: Void = {
            if let engine = localVectorEngine {
                try await self.stageVectorForCommit(using: engine)
            } else if localConfig.enableVectorSearch {
                let hasPendingEmbeddings = !(await localWax.pendingEmbeddingMutations()).isEmpty
                let hasCommittedIndex = (await localWax.committedVecIndexManifest()) != nil
                if hasPendingEmbeddings || hasCommittedIndex {
                    throw WaxError.io("vector search enabled but no vector engine configured; set vectorDimensions")
                }
            }
        }()

        try await textStaging
        try await vectorStaging
    }

    public func commit(compact: Bool = false) async throws {
        try await stage(compact: compact)
        do {
            try await wax.commit()
        } catch let error as WaxError {
            if case .io(let message) = error,
               message == "vector index must be staged before committing embeddings" {
                return
            }
            throw error
        }
    }

    private func ensureWritable() throws {
        guard case .readWrite = mode else {
            throw WaxError.io("session is read-only")
        }
        guard !isClosed else {
            throw WaxError.io("session is closed")
        }
    }

    private static func mapWriterPolicy(_ policy: WriterPolicy) -> WaxWriterPolicy {
        switch policy {
        case .wait:
            return .wait
        case .fail:
            return .fail
        case .timeout(let duration):
            return .timeout(duration)
        }
    }

    private func stageVectorForCommit(using engine: any VectorSearchEngine) async throws {
        let snapshot = await wax.pendingEmbeddingMutations(since: lastPendingEmbeddingSequence)
        if let latest = snapshot.latestSequence,
           let last = lastPendingEmbeddingSequence,
           latest < last {
            lastPendingEmbeddingSequence = nil
        }
        if !snapshot.embeddings.isEmpty {
            let frameIds = snapshot.embeddings.map(\.frameId)
            let vectors = snapshot.embeddings.map(\.vector)
            try await engine.addBatch(frameIds: frameIds, vectors: vectors)
        }
        lastPendingEmbeddingSequence = snapshot.latestSequence
        try await engine.stageForCommit(into: wax)
    }

    private static func resolveVectorDimensions(for wax: Wax, config: Config) async throws -> Int? {
        if let configured = config.vectorDimensions {
            return configured
        }
        if let manifest = await wax.committedVecIndexManifest() {
            return Int(manifest.dimension)
        }
        return nil
    }

    private static func loadVectorEngine(
        wax: Wax,
        metric: VectorMetric,
        dimensions: Int,
        preference: VectorEnginePreference
    ) async throws -> any VectorSearchEngine {
        if preference != .cpuOnly, MetalVectorEngine.isAvailable {
            if let metal = try? await MetalVectorEngine.load(from: wax, metric: metric, dimensions: dimensions) {
                return metal
            }
        }
        return try await USearchVectorEngine.load(from: wax, metric: metric, dimensions: dimensions)
    }

    private func mergeOptions(
        _ options: FrameMetaSubset,
        identity: EmbeddingIdentity?,
        embeddingCount: Int
    ) throws -> FrameMetaSubset {
        guard let identity else { return options }

        if let expectedDims = identity.dimensions, expectedDims != embeddingCount {
            throw WaxError.io("embedding identity dimension mismatch: expected \(expectedDims), got \(embeddingCount)")
        }

        var merged = options
        var metadata = merged.metadata ?? Metadata()
        if let provider = identity.provider { metadata.entries["memvid.embedding.provider"] = provider }
        if let model = identity.model { metadata.entries["memvid.embedding.model"] = model }
        if let dims = identity.dimensions { metadata.entries["memvid.embedding.dimension"] = String(dims) }
        if let normalized = identity.normalized { metadata.entries["memvid.embedding.normalized"] = String(normalized) }
        merged.metadata = metadata
        return merged
    }
}

public extension Wax {
    func openSession(
        _ mode: WaxSession.Mode = .readOnly,
        config: WaxSession.Config = .default
    ) async throws -> WaxSession {
        try await WaxSession(wax: self, mode: mode, config: config)
    }
}
