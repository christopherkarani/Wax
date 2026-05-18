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
        let encoding = try await currentEncoding(for: wax)
        let projectedCount = try await projectedVectorCount(for: wax, fallbackDimensions: dimensions)
        let selectedKind = try resolveKind(
            encoding: encoding,
            projectedVectorCount: projectedCount,
            preference: preference,
            allowEmptySelection: false
        )

        switch selectedKind {
        case .accelerate:
            return .accelerate(try await AccelerateVectorEngine.load(from: wax, metric: metric, dimensions: dimensions))
        #if canImport(Metal) && canImport(MetalANNS)
        case .metalANNS:
            return .metalANNS(try await MetalANNSVectorEngine.load(from: wax, metric: metric, dimensions: dimensions))
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
        let hasStaged = await wax.stagedVecIndexStamp() != nil
        let hasCommitted = await wax.committedVecIndexManifest() != nil
        let hasCommittedOrStaged = hasStaged || hasCommitted
        guard hasPending || hasCommittedOrStaged else { return nil }

        let encoding = try await currentEncoding(for: wax)
        let projectedCount = try await projectedVectorCount(
            for: wax,
            fallbackDimensions: queryEmbeddingDimensions,
            pendingSnapshot: snapshot
        )
        return try resolveKind(
            encoding: encoding,
            projectedVectorCount: projectedCount,
            preference: preference,
            allowEmptySelection: false
        )
    }

    package static func currentEncoding(for wax: Wax) async throws -> VectorSerializer.VecEncoding? {
        if let staged = await wax.readStagedVecIndexBytes() {
            return try validatedCurrentEncoding(from: staged.bytes)
        }
        if let bytes = try await wax.readCommittedVecIndexBytes() {
            return try validatedCurrentEncoding(from: bytes)
        }
        return nil
    }

    private static func validatedCurrentEncoding(from data: Data) throws -> VectorSerializer.VecEncoding {
        let encoding = try VectorSerializer.detectEncoding(from: data)
        guard encoding != .uSearch else {
            throw WaxError.invalidToc(reason: VectorSerializer.legacyUSearchUnsupportedReason)
        }
        return encoding
    }

    package static func projectedVectorCount(
        for wax: Wax,
        fallbackDimensions: Int,
        pendingSnapshot: PendingEmbeddingSnapshot? = nil
    ) async throws -> Int {
        var committedOrStaged = 0
        if let staged = await wax.readStagedVecIndexBytes() {
            let decoded = try VectorSerializer.decodeVecSegment(from: staged.bytes)
            committedOrStaged = try segmentVectorCount(for: decoded)
        } else if let manifest = await wax.committedVecIndexManifest() {
            committedOrStaged = try checkedVectorCount(
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
            committedOrStaged: committedOrStaged,
            pendingCount: pendingCount
        )
    }

    private static func resolveKind(
        encoding: VectorSerializer.VecEncoding?,
        projectedVectorCount: Int,
        preference: VectorEnginePreference,
        allowEmptySelection: Bool
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
               (allowEmptySelection || projectedVectorCount >= MetalANNSVectorEngine.autoThreshold) {
                return .metalANNS
            }
            #endif
            return .accelerate
        }
    }

    private static func segmentVectorCount(for payload: VectorSerializer.VecSegmentPayload) throws -> Int {
        switch payload {
        case .metal(let info, _, _):
            return try checkedVectorCount(info.vectorCount, context: "Metal vec segment")
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
