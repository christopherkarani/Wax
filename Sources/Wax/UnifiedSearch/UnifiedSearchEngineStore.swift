import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

/// Evictable search-engine cache owned by a single store owner (``MemoryOrchestrator``
/// creates and holds one; session-less readers may create their own).
///
/// Engines are keyed by source state only (empty / committed checksum / staged stamp) —
/// never by facade identity. When the underlying index changes, the key changes and the
/// engine is reloaded; ``releaseEngines()`` drops all cached engines when the owner
/// closes or invalidates the store. Test seams are constructor-injected factories that
/// replace the load step, so injected fakes flow through the same cache lifecycle as
/// production engines.
package actor UnifiedSearchEngineStore {
    enum TextSourceKey: Hashable, Sendable {
        case empty
        case committed(checksum: Data)
        case staged(stamp: UInt64)
    }

    enum VectorSourceKey: Hashable, Sendable {
        case pendingOnly(dimensions: Int, engine: LoadedVectorSearchEngine.Kind, pendingSequence: UInt64?)
        case committed(
            checksum: Data,
            similarity: VecSimilarity,
            dimensions: Int,
            engine: LoadedVectorSearchEngine.Kind,
            pendingSequence: UInt64?
        )
        case staged(
            stamp: UInt64,
            similarity: VecSimilarity,
            dimensions: Int,
            engine: LoadedVectorSearchEngine.Kind,
            pendingSequence: UInt64?
        )
    }

    struct Stats: Sendable, Equatable {
        var textDeserializations: Int = 0
        var vectorDeserializations: Int = 0
    }

    /// Replaces the real text-engine load step (deserialize / in-memory construction).
    package typealias TextEngineFactory = @Sendable () async throws -> FTS5SearchEngine

    /// Replaces the real vector-engine load step (`LoadedVectorSearchEngine.load`).
    package typealias VectorEngineFactory = @Sendable (
        _ metric: VectorMetric,
        _ dimensions: Int
    ) async throws -> any VectorSearchEngine

    private struct CachedText {
        var key: TextSourceKey
        var engine: FTS5SearchEngine
    }

    private struct CachedVector {
        var key: VectorSourceKey
        var engine: any VectorSearchEngine
    }

    private var cachedText: CachedText?
    private var cachedVector: CachedVector?
    private var stats = Stats()
    private let textEngineFactory: TextEngineFactory?
    private let vectorEngineFactory: VectorEngineFactory?

    package init(
        textEngineFactory: TextEngineFactory? = nil,
        vectorEngineFactory: VectorEngineFactory? = nil
    ) {
        self.textEngineFactory = textEngineFactory
        self.vectorEngineFactory = vectorEngineFactory
    }

    func snapshotStats() -> Stats { stats }

    func resetStats() {
        stats = Stats()
    }

    /// Drops all cached engines. Called by the owning orchestrator on close and
    /// available for explicit invalidation; stats counters are preserved.
    func releaseEngines() {
        cachedText = nil
        cachedVector = nil
    }

    var cachedEngineCount: Int {
        (cachedText == nil ? 0 : 1) + (cachedVector == nil ? 0 : 1)
    }

    func textEngine(for wax: Wax) async throws -> FTS5SearchEngine {
        if let stamp = await wax.stagedLexIndexStamp() {
            let stagedBytes = await wax.readStagedLexIndexBytes()
            let key: TextSourceKey = .staged(stamp: stamp)
            if let cached = cachedText, cached.key == key {
                return cached.engine
            }
            guard let bytes = stagedBytes else {
                let engine = try await loadTextEngine(inMemory: true)
                cachedText = CachedText(key: .empty, engine: engine)
                return engine
            }
            let engine = try await loadTextEngine(from: bytes)
            incrementTextDeserializations()
            cachedText = CachedText(key: key, engine: engine)
            return engine
        }

        if let manifest = await wax.committedLexIndexManifest() {
            let key: TextSourceKey = .committed(checksum: manifest.checksum)
            if let cached = cachedText, cached.key == key {
                return cached.engine
            }
            if let bytes = try await wax.readCommittedLexIndexBytes() {
                let engine = try await loadTextEngine(from: bytes)
                incrementTextDeserializations()
                cachedText = CachedText(key: key, engine: engine)
                return engine
            }
        }

        if let cached = cachedText, cached.key == .empty {
            return cached.engine
        }
        let engine = try await loadTextEngine(inMemory: true)
        cachedText = CachedText(key: .empty, engine: engine)
        return engine
    }

    func vectorEngine(
        for wax: Wax,
        queryEmbeddingDimensions: Int,
        preference: VectorEnginePreference = .auto
    ) async throws -> (any VectorSearchEngine)? {
        guard queryEmbeddingDimensions > 0 else { return nil }
        let pendingSnapshot = await wax.pendingEmbeddingMutations(since: nil)
        guard let descriptor = try await vectorLoadDescriptor(
            for: wax,
            queryEmbeddingDimensions: queryEmbeddingDimensions,
            preference: preference,
            pendingSnapshot: pendingSnapshot
        ) else {
            return nil
        }

        if let cached = cachedVector, cached.key == descriptor.key {
            return cached.engine
        }

        let engine: any VectorSearchEngine
        if let vectorEngineFactory {
            engine = try await vectorEngineFactory(descriptor.metric, descriptor.dimensions)
        } else {
            let loaded = try await LoadedVectorSearchEngine.load(
                from: wax,
                metric: descriptor.metric,
                dimensions: descriptor.dimensions,
                preference: preference
            )
            engine = loaded.erased
        }
        incrementVectorDeserializations()
        cachedVector = CachedVector(key: descriptor.key, engine: engine)
        return engine
    }

    private func loadTextEngine(from bytes: Data) async throws -> FTS5SearchEngine {
        if let textEngineFactory {
            return try await textEngineFactory()
        }
        return try FTS5SearchEngine.deserialize(from: bytes)
    }

    private func loadTextEngine(inMemory: Bool) async throws -> FTS5SearchEngine {
        if let textEngineFactory {
            return try await textEngineFactory()
        }
        return try FTS5SearchEngine.inMemory()
    }

    private func incrementTextDeserializations() {
        stats.textDeserializations += 1
    }

    private func incrementVectorDeserializations() {
        stats.vectorDeserializations += 1
    }

    private func vectorLoadDescriptor(
        for wax: Wax,
        queryEmbeddingDimensions: Int,
        preference: VectorEnginePreference,
        pendingSnapshot: PendingEmbeddingSnapshot
    ) async throws -> (key: VectorSourceKey, metric: VectorMetric, dimensions: Int)? {
        guard let kind = try await LoadedVectorSearchEngine.preferredKind(
            for: wax,
            queryEmbeddingDimensions: queryEmbeddingDimensions,
            preference: preference,
            pendingSnapshot: pendingSnapshot
        ) else {
            return nil
        }

        if let stamp = await wax.stagedVecIndexStamp(),
           let staged = await wax.readStagedVecIndexBytes(),
           let metric = VectorMetric(vecSimilarity: staged.similarity) {
            return (
                .staged(
                    stamp: stamp,
                    similarity: staged.similarity,
                    dimensions: Int(staged.dimension),
                    engine: kind,
                    pendingSequence: pendingSnapshot.latestSequence
                ),
                metric,
                Int(staged.dimension)
            )
        }

        if let manifest = await wax.committedVecIndexManifest(),
           let metric = VectorMetric(vecSimilarity: manifest.similarity) {
            return (
                .committed(
                    checksum: manifest.checksum,
                    similarity: manifest.similarity,
                    dimensions: Int(manifest.dimension),
                    engine: kind,
                    pendingSequence: pendingSnapshot.latestSequence
                ),
                metric,
                Int(manifest.dimension)
            )
        }

        guard pendingSnapshot.embeddings.contains(where: { $0.dimension == UInt32(queryEmbeddingDimensions) }) else {
            return nil
        }
        return (
            .pendingOnly(
                dimensions: queryEmbeddingDimensions,
                engine: kind,
                pendingSequence: pendingSnapshot.latestSequence
            ),
            .cosine,
            queryEmbeddingDimensions
        )
    }
}
