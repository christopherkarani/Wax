import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

package actor WaxSession {
    private typealias ConcreteVectorEngine = LoadedVectorSearchEngine

    package enum Mode: Sendable, Equatable {
        case readOnly
        case readWrite(WriterPolicy = .wait)
    }

    package enum WriterPolicy: Sendable, Equatable {
        case wait
        case fail
        case timeout(Duration)
    }

    package struct Config: Sendable, Equatable {
        package var enableTextSearch: Bool
        package var enableVectorSearch: Bool
        package var enableStructuredMemory: Bool
        package var vectorEnginePreference: VectorEnginePreference
        package var vectorMetric: VectorMetric
        package var vectorDimensions: Int?

        package init(
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

        package static let `default` = Config()
    }

    package let wax: Wax
    package let mode: Mode
    package let config: Config

    private let textEngine: FTS5SearchEngine?
    private let vectorEngine: (any VectorSearchEngine)?
    private let concreteVectorEngine: ConcreteVectorEngine?
    private var lastPendingEmbeddingSequence: UInt64?
    private var writerLeaseId: UUID?
    private var isClosed = false

    package init(wax: Wax, mode: Mode = .readOnly, config: Config = .default) async throws {
        self.wax = wax
        self.mode = mode
        self.config = config

        var acquiredWriterLeaseId: UUID?
        if case .readWrite(let policy) = mode {
            let lease = try await wax.acquireWriterLease(policy: Self.mapWriterPolicy(policy))
            acquiredWriterLeaseId = lease
        }
        self.writerLeaseId = acquiredWriterLeaseId

        do {
            let resolvedTextEngine: FTS5SearchEngine? = if config.enableTextSearch || config.enableStructuredMemory {
                try await FTS5SearchEngine.load(from: wax)
            } else {
                nil
            }

            let resolvedConcreteVectorEngine: ConcreteVectorEngine?
            let resolvedVectorEngine: (any VectorSearchEngine)?
            let resolvedLastPendingEmbeddingSequence: UInt64?

            if config.enableVectorSearch {
                let dimensions = try await Self.resolveVectorDimensions(for: wax, config: config)
                if let dimensions {
                    let loadedVectorEngine = try await Self.loadVectorEngine(
                        wax: wax,
                        metric: config.vectorMetric,
                        dimensions: dimensions,
                        preference: config.vectorEnginePreference
                    )
                    resolvedConcreteVectorEngine = loadedVectorEngine
                    resolvedVectorEngine = loadedVectorEngine.erased
                    let snapshot = await wax.pendingEmbeddingMutations(since: nil)
                    resolvedLastPendingEmbeddingSequence = snapshot.latestSequence
                } else {
                    resolvedConcreteVectorEngine = nil
                    resolvedVectorEngine = nil
                    resolvedLastPendingEmbeddingSequence = nil
                }
            } else {
                resolvedConcreteVectorEngine = nil
                resolvedVectorEngine = nil
                resolvedLastPendingEmbeddingSequence = nil
            }

            self.textEngine = resolvedTextEngine
            self.concreteVectorEngine = resolvedConcreteVectorEngine
            self.vectorEngine = resolvedVectorEngine
            self.lastPendingEmbeddingSequence = resolvedLastPendingEmbeddingSequence
        } catch {
            if let leaseId = acquiredWriterLeaseId {
                await wax.releaseWriterLease(leaseId)
                self.writerLeaseId = nil
            }
            throw error
        }
    }

    deinit {
        if let leaseId = writerLeaseId {
            let wax = wax
            Task { await wax.releaseWriterLease(leaseId) }
        }
    }

    package func close() async {
        guard !isClosed else { return }
        isClosed = true
        if let leaseId = writerLeaseId {
            writerLeaseId = nil
            await wax.releaseWriterLease(leaseId)
        }
    }

    // MARK: - Search

    package func search(_ request: SearchRequest) async throws -> SearchResponse {
        let overrides = UnifiedSearchEngineOverrides(
            textEngine: textEngine,
            vectorEngine: vectorEngine,
            structuredEngine: textEngine
        )
        return try await wax.search(request, engineOverrides: overrides)
    }

    package func searchText(query: String, topK: Int) async throws -> [TextSearchResult] {
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        return try await textEngine.search(query: query, topK: topK)
    }

    // MARK: - Text Search (write)

    package func indexText(frameId: UInt64, text: String) async throws {
        try ensureWritable()
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        try await textEngine.index(frameId: frameId, text: text)
    }

    package func indexTextBatch(frameIds: [UInt64], texts: [String]) async throws {
        try ensureWritable()
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        try await textEngine.indexBatch(frameIds: frameIds, texts: texts)
    }

    package func removeText(frameId: UInt64) async throws {
        try ensureWritable()
        guard config.enableTextSearch, let textEngine else {
            throw WaxError.io("text search is disabled")
        }
        try await textEngine.remove(frameId: frameId)
    }

    // MARK: - Structured Memory

    package func upsertEntity(
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

    package func resolveEntities(matchingAlias alias: String, limit: Int) async throws -> [StructuredEntityMatch] {
        guard config.enableStructuredMemory, let textEngine else {
            throw WaxError.io("structured memory is disabled")
        }
        return try await textEngine.resolveEntities(matchingAlias: alias, limit: limit)
    }

    package func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        relation: VersionRelation = .sets,
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
            relation: relation,
            valid: valid,
            system: system,
            evidence: evidence
        )
    }

    package func retractFact(factId: FactRowID, atMs: Int64) async throws {
        try ensureWritable()
        guard config.enableStructuredMemory, let textEngine else {
            throw WaxError.io("structured memory is disabled")
        }
        try await textEngine.retractFact(factId: factId, atMs: atMs)
    }

    package func facts(
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

    package func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain
    ) async throws -> UInt64 {
        try ensureWritable()
        return try await wax.put(content, options: options, compression: compression)
    }

    package func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain,
        timestampMs: Int64
    ) async throws -> UInt64 {
        try ensureWritable()
        return try await wax.put(content, options: options, compression: compression, timestampMs: timestampMs)
    }

    package func put(
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

    package func put(
        _ content: Data,
        embedding: [Float],
        identity: EmbeddingIdentity? = nil,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain,
        timestampMs: Int64
    ) async throws -> UInt64 {
        try ensureWritable()
        let merged = try mergeOptions(options, identity: identity, embeddingCount: embedding.count)
        let frameId = try await wax.put(content, options: merged, compression: compression, timestampMs: timestampMs)
        try await wax.putEmbedding(frameId: frameId, vector: embedding)
        return frameId
    }

    package func putBatch(
        contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        try ensureWritable()
        return try await wax.putBatch(contents, options: options, compression: compression)
    }

    package func putBatch(
        contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain,
        timestampsMs: [Int64]
    ) async throws -> [UInt64] {
        try ensureWritable()
        return try await wax.putBatch(contents, options: options, compression: compression, timestampsMs: timestampsMs)
    }

    package func putBatch(
        contents: [Data],
        embeddings: [[Float]],
        identity: EmbeddingIdentity? = nil,
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        try ensureWritable()
        guard contents.count == embeddings.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count != embeddings.count")
        }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count != options.count")
        }
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
        try await wax.putEmbeddingBatch(frameIds: frameIds, vectors: embeddings)
        return frameIds
    }

    package func putBatch(
        contents: [Data],
        embeddings: [[Float]],
        identity: EmbeddingIdentity? = nil,
        options: [FrameMetaSubset],
        timestampsMs: [Int64],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        try ensureWritable()
        guard contents.count == embeddings.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count != embeddings.count")
        }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count != options.count")
        }
        guard contents.count == timestampsMs.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count != timestampsMs.count")
        }

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
        let frameIds = try await wax.putBatch(contents, options: mergedOptions, compression: compression, timestampsMs: timestampsMs)
        guard frameIds.count == embeddings.count else {
            throw WaxError.encodingError(reason: "putBatch: embeddings.count != frameIds.count")
        }
        try await wax.putEmbeddingBatch(frameIds: frameIds, vectors: embeddings)
        return frameIds
    }

    /// Finds the most recent active document frame whose metadata contains `key == value`.
    ///
    /// - Note: This performs an O(n) scan over `frameMetas()` and is acceptable for v2.
    ///   A dedicated metadata index can optimize this in a later version.
    package func findFrameByMetadata(key: String, value: String) async -> UInt64? {
        let metas = await wax.frameMetas()
        for meta in metas.reversed() {
            guard meta.role == .document else { continue }
            guard meta.status == .active, meta.supersededBy == nil else { continue }
            guard meta.metadata?.entries[key] == value else { continue }
            return meta.id
        }
        return nil
    }

    // MARK: - Lifecycle

    package func stage(compact: Bool = false) async throws {
        try ensureWritable()

        let localTextEngine = textEngine
        let localVectorEngine = concreteVectorEngine
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

    package func commit(compact: Bool = false) async throws {
        try await stage(compact: compact)
        try await wax.commit()
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

    private func stageVectorForCommit(using engine: ConcreteVectorEngine) async throws {
        let snapshot = await wax.pendingEmbeddingMutations(since: lastPendingEmbeddingSequence)
        if let latest = snapshot.latestSequence,
           let last = lastPendingEmbeddingSequence,
           latest < last {
            lastPendingEmbeddingSequence = nil
        }
        if !snapshot.embeddings.isEmpty {
            var frameIds: [UInt64] = []
            var vectors: [[Float]] = []
            frameIds.reserveCapacity(snapshot.embeddings.count)
            vectors.reserveCapacity(snapshot.embeddings.count)
            for embedding in snapshot.embeddings {
                frameIds.append(embedding.frameId)
                vectors.append(embedding.vector)
            }
            try await engine.addBatch(frameIds: frameIds, vectors: vectors)
        }
        lastPendingEmbeddingSequence = snapshot.latestSequence
        try await engine.stageForCommit(into: wax)
    }

    private static func resolveVectorDimensions(for wax: Wax, config: Config) async throws -> Int? {
        if let configured = config.vectorDimensions {
            return configured
        }
        if let staged = await wax.readStagedVecIndexBytes() {
            return Int(staged.dimension)
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
    ) async throws -> ConcreteVectorEngine {
        try await LoadedVectorSearchEngine.load(
            from: wax,
            metric: metric,
            dimensions: dimensions,
            preference: preference
        )
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
        if let provider = identity.provider { metadata.entries["wax.embedding.provider"] = provider }
        if let model = identity.model { metadata.entries["wax.embedding.model"] = model }
        if let dims = identity.dimensions { metadata.entries["wax.embedding.dimension"] = String(dims) }
        if let normalized = identity.normalized { metadata.entries["wax.embedding.normalized"] = String(normalized) }
        merged.metadata = metadata
        return merged
    }
}

package extension Wax {
    func openSession(
        _ mode: WaxSession.Mode = .readOnly,
        config: WaxSession.Config = .default
    ) async throws -> WaxSession {
        try await WaxSession(wax: self, mode: mode, config: config)
    }
}
