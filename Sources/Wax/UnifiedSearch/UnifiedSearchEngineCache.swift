import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

actor UnifiedSearchEngineCache {
    static let shared = UnifiedSearchEngineCache()
    static let metalAutoMaxVectorCount: UInt64 = {
        if let raw = ProcessInfo.processInfo.environment["WAX_METAL_AUTO_MAX_VECTORS"],
           let value = UInt64(raw), value > 0 {
            return value
        }
        return 20_000
    }()
    static let metalAutoMaxTopK: Int = {
        if let raw = ProcessInfo.processInfo.environment["WAX_METAL_AUTO_MAX_TOPK"],
           let value = Int(raw), value > 0 {
            return value
        }
        return 64
    }()

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
        var engine: any VectorSearchEngine
        var lastPendingEmbeddingSequence: UInt64?
    }

    private var textByWax: [ObjectIdentifier: CachedText] = [:]
    private var vectorByWax: [ObjectIdentifier: CachedVector] = [:]
    private var stats = Stats()

    enum VectorEngineKind: Hashable, Sendable {
        case usearch
        case metal
    }

    static func autoEngineKind(for vectorCount: UInt64, topK: Int?) -> VectorEngineKind {
        if let topK, topK > metalAutoMaxTopK {
            return .usearch
        }
        return vectorCount <= metalAutoMaxVectorCount ? .metal : .usearch
    }

    static func preferredEngineOrder(
        preference: VectorEnginePreference,
        vectorCount: UInt64,
        topK: Int?
    ) -> [VectorEngineKind] {
        switch preference {
        case .cpuOnly:
            return [.usearch]
        case .metalPreferred:
            return [.metal, .usearch]
        case .auto:
            let first = autoEngineKind(for: vectorCount, topK: topK)
            return first == .metal ? [.metal, .usearch] : [.usearch, .metal]
        }
    }

    func snapshotStats() -> Stats { stats }

    func resetStats() {
        stats = Stats()
    }

    func textEngine(for wax: Wax) async throws -> FTS5SearchEngine {
        let waxId = ObjectIdentifier(wax)

        if let stamp = await wax.stagedLexIndexStamp(),
           let _ = await wax.readStagedLexIndexBytes() {
            let key: TextSourceKey = .staged(stamp: stamp)
            if let cached = textByWax[waxId], cached.key == key {
                return cached.engine
            }
            guard let bytes = await wax.readStagedLexIndexBytes() else {
                let engine = try FTS5SearchEngine.inMemory()
                textByWax[waxId] = CachedText(key: .empty, engine: engine)
                return engine
            }
            let engine = try FTS5SearchEngine.deserializeReadOnly(from: bytes)
            stats.textDeserializations += 1
            textByWax[waxId] = CachedText(key: key, engine: engine)
            return engine
        }

        if let manifest = await wax.committedLexIndexManifest() {
            let key: TextSourceKey = .committed(checksum: manifest.checksum)
            if let cached = textByWax[waxId], cached.key == key {
                return cached.engine
            }
            if let region = try await wax.readCommittedLexIndexMapped() {
                let engine = try FTS5SearchEngine.deserializeReadOnly(from: region)
                stats.textDeserializations += 1
                textByWax[waxId] = CachedText(key: key, engine: engine)
                return engine
            }
            if let bytes = try await wax.readCommittedLexIndexBytes() {
                let engine = try FTS5SearchEngine.deserializeReadOnly(from: bytes)
                stats.textDeserializations += 1
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
        preference: VectorEnginePreference = .auto,
        topK: Int? = nil
    ) async throws -> (any VectorSearchEngine)? {
        guard queryEmbeddingDimensions > 0 else { return nil }

        let waxId = ObjectIdentifier(wax)
        let vectorCount = await vectorCountHint(
            wax: wax,
            queryEmbeddingDimensions: queryEmbeddingDimensions
        ) ?? 0
        let order = Self.preferredEngineOrder(
            preference: preference,
            vectorCount: vectorCount,
            topK: topK
        )

        for kind in order {
            if kind == .metal && !MetalVectorEngine.isAvailable {
                continue
            }
            if let engine = try await vectorEngine(
                for: wax,
                waxId: waxId,
                queryEmbeddingDimensions: queryEmbeddingDimensions,
                engineKind: kind
            ) {
                return engine
            }
        }

        return nil
    }

    private func vectorCountHint(
        wax: Wax,
        queryEmbeddingDimensions: Int
    ) async -> UInt64? {
        if let manifest = await wax.committedVecIndexManifest() {
            return manifest.vectorCount
        }

        if let staged = await wax.readStagedVecIndexBytes() {
            if let info = try? VectorSerializer.decodeHeader(from: staged.bytes) {
                return info.vectorCount
            }
        }

        let pendingSnapshot = await wax.pendingEmbeddingMutations(since: nil)
        if !pendingSnapshot.embeddings.isEmpty,
           pendingSnapshot.embeddings.first?.dimension == UInt32(queryEmbeddingDimensions) {
            return UInt64(pendingSnapshot.embeddings.count)
        }

        return nil
    }

    private func vectorEngine(
        for wax: Wax,
        waxId: ObjectIdentifier,
        queryEmbeddingDimensions: Int,
        engineKind: VectorEngineKind
    ) async throws -> (any VectorSearchEngine)? {
        let engineKindTag = engineKind
        let preferMetal = engineKind == .metal

        let makeEngine: (VectorMetric, Int, VecQuantization) throws -> any VectorSearchEngine = { metric, dimensions, quantization in
            if preferMetal {
                return try MetalVectorEngine(metric: metric, dimensions: dimensions)
            }
            return try USearchVectorEngine(metric: metric, dimensions: dimensions, quantization: quantization)
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
            let committedBytes = try await wax.readCommittedVecIndexBytes()
            let quantization: VecQuantization = committedBytes
                .flatMap { try? VectorSerializer.decodeHeader(from: $0).quantization } ?? .f32
            let key: VectorSourceKey = .committed(
                checksum: manifest.checksum,
                similarity: manifest.similarity,
                dimensions: Int(manifest.dimension),
                engine: engineKind
            )
            if let cached = vectorByWax[waxId], cached.key == key {
                try await applyPendingEmbeddingsIfNeeded(wax: wax, waxId: waxId, cached: cached)
                return vectorByWax[waxId]?.engine
            }
            do {
                let engine = try makeEngine(metric, Int(manifest.dimension), quantization)
                if let bytes = committedBytes {
                    try await deserialize(engine, bytes)
                }
                stats.vectorDeserializations += 1
                let cached = CachedVector(
                    key: key,
                    engine: engine,
                    lastPendingEmbeddingSequence: nil
                )
                vectorByWax[waxId] = cached
                try await applyPendingEmbeddingsIfNeeded(wax: wax, waxId: waxId, cached: cached)
                return engine
            } catch {
                return nil
            }
        }

        if let stamp = await wax.stagedVecIndexStamp(),
           let staged = await wax.readStagedVecIndexBytes(),
           let metric = VectorMetric(vecSimilarity: staged.similarity) {
            let quantization: VecQuantization = (try? VectorSerializer.decodeHeader(from: staged.bytes).quantization) ?? .f32
            let key: VectorSourceKey = .staged(
                stamp: stamp,
                similarity: staged.similarity,
                dimensions: Int(staged.dimension),
                engine: engineKind
            )
            if let cached = vectorByWax[waxId], cached.key == key {
                try await applyPendingEmbeddingsIfNeeded(wax: wax, waxId: waxId, cached: cached)
                return vectorByWax[waxId]?.engine
            }

            do {
                let engine = try makeEngine(metric, Int(staged.dimension), quantization)
                try await deserialize(engine, staged.bytes)
                stats.vectorDeserializations += 1
                let pendingSnapshot = await wax.pendingEmbeddingMutations(since: nil)
                let cached = CachedVector(
                    key: key,
                    engine: engine,
                    lastPendingEmbeddingSequence: pendingSnapshot.latestSequence
                )
                vectorByWax[waxId] = cached
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
            if let cached = vectorByWax[waxId], cached.key == key {
                try await applyPendingEmbeddingsIfNeeded(
                    wax: wax,
                    waxId: waxId,
                    cached: cached,
                    pendingSnapshot: pendingSnapshot
                )
                return vectorByWax[waxId]?.engine
            }

            do {
                let engine = try makeEngine(.cosine, queryEmbeddingDimensions, .f32)
                let cached = CachedVector(key: key, engine: engine, lastPendingEmbeddingSequence: nil)
                vectorByWax[waxId] = cached
                try await applyPendingEmbeddingsIfNeeded(
                    wax: wax,
                    waxId: waxId,
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
        waxId: ObjectIdentifier,
        cached: CachedVector,
        pendingSnapshot: PendingEmbeddingSnapshot? = nil
    ) async throws {
        guard var current = vectorByWax[waxId], current.key == cached.key else { return }

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
        vectorByWax[waxId] = current
    }
}
