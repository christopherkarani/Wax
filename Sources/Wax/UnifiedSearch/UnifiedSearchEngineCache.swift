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
    /// The commit generation is: a commit that leaves the vec index bytes (and so
    /// the checksum) unchanged still starts a new pending window.
    enum VectorSourceKey: Hashable, Sendable {
        case pendingOnly(generation: UInt64, dimensions: Int, engine: LoadedVectorSearchEngine.Kind)
        case committed(
            generation: UInt64,
            checksum: Data,
            similarity: VecSimilarity,
            dimensions: Int,
            engine: LoadedVectorSearchEngine.Kind
        )
        case staged(
            generation: UInt64,
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

    /// Entries are found by `ObjectIdentifier(wax)` but only belong to the store
    /// that `owner` still points at: once a store is freed its address can be
    /// reused by a new one, which must not inherit the old store's engines.
    private struct CachedText {
        weak var owner: Wax?
        var key: TextSourceKey
        var engine: FTS5SearchEngine
    }

    private struct CachedVector {
        weak var owner: Wax?
        var key: VectorSourceKey
        var engine: LoadedVectorSearchEngine
        /// Latest pending-embedding sequence applied to `engine`.
        var syncedThrough: UInt64?
    }

    private struct OwnedStats {
        weak var owner: Wax?
        var stats: Stats
    }

    private var textByWax: [ObjectIdentifier: CachedText] = [:]
    private var vectorByWax: [ObjectIdentifier: CachedVector] = [:]
    private var stats = Stats()
    private var statsByWax: [ObjectIdentifier: OwnedStats] = [:]

    func snapshotStats() -> Stats { stats }

    func snapshotStats(for wax: Wax) -> Stats {
        guard let entry = statsByWax[ObjectIdentifier(wax)], entry.owner === wax else { return Stats() }
        return entry.stats
    }

    func resetStats() {
        stats = Stats()
    }

    func resetStats(for wax: Wax) {
        statsByWax[ObjectIdentifier(wax)] = OwnedStats(owner: wax, stats: Stats())
    }

    func textEngine(for wax: Wax) async throws -> FTS5SearchEngine {
        if let stamp = await wax.stagedLexIndexStamp() {
            let stagedBytes = await wax.readStagedLexIndexBytes()
            let key: TextSourceKey = .staged(stamp: stamp)
            if let cached = cachedText(for: wax), cached.key == key {
                return cached.engine
            }
            guard let bytes = stagedBytes else {
                let engine = try FTS5SearchEngine.inMemory()
                storeText(CachedText(owner: wax, key: .empty, engine: engine), for: wax)
                return engine
            }
            let engine = try FTS5SearchEngine.deserialize(from: bytes)
            incrementTextDeserializations(for: wax)
            storeText(CachedText(owner: wax, key: key, engine: engine), for: wax)
            return engine
        }

        if let manifest = await wax.committedLexIndexManifest() {
            let key: TextSourceKey = .committed(checksum: manifest.checksum)
            if let cached = cachedText(for: wax), cached.key == key {
                return cached.engine
            }
            if let bytes = try await wax.readCommittedLexIndexBytes() {
                let engine = try FTS5SearchEngine.deserialize(from: bytes)
                incrementTextDeserializations(for: wax)
                storeText(CachedText(owner: wax, key: key, engine: engine), for: wax)
                return engine
            }
        }

        if let cached = cachedText(for: wax), cached.key == .empty {
            return cached.engine
        }
        let engine = try FTS5SearchEngine.inMemory()
        storeText(CachedText(owner: wax, key: .empty, engine: engine), for: wax)
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

        let latestPending = pendingSnapshot.latestSequence
        if let cached = cachedVector(for: wax), cached.key == descriptor.key {
            if cached.syncedThrough == latestPending {
                return cached.engine
            }
            if let latestPending, cached.syncedThrough.map({ $0 < latestPending }) ?? true {
                // Only new writes since the last search: apply them instead of
                // rebuilding the engine from the whole index. `load` adds pending
                // embeddings with the same `addBatch`, so the exact (Accelerate)
                // engine ends up identical; MetalANNS grows its graph per insert,
                // so its approximate top-K may differ slightly from a rebuild.
                let delta = await wax.pendingEmbeddingMutations(since: cached.syncedThrough)
                if !delta.embeddings.isEmpty {
                    try await cached.engine.addBatch(
                        frameIds: delta.embeddings.map(\.frameId),
                        vectors: delta.embeddings.map(\.vector)
                    )
                }
                recordVectorSync(for: wax, key: descriptor.key, through: delta.latestSequence)
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
        incrementVectorDeserializations(for: wax)
        // `load` applies every pending embedding present when it read them, which
        // is at least `latestPending`; a later write is re-applied idempotently.
        storeVector(
            CachedVector(owner: wax, key: descriptor.key, engine: loaded, syncedThrough: latestPending),
            for: wax
        )
        return loaded
    }

    /// Searches can interleave across the `addBatch` await. Adds are idempotent
    /// overwrites, so only move the watermark forward and only for the same index.
    private func recordVectorSync(for wax: Wax, key: VectorSourceKey, through sequence: UInt64?) {
        guard var cached = cachedVector(for: wax), cached.key == key, let sequence else { return }
        if let synced = cached.syncedThrough, synced >= sequence { return }
        cached.syncedThrough = sequence
        vectorByWax[ObjectIdentifier(wax)] = cached
    }

    private func cachedText(for wax: Wax) -> CachedText? {
        guard let cached = textByWax[ObjectIdentifier(wax)], cached.owner === wax else { return nil }
        return cached
    }

    private func cachedVector(for wax: Wax) -> CachedVector? {
        guard let cached = vectorByWax[ObjectIdentifier(wax)], cached.owner === wax else { return nil }
        return cached
    }

    private func storeText(_ entry: CachedText, for wax: Wax) {
        pruneReleasedStores()
        textByWax[ObjectIdentifier(wax)] = entry
    }

    private func storeVector(_ entry: CachedVector, for wax: Wax) {
        pruneReleasedStores()
        vectorByWax[ObjectIdentifier(wax)] = entry
    }

    /// Drops entries whose store was freed, so engines do not outlive their store.
    /// Runs only when an engine is (re)built, which already costs O(index size).
    private func pruneReleasedStores() {
        textByWax = textByWax.filter { $0.value.owner != nil }
        vectorByWax = vectorByWax.filter { $0.value.owner != nil }
        statsByWax = statsByWax.filter { $0.value.owner != nil }
    }

    private func incrementTextDeserializations(for wax: Wax) {
        stats.textDeserializations += 1
        updateStats(for: wax) { $0.textDeserializations += 1 }
    }

    private func incrementVectorDeserializations(for wax: Wax) {
        stats.vectorDeserializations += 1
        updateStats(for: wax) { $0.vectorDeserializations += 1 }
    }

    private func updateStats(for wax: Wax, _ change: (inout Stats) -> Void) {
        var waxStats = snapshotStats(for: wax)
        change(&waxStats)
        statsByWax[ObjectIdentifier(wax)] = OwnedStats(owner: wax, stats: waxStats)
    }

    private func vectorLoadDescriptor(
        for wax: Wax,
        queryEmbeddingDimensions: Int,
        preference: VectorEnginePreference,
        pendingSnapshot: PendingEmbeddingSnapshot
    ) async throws -> (key: VectorSourceKey, metric: VectorMetric, dimensions: Int)? {
        let generation = await wax.stats().generation
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
                    generation: generation,
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
                    generation: generation,
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
                generation: generation,
                dimensions: queryEmbeddingDimensions,
                engine: kind
            ),
            .cosine,
            queryEmbeddingDimensions
        )
    }
}
