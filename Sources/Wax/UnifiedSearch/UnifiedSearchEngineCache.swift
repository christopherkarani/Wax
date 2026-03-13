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

    private struct CachedText {
        var key: TextSourceKey
        var engine: FTS5SearchEngine
    }

    private struct CachedVector {
        var key: VectorSourceKey
        var engine: any VectorSearchEngine
    }

    private var textByWax: [ObjectIdentifier: CachedText] = [:]
    private var vectorByWax: [ObjectIdentifier: CachedVector] = [:]
    private var stats = Stats()

    func snapshotStats() -> Stats { stats }

    func resetStats() {
        stats = Stats()
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
            stats.textDeserializations += 1
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

        let waxId = ObjectIdentifier(wax)
        if let cached = vectorByWax[waxId], cached.key == descriptor.key {
            return cached.engine
        }

        let loaded = try await LoadedVectorSearchEngine.load(
            from: wax,
            metric: descriptor.metric,
            dimensions: descriptor.dimensions,
            preference: preference
        )
        stats.vectorDeserializations += 1
        vectorByWax[waxId] = CachedVector(key: descriptor.key, engine: loaded.erased)
        return loaded.erased
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
