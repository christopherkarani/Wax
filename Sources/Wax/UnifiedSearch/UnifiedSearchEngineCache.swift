import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

actor UnifiedSearchEngineCache {
    static let shared = UnifiedSearchEngineCache()

    enum TextSourceKey: Hashable, Sendable {
        case empty
        case committed(checksum: Data)
        case staged(stamp: UInt64)
    }

    /// The index a cached vector engine was loaded from. Pending embeddings are
    /// not part of the key: they are applied to the cached engine incrementally
    /// (see `CachedVector.syncedThrough`), so a write does not force a reload.
    enum VectorSourceKey: Hashable, Sendable {
        case pendingOnly(dimensions: Int, engine: LoadedVectorSearchEngine.Kind)
        case committed(
            checksum: Data,
            similarity: VecSimilarity,
            dimensions: Int,
            engine: LoadedVectorSearchEngine.Kind
        )
        case staged(
            stamp: UInt64,
            similarity: VecSimilarity,
            dimensions: Int,
            engine: LoadedVectorSearchEngine.Kind
        )
    }

    struct Stats: Sendable, Equatable {
        var textDeserializations: Int = 0
        var vectorDeserializations: Int = 0
    }

    private struct CachedText {
        var key: TextSourceKey
        var engine: FTS5SearchEngine
    }

    private struct CachedVector {
        var key: VectorSourceKey
        var engine: LoadedVectorSearchEngine
        /// Latest pending-embedding sequence applied to `engine`.
        var syncedThrough: UInt64?
    }

    private var textByWax: [ObjectIdentifier: CachedText] = [:]
    private var vectorByWax: [ObjectIdentifier: CachedVector] = [:]
    private var stats = Stats()
    private var statsByWax: [ObjectIdentifier: Stats] = [:]

    func snapshotStats() -> Stats { stats }

    func snapshotStats(for wax: Wax) -> Stats {
        statsByWax[ObjectIdentifier(wax)] ?? Stats()
    }

    func resetStats() {
        stats = Stats()
    }

    func resetStats(for wax: Wax) {
        statsByWax[ObjectIdentifier(wax)] = Stats()
    }

    func textEngine(for wax: Wax) async throws -> FTS5SearchEngine {
        let waxId = ObjectIdentifier(wax)

        if let stamp = await wax.stagedLexIndexStamp() {
            let stagedBytes = await wax.readStagedLexIndexBytes()
            let key: TextSourceKey = .staged(stamp: stamp)
            if let cached = textByWax[waxId], cached.key == key {
                return cached.engine
            }
            guard let bytes = stagedBytes else {
                let engine = try FTS5SearchEngine.inMemory()
                textByWax[waxId] = CachedText(key: .empty, engine: engine)
                return engine
            }
            let engine = try FTS5SearchEngine.deserialize(from: bytes)
            incrementTextDeserializations(for: waxId)
            textByWax[waxId] = CachedText(key: key, engine: engine)
            return engine
        }

        if let manifest = await wax.committedLexIndexManifest() {
            let key: TextSourceKey = .committed(checksum: manifest.checksum)
            if let cached = textByWax[waxId], cached.key == key {
                return cached.engine
            }
            if let bytes = try await wax.readCommittedLexIndexBytes() {
                let engine = try FTS5SearchEngine.deserialize(from: bytes)
                incrementTextDeserializations(for: waxId)
                textByWax[waxId] = CachedText(key: key, engine: engine)
                return engine
            }
        }

        if let cached = textByWax[waxId], cached.key == .empty {
            return cached.engine
        }
        let engine = try FTS5SearchEngine.inMemory()
        textByWax[waxId] = CachedText(key: .empty, engine: engine)
        return engine
    }

    func vectorEngine(
        for wax: Wax,
        queryEmbeddingDimensions: Int,
        preference: VectorEnginePreference = .auto
    ) async throws -> LoadedVectorSearchEngine? {
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

        let waxId = ObjectIdentifier(wax)
        let latestPending = pendingSnapshot.latestSequence
        if let cached = vectorByWax[waxId], cached.key == descriptor.key {
            if cached.syncedThrough == latestPending {
                return cached.engine
            }
            if let latestPending, cached.syncedThrough.map({ $0 < latestPending }) ?? true {
                // Only new writes since the last search: apply them instead of
                // rebuilding the engine from the whole index. A load applies every
                // pending embedding the same way, so the result is identical.
                let delta = await wax.pendingEmbeddingMutations(since: cached.syncedThrough)
                if !delta.embeddings.isEmpty {
                    try await cached.engine.addBatch(
                        frameIds: delta.embeddings.map(\.frameId),
                        vectors: delta.embeddings.map(\.vector)
                    )
                }
                recordVectorSync(waxId: waxId, key: descriptor.key, through: delta.latestSequence)
                return cached.engine
            }
            // Pending embeddings were dropped without an index change; the cached
            // engine may hold vectors that are gone. Reload.
        }

        let loaded = try await LoadedVectorSearchEngine.load(
            from: wax,
            metric: descriptor.metric,
            dimensions: descriptor.dimensions,
            preference: preference
        )
        incrementVectorDeserializations(for: waxId)
        // `load` applies every pending embedding present when it read them, which
        // is at least `latestPending`; a later write is re-applied idempotently.
        vectorByWax[waxId] = CachedVector(key: descriptor.key, engine: loaded, syncedThrough: latestPending)
        return loaded
    }

    /// Searches can interleave across the `addBatch` await. Adds are idempotent
    /// overwrites, so only move the watermark forward and only for the same index.
    private func recordVectorSync(waxId: ObjectIdentifier, key: VectorSourceKey, through sequence: UInt64?) {
        guard var cached = vectorByWax[waxId], cached.key == key, let sequence else { return }
        if let synced = cached.syncedThrough, synced >= sequence { return }
        cached.syncedThrough = sequence
        vectorByWax[waxId] = cached
    }

    private func incrementTextDeserializations(for waxId: ObjectIdentifier) {
        stats.textDeserializations += 1
        var waxStats = statsByWax[waxId] ?? Stats()
        waxStats.textDeserializations += 1
        statsByWax[waxId] = waxStats
    }

    private func incrementVectorDeserializations(for waxId: ObjectIdentifier) {
        stats.vectorDeserializations += 1
        var waxStats = statsByWax[waxId] ?? Stats()
        waxStats.vectorDeserializations += 1
        statsByWax[waxId] = waxStats
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
                    engine: kind
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
                    engine: kind
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
                engine: kind
            ),
            .cosine,
            queryEmbeddingDimensions
        )
    }
}
