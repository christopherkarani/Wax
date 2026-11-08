import Foundation
import WaxCore

package enum LoadedVectorSearchEngine: Sendable {
    package enum Kind: Hashable, Sendable {
        case accelerate
        #if canImport(Metal) && canImport(MetalANNS)
        case metalANNS
        #endif
    }

    case accelerate(AccelerateVectorEngine)
    #if canImport(Metal) && canImport(MetalANNS)
    case metalANNS(MetalANNSVectorEngine)
    #endif

    package var erased: any VectorSearchEngine {
        switch self {
        case .accelerate(let engine):
            return engine
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS(let engine):
            return engine
        #endif
        }
    }

    package var kind: Kind {
        switch self {
        case .accelerate:
            return .accelerate
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS:
            return .metalANNS
        #endif
        }
    }

    package func add(frameId: UInt64, vector: [Float]) async throws {
        switch self {
        case .accelerate(let engine):
            try await engine.add(frameId: frameId, vector: vector)
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS(let engine):
            try await engine.add(frameId: frameId, vector: vector)
        #endif
        }
    }

    package func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        switch self {
        case .accelerate(let engine):
            try await engine.addBatch(frameIds: frameIds, vectors: vectors)
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS(let engine):
            try await engine.addBatch(frameIds: frameIds, vectors: vectors)
        #endif
        }
    }

    package func storedFrameIds() async -> Set<UInt64> {
        switch self {
        case .accelerate(let engine):
            await engine.storedFrameIds()
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS(let engine):
            await engine.storedFrameIds()
        #endif
        }
    }

    package func remove(frameId: UInt64) async throws {
        switch self {
        case .accelerate(let engine):
            try await engine.remove(frameId: frameId)
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS(let engine):
            try await engine.remove(frameId: frameId)
        #endif
        }
    }

    package func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        switch self {
        case .accelerate(let engine):
            return try await engine.search(vector: vector, topK: topK)
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS(let engine):
            return try await engine.search(vector: vector, topK: topK)
        #endif
        }
    }

    /// Records the index's dimension and similarity for the commit, which writes the pending
    /// vector changes from the WAL.
    package func stageForCommit(into wax: Wax) async throws {
        switch self {
        case .accelerate(let engine):
            try await engine.stageForCommit(into: wax)
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS(let engine):
            try await engine.stageForCommit(into: wax)
        #endif
        }
    }

    package static func load(
        from wax: Wax,
        metric: VectorMetric,
        dimensions: Int,
        preference: VectorEnginePreference
    ) async throws -> LoadedVectorSearchEngine {
        let projectedCount = try await projectedVectorCount(for: wax, fallbackDimensions: dimensions)
        let selectedKind = try resolveKind(projectedVectorCount: projectedCount, preference: preference)
        // Read (and checksum) the runs once, after choosing the kind.
        let committed = try await wax.readCommittedVectors()

        switch selectedKind {
        case .accelerate:
            return .accelerate(try await AccelerateVectorEngine.load(
                from: wax,
                committed: committed,
                metric: metric,
                dimensions: dimensions
            ))
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS:
            return .metalANNS(try await MetalANNSVectorEngine.load(
                from: wax,
                committed: committed,
                metric: metric,
                dimensions: dimensions
            ))
        #endif
        }
    }

    package static func preferredKind(
        for wax: Wax,
        queryEmbeddingDimensions: Int,
        preference: VectorEnginePreference,
        pendingSnapshot: PendingEmbeddingSnapshot? = nil
    ) async throws -> Kind? {
        let snapshot: PendingEmbeddingSnapshot
        if let pendingSnapshot {
            snapshot = pendingSnapshot
        } else {
            snapshot = await wax.pendingEmbeddingMutations(since: nil)
        }
        let hasPending = snapshot.embeddings.contains { embedding in embedding.dimension == UInt32(queryEmbeddingDimensions) }
        let hasCommitted = await wax.committedVecIndexManifest() != nil
        guard hasPending || hasCommitted else { return nil }

        let projectedCount = try await projectedVectorCount(
            for: wax,
            fallbackDimensions: queryEmbeddingDimensions,
            pendingSnapshot: snapshot
        )
        return try resolveKind(projectedVectorCount: projectedCount, preference: preference)
    }

    /// Committed vectors plus pending embeddings of `fallbackDimensions`: an upper bound, since
    /// a pending embedding can replace a committed vector.
    package static func projectedVectorCount(
        for wax: Wax,
        fallbackDimensions: Int,
        pendingSnapshot: PendingEmbeddingSnapshot? = nil
    ) async throws -> Int {
        var committedCount = 0
        if let manifest = await wax.committedVecIndexManifest() {
            committedCount = try checkedVectorCount(
                manifest.vectorCount,
                context: "committed vec index manifest"
            )
        }

        let snapshot: PendingEmbeddingSnapshot
        if let pendingSnapshot {
            snapshot = pendingSnapshot
        } else {
            snapshot = await wax.pendingEmbeddingMutations(since: nil)
        }
        let pendingCount = snapshot.embeddings.reduce(into: 0) { count, embedding in
            if embedding.dimension == UInt32(fallbackDimensions) {
                count += 1
            }
        }
        return try checkedProjectedVectorCount(
            committedOrStaged: committedCount,
            pendingCount: pendingCount
        )
    }

    private static func resolveKind(
        projectedVectorCount: Int,
        preference: VectorEnginePreference
    ) throws -> Kind {
        switch preference {
        case .cpuOnly:
            return .accelerate
        case .gpuOnly:
            #if canImport(Metal) && canImport(MetalANNS)
            guard MetalANNSVectorEngine.isAvailable else {
                throw WaxError.io("gpuOnly requested but Metal is not available")
            }
            return .metalANNS
            #else
            throw WaxError.io("gpuOnly requested but MetalANNS is unavailable on this platform")
            #endif
        case .auto, .metalPreferred:
            #if canImport(Metal) && canImport(MetalANNS)
            if MetalANNSVectorEngine.isAvailable,
               projectedVectorCount >= MetalANNSVectorEngine.autoThreshold {
                return .metalANNS
            }
            #endif
            return .accelerate
        }
    }

    private static func checkedVectorCount(_ vectorCount: UInt64, context: String) throws -> Int {
        guard vectorCount <= UInt64(Int.max) else {
            throw WaxError.invalidToc(reason: "\(context) vector count exceeds Int.max")
        }
        return Int(vectorCount)
    }

    package static func checkedProjectedVectorCount(committedOrStaged: Int, pendingCount: Int) throws -> Int {
        let total = committedOrStaged.addingReportingOverflow(pendingCount)
        guard !total.overflow else {
            throw WaxError.invalidToc(reason: "projected vector count exceeds Int.max")
        }
        return total.partialValue
    }
}
