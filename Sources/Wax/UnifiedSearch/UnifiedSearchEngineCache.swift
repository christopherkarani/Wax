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

    enum VectorSourceKey: Hashable, Sendable {
        case none
        case pendingOnly(dimensions: Int, engine: VectorEngineKind)
        case committed(checksum: Data, similarity: VecSimilarity, dimensions: Int, engine: VectorEngineKind)
        case staged(stamp: UInt64, similarity: VecSimilarity, dimensions: Int, engine: VectorEngineKind)
    }

    enum VectorEngineKind: Hashable, Sendable {
        case usearch
        case metal
    }

    struct Stats: Sendable, Equatable {
        var textDeserializations: Int = 0
        var vectorDeserializations: Int = 0
    }

    struct EntryCounts: Sendable, Equatable {
        var text: Int
        var vector: Int
    }

    private struct StoreIdentity: Hashable, Sendable {
        let canonicalPath: String
        let generation: UInt64
    }

    private struct CachedText {
        var key: TextSourceKey
        var engine: FTS5SearchEngine
        var lastAccess: Date
    }

    private struct CachedVector {
        var key: VectorSourceKey
        var engine: any VectorSearchEngine
        var lastPendingEmbeddingSequence: UInt64?
        var lastAccess: Date
    }

    private static let maxEntriesPerTier = 64
    private static let entryTTLSeconds: TimeInterval = 15 * 60

    private var textByStore: [StoreIdentity: CachedText] = [:]
    private var vectorByStore: [StoreIdentity: CachedVector] = [:]
    private var textLRU: [StoreIdentity] = []
    private var vectorLRU: [StoreIdentity] = []
    private var stats = Stats()

    func snapshotStats() -> Stats { stats }

    func snapshotEntryCounts() -> EntryCounts {
        EntryCounts(text: textByStore.count, vector: vectorByStore.count)
    }

    func containsEntry(for wax: Wax) async -> Bool {
        let canonicalPath = await storeCanonicalPath(for: wax)
        return textByStore.keys.contains(where: { $0.canonicalPath == canonicalPath })
            || vectorByStore.keys.contains(where: { $0.canonicalPath == canonicalPath })
    }

    func resetStats() {
        stats = Stats()
    }

    func resetForTests() {
        textByStore.removeAll()
        vectorByStore.removeAll()
        textLRU.removeAll()
        vectorLRU.removeAll()
        stats = Stats()
    }

    func invalidate(for wax: Wax) async {
        let canonicalPath = await storeCanonicalPath(for: wax)
        invalidate(canonicalPath: canonicalPath)
    }

    func textEngine(for wax: Wax) async throws -> FTS5SearchEngine {
        let now = Date()
        expireStaleEntries(now: now)
        let store = await storeIdentity(for: wax)

        if let stamp = await wax.stagedLexIndexStamp() {
            let stagedBytes = await wax.readStagedLexIndexBytes()
            let key: TextSourceKey = .staged(stamp: stamp)
            if let cached = textByStore[store], cached.key == key {
                touchTextEntry(for: store, at: now)
                return cached.engine
            }
            guard let bytes = stagedBytes else {
                let engine = try FTS5SearchEngine.inMemory()
                textByStore[store] = CachedText(key: .empty, engine: engine, lastAccess: now)
                touchTextEntry(for: store, at: now)
                return engine
            }
            let engine = try FTS5SearchEngine.deserialize(from: bytes)
            stats.textDeserializations += 1
            textByStore[store] = CachedText(key: key, engine: engine, lastAccess: now)
            touchTextEntry(for: store, at: now)
            return engine
        }

        if let manifest = await wax.committedLexIndexManifest() {
            let key: TextSourceKey = .committed(checksum: manifest.checksum)
            if let cached = textByStore[store], cached.key == key {
                touchTextEntry(for: store, at: now)
                return cached.engine
            }
            if let bytes = try await wax.readCommittedLexIndexBytes() {
                let engine = try FTS5SearchEngine.deserialize(from: bytes)
                stats.textDeserializations += 1
                textByStore[store] = CachedText(key: key, engine: engine, lastAccess: now)
                touchTextEntry(for: store, at: now)
                return engine
            }
        }

        if let cached = textByStore[store], cached.key == .empty {
            touchTextEntry(for: store, at: now)
            return cached.engine
        }
        let engine = try FTS5SearchEngine.inMemory()
        textByStore[store] = CachedText(key: .empty, engine: engine, lastAccess: now)
        touchTextEntry(for: store, at: now)
        return engine
    }

    func vectorEngine(
        for wax: Wax,
        queryEmbeddingDimensions: Int,
        preference: VectorEnginePreference = .auto
    ) async throws -> (any VectorSearchEngine)? {
        guard queryEmbeddingDimensions > 0 else { return nil }

        let now = Date()
        expireStaleEntries(now: now)
        let store = await storeIdentity(for: wax)
        let allowMetal = preference != .cpuOnly && MetalVectorEngine.isAvailable

        if allowMetal {
            if let metalEngine = try await vectorEngine(
                for: wax,
                store: store,
                queryEmbeddingDimensions: queryEmbeddingDimensions,
                engineKind: .metal,
                now: now
            ) {
                return metalEngine
            }
        }

        return try await vectorEngine(
            for: wax,
            store: store,
            queryEmbeddingDimensions: queryEmbeddingDimensions,
            engineKind: .usearch,
            now: now
        )
    }

    private func vectorEngine(
        for wax: Wax,
        store: StoreIdentity,
        queryEmbeddingDimensions: Int,
        engineKind: VectorEngineKind,
        now: Date
    ) async throws -> (any VectorSearchEngine)? {
        let engineKindTag = engineKind
        let preferMetal = engineKind == .metal

        let makeEngine: (VectorMetric, Int) throws -> any VectorSearchEngine = { metric, dimensions in
            if preferMetal {
                return try MetalVectorEngine(metric: metric, dimensions: dimensions)
            }
            return try USearchVectorEngine(metric: metric, dimensions: dimensions)
        }

        let deserialize: (any VectorSearchEngine, Data) async throws -> Void = { engine, bytes in
            switch engineKindTag {
            case .metal:
                guard let metal = engine as? MetalVectorEngine else {
                    throw WaxError.invalidToc(reason: "metal engine type mismatch")
                }
                try await metal.deserialize(bytes)
            case .usearch:
                guard let usearch = engine as? USearchVectorEngine else {
                    throw WaxError.invalidToc(reason: "usearch engine type mismatch")
                }
                try await usearch.deserialize(bytes)
            }
        }

        if let manifest = await wax.committedVecIndexManifest(),
           let metric = VectorMetric(vecSimilarity: manifest.similarity) {
            let key: VectorSourceKey = .committed(
                checksum: manifest.checksum,
                similarity: manifest.similarity,
                dimensions: Int(manifest.dimension),
                engine: engineKind
            )
            if let cached = vectorByStore[store], cached.key == key {
                try await applyPendingEmbeddingsIfNeeded(wax: wax, store: store, cached: cached)
                touchVectorEntry(for: store, at: now)
                return vectorByStore[store]?.engine
            }
            do {
                let engine = try makeEngine(metric, Int(manifest.dimension))
                if let bytes = try await wax.readCommittedVecIndexBytes() {
                    try await deserialize(engine, bytes)
                }
                stats.vectorDeserializations += 1
                let cached = CachedVector(
                    key: key,
                    engine: engine,
                    lastPendingEmbeddingSequence: nil,
                    lastAccess: now
                )
                vectorByStore[store] = cached
                touchVectorEntry(for: store, at: now)
                try await applyPendingEmbeddingsIfNeeded(wax: wax, store: store, cached: cached)
                return engine
            } catch {
                return nil
            }
        }

        if let stamp = await wax.stagedVecIndexStamp(),
           let staged = await wax.readStagedVecIndexBytes(),
           let metric = VectorMetric(vecSimilarity: staged.similarity) {
            let key: VectorSourceKey = .staged(
                stamp: stamp,
                similarity: staged.similarity,
                dimensions: Int(staged.dimension),
                engine: engineKind
            )
            if let cached = vectorByStore[store], cached.key == key {
                try await applyPendingEmbeddingsIfNeeded(wax: wax, store: store, cached: cached)
                touchVectorEntry(for: store, at: now)
                return vectorByStore[store]?.engine
            }

            do {
                let engine = try makeEngine(metric, Int(staged.dimension))
                try await deserialize(engine, staged.bytes)
                stats.vectorDeserializations += 1
                let pendingSnapshot = await wax.pendingEmbeddingMutations(since: nil)
                let cached = CachedVector(
                    key: key,
                    engine: engine,
                    lastPendingEmbeddingSequence: pendingSnapshot.latestSequence,
                    lastAccess: now
                )
                vectorByStore[store] = cached
                touchVectorEntry(for: store, at: now)
                return engine
            } catch {
                return nil
            }
        }

        let pendingSnapshot = await wax.pendingEmbeddingMutations(since: nil)
        if !pendingSnapshot.embeddings.isEmpty,
           pendingSnapshot.embeddings.first?.dimension == UInt32(queryEmbeddingDimensions) {
            let key: VectorSourceKey = .pendingOnly(
                dimensions: queryEmbeddingDimensions,
                engine: engineKind
            )
            if let cached = vectorByStore[store], cached.key == key {
                try await applyPendingEmbeddingsIfNeeded(
                    wax: wax,
                    store: store,
                    cached: cached,
                    pendingSnapshot: pendingSnapshot
                )
                touchVectorEntry(for: store, at: now)
                return vectorByStore[store]?.engine
            }

            do {
                let engine = try makeEngine(.cosine, queryEmbeddingDimensions)
                let cached = CachedVector(
                    key: key,
                    engine: engine,
                    lastPendingEmbeddingSequence: nil,
                    lastAccess: now
                )
                vectorByStore[store] = cached
                touchVectorEntry(for: store, at: now)
                try await applyPendingEmbeddingsIfNeeded(
                    wax: wax,
                    store: store,
                    cached: cached,
                    pendingSnapshot: pendingSnapshot
                )
                return engine
            } catch {
                return nil
            }
        }

        return nil
    }

    private func applyPendingEmbeddingsIfNeeded(
        wax: Wax,
        store: StoreIdentity,
        cached: CachedVector,
        pendingSnapshot: PendingEmbeddingSnapshot? = nil
    ) async throws {
        guard var current = vectorByStore[store], current.key == cached.key else { return }

        let snapshot: PendingEmbeddingSnapshot
        if let provided = pendingSnapshot {
            snapshot = provided
        } else {
            snapshot = await wax.pendingEmbeddingMutations(
                since: current.lastPendingEmbeddingSequence
            )
        }

        if let latest = snapshot.latestSequence,
           let last = current.lastPendingEmbeddingSequence,
           latest < last {
            current.lastPendingEmbeddingSequence = nil
        }

        if !snapshot.embeddings.isEmpty {
            let frameIds = snapshot.embeddings.map(\.frameId)
            let vectors = snapshot.embeddings.map(\.vector)
            try await current.engine.addBatch(frameIds: frameIds, vectors: vectors)
        }

        current.lastPendingEmbeddingSequence = snapshot.latestSequence
        current.lastAccess = Date()
        vectorByStore[store] = current
        touchVectorEntry(for: store, at: current.lastAccess)
    }

    private func touchTextEntry(for store: StoreIdentity, at now: Date) {
        if var cached = textByStore[store] {
            cached.lastAccess = now
            textByStore[store] = cached
        }
        if let existing = textLRU.firstIndex(of: store) {
            textLRU.remove(at: existing)
        }
        textLRU.append(store)

        while textByStore.count > Self.maxEntriesPerTier,
              let oldest = textLRU.first {
            textLRU.removeFirst()
            textByStore.removeValue(forKey: oldest)
        }
    }

    private func touchVectorEntry(for store: StoreIdentity, at now: Date) {
        if var cached = vectorByStore[store] {
            cached.lastAccess = now
            vectorByStore[store] = cached
        }
        if let existing = vectorLRU.firstIndex(of: store) {
            vectorLRU.remove(at: existing)
        }
        vectorLRU.append(store)

        while vectorByStore.count > Self.maxEntriesPerTier,
              let oldest = vectorLRU.first {
            vectorLRU.removeFirst()
            vectorByStore.removeValue(forKey: oldest)
        }
    }

    private func expireStaleEntries(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.entryTTLSeconds)

        let staleText = textByStore.compactMap { key, value in
            value.lastAccess < cutoff ? key : nil
        }
        if !staleText.isEmpty {
            for key in staleText {
                textByStore.removeValue(forKey: key)
            }
            textLRU.removeAll { staleText.contains($0) }
        }

        let staleVector = vectorByStore.compactMap { key, value in
            value.lastAccess < cutoff ? key : nil
        }
        if !staleVector.isEmpty {
            for key in staleVector {
                vectorByStore.removeValue(forKey: key)
            }
            vectorLRU.removeAll { staleVector.contains($0) }
        }
    }

    private func invalidate(canonicalPath: String) {
        let textKeysToDrop = textByStore.keys.filter { $0.canonicalPath == canonicalPath }
        for key in textKeysToDrop {
            textByStore.removeValue(forKey: key)
        }
        textLRU.removeAll { $0.canonicalPath == canonicalPath }

        let vectorKeysToDrop = vectorByStore.keys.filter { $0.canonicalPath == canonicalPath }
        for key in vectorKeysToDrop {
            vectorByStore.removeValue(forKey: key)
        }
        vectorLRU.removeAll { $0.canonicalPath == canonicalPath }
    }

    private func storeIdentity(for wax: Wax) async -> StoreIdentity {
        async let stats = wax.stats()
        async let fileURL = wax.fileURL()
        let resolvedStats = await stats
        let resolvedURL = await fileURL
        return StoreIdentity(
            canonicalPath: canonicalPath(for: resolvedURL),
            generation: resolvedStats.generation
        )
    }

    private func storeCanonicalPath(for wax: Wax) async -> String {
        let fileURL = await wax.fileURL()
        return canonicalPath(for: fileURL)
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
