import Foundation
import WaxCore
import WaxVectorSearch

public actor WaxVectorSearchSession {
    private enum ConcreteVectorEngine: Sendable {
        case usearch(USearchVectorEngine)
        case metal(MetalVectorEngine)
    }

    public let wax: Wax
    public let engine: any VectorSearchEngine
    public let metric: VectorMetric
    public let dimensions: Int
    private let concreteEngine: ConcreteVectorEngine
    private var lastPendingEmbeddingSequence: UInt64?
    private var pendingRemovedFrameIds: Set<UInt64> = []

    public init(
        wax: Wax,
        metric: VectorMetric = .cosine,
        dimensions: Int,
        preference: VectorEnginePreference = .auto
    ) async throws {
        self.wax = wax
        self.metric = metric
        self.dimensions = dimensions
        let loadedEngine: ConcreteVectorEngine
        if preference != .cpuOnly, MetalVectorEngine.isAvailable {
            // Try Metal first; if load fails, fall back to CPU without aborting the session.
            do {
                let metal = try await MetalVectorEngine.load(from: wax, metric: metric, dimensions: dimensions)
                loadedEngine = .metal(metal)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "metal vector engine load",
                    fallback: "use CPU vector engine"
                )
                let usearch = try await USearchVectorEngine.load(from: wax, metric: metric, dimensions: dimensions)
                loadedEngine = .usearch(usearch)
            }
        } else {
            let usearch = try await USearchVectorEngine.load(from: wax, metric: metric, dimensions: dimensions)
            loadedEngine = .usearch(usearch)
        }
        self.concreteEngine = loadedEngine
        switch loadedEngine {
        case .usearch(let engine):
            self.engine = engine
        case .metal(let engine):
            self.engine = engine
        }

        let snapshot = await wax.pendingEmbeddingMutations(since: nil)
        self.lastPendingEmbeddingSequence = snapshot.latestSequence
    }

    public func add(frameId: UInt64, vector: [Float]) async throws {
        try await addToEngine(frameId: frameId, vector: vector)
        pendingRemovedFrameIds.remove(frameId)
        try await wax.putEmbedding(frameId: frameId, vector: vector)
    }

    public func remove(frameId: UInt64) async throws {
        try await removeFromEngine(frameId: frameId)
        pendingRemovedFrameIds.insert(frameId)
    }

    public func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        var query = vector
        if metric == .cosine, !query.isEmpty, !VectorMath.isNormalizedL2(query) {
            query = VectorMath.normalizeL2(query)
        }
        return try await searchEngine(vector: query, topK: topK)
    }

    public func putWithEmbedding(
        _ content: Data,
        embedding: [Float],
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain,
        identity: EmbeddingIdentity? = nil
    ) async throws -> UInt64 {
        guard embedding.count == dimensions else {
            throw WaxError.encodingError(reason: "vector dimension mismatch: expected \(dimensions), got \(embedding.count)")
        }

        var merged = options
        if let identity {
            if let expectedDims = identity.dimensions, expectedDims != embedding.count {
                throw WaxError.io("embedding identity dimension mismatch: expected \(expectedDims), got \(embedding.count)")
            }
            var metadata = merged.metadata ?? Metadata()
            if let provider = identity.provider { metadata.entries["memvid.embedding.provider"] = provider }
            if let model = identity.model { metadata.entries["memvid.embedding.model"] = model }
            if let dims = identity.dimensions { metadata.entries["memvid.embedding.dimension"] = String(dims) }
            if let normalized = identity.normalized { metadata.entries["memvid.embedding.normalized"] = String(normalized) }
            merged.metadata = metadata
        }

        let frameId = try await wax.put(content, options: merged, compression: compression)
        try await addToEngine(frameId: frameId, vector: embedding)
        pendingRemovedFrameIds.remove(frameId)
        try await wax.putEmbedding(frameId: frameId, vector: embedding)
        return frameId
    }

    /// Batch put multiple frames with embeddings in a single operation.
    /// This amortizes actor and I/O overhead across all frames.
    /// Returns frame IDs in the same order as the input contents.
    public func putWithEmbeddingBatch(
        contents: [Data],
        embeddings: [[Float]],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain,
        identity: EmbeddingIdentity? = nil
    ) async throws -> [UInt64] {
        guard !contents.isEmpty else { return [] }
        guard contents.count == embeddings.count else {
            throw WaxError.encodingError(reason: "putWithEmbeddingBatch: contents.count != embeddings.count")
        }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putWithEmbeddingBatch: contents.count != options.count")
        }

        // Validate all embeddings
        for embedding in embeddings {
            guard embedding.count == dimensions else {
                throw WaxError.encodingError(reason: "vector dimension mismatch: expected \(dimensions), got \(embedding.count)")
            }
        }

        // Merge identity metadata into options
        var mergedOptions = options
        if let identity {
            for (index, _) in options.enumerated() {
                if let expectedDims = identity.dimensions, expectedDims != embeddings[index].count {
                    throw WaxError.io("embedding identity dimension mismatch: expected \(expectedDims), got \(embeddings[index].count)")
                }
                var metadata = mergedOptions[index].metadata ?? Metadata()
                if let provider = identity.provider { metadata.entries["memvid.embedding.provider"] = provider }
                if let model = identity.model { metadata.entries["memvid.embedding.model"] = model }
                if let dims = identity.dimensions { metadata.entries["memvid.embedding.dimension"] = String(dims) }
                if let normalized = identity.normalized { metadata.entries["memvid.embedding.normalized"] = String(normalized) }
                mergedOptions[index].metadata = metadata
            }
        }

        // Batch put frames
        let frameIds = try await wax.putBatch(contents, options: mergedOptions, compression: compression)

        // Batch add to vector engine
        try await addBatchToEngine(frameIds: frameIds, vectors: embeddings)
        for frameId in frameIds {
            pendingRemovedFrameIds.remove(frameId)
        }

        // Batch put embeddings to WAL
        try await wax.putEmbeddingBatch(frameIds: frameIds, vectors: embeddings)

        return frameIds
    }

    public func commit() async throws {
        try await stageForCommit()
        try await wax.commit()
    }

    public func stageForCommit() async throws {
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
            try await addBatchToEngine(frameIds: frameIds, vectors: vectors)
        }
        if !pendingRemovedFrameIds.isEmpty {
            for frameId in pendingRemovedFrameIds {
                try await removeFromEngine(frameId: frameId)
            }
        }
        lastPendingEmbeddingSequence = snapshot.latestSequence
        try await stageEngineForCommit()
        pendingRemovedFrameIds.removeAll(keepingCapacity: true)
    }

    private func addToEngine(frameId: UInt64, vector: [Float]) async throws {
        switch concreteEngine {
        case .usearch(let engine):
            try await engine.add(frameId: frameId, vector: vector)
        case .metal(let engine):
            try await engine.add(frameId: frameId, vector: vector)
        }
    }

    private func addBatchToEngine(frameIds: [UInt64], vectors: [[Float]]) async throws {
        switch concreteEngine {
        case .usearch(let engine):
            try await engine.addBatch(frameIds: frameIds, vectors: vectors)
        case .metal(let engine):
            try await engine.addBatch(frameIds: frameIds, vectors: vectors)
        }
    }

    private func removeFromEngine(frameId: UInt64) async throws {
        switch concreteEngine {
        case .usearch(let engine):
            try await engine.remove(frameId: frameId)
        case .metal(let engine):
            try await engine.remove(frameId: frameId)
        }
    }

    private func searchEngine(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        switch concreteEngine {
        case .usearch(let engine):
            return try await engine.search(vector: vector, topK: topK)
        case .metal(let engine):
            return try await engine.search(vector: vector, topK: topK)
        }
    }

    private func stageEngineForCommit() async throws {
        switch concreteEngine {
        case .usearch(let engine):
            try await engine.stageForCommit(into: wax)
        case .metal(let engine):
            try await engine.stageForCommit(into: wax)
        }
    }
}

public extension Wax {
    @available(*, deprecated, message: "Use Wax.openSession(...)")
    func enableVectorSearch(
        metric: VectorMetric = .cosine,
        dimensions: Int,
        preference: VectorEnginePreference = .auto
    ) async throws -> WaxVectorSearchSession {
        try await WaxVectorSearchSession(
            wax: self,
            metric: metric,
            dimensions: dimensions,
            preference: preference
        )
    }

    @available(*, deprecated, message: "Use Wax.openSession(...)")
    func enableVectorSearchFromManifest(
        preference: VectorEnginePreference = .auto
    ) async throws -> WaxVectorSearchSession {
        guard let manifest = await committedVecIndexManifest() else {
            throw WaxError.io("vec index manifest missing; enableVectorSearch(dimensions:) required")
        }
        guard let metric = VectorMetric(vecSimilarity: manifest.similarity) else {
            throw WaxError.invalidToc(reason: "unsupported vec similarity \(manifest.similarity)")
        }
        return try await WaxVectorSearchSession(
            wax: self,
            metric: metric,
            dimensions: Int(manifest.dimension),
            preference: preference
        )
    }
}
