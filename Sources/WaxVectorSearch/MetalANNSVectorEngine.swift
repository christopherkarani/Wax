#if canImport(Metal) && canImport(MetalANNS)
import Foundation
import Metal
import MetalANNS
import WaxCore

package actor MetalANNSVectorEngine: VectorSearchEngine {
    package static let autoThreshold = 10_000

    private let metric: VectorMetric
    package let dimensions: Int
    private let configuration: IndexConfiguration

    private var index: VectorIndex<UInt64, VectorIndexState.Ready>?
    private var frameIds: [UInt64] = []
    private var positions: [UInt64: Int] = [:]
    private var vectors: [Float] = []
    private var dirty = false

    package static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    package init(metric: VectorMetric, dimensions: Int) throws {
        guard dimensions > 0 else {
            throw WaxError.invalidToc(reason: "dimensions must be > 0")
        }
        guard dimensions <= Constants.maxEmbeddingDimensions else {
            throw WaxError.capacityExceeded(
                limit: UInt64(Constants.maxEmbeddingDimensions),
                requested: UInt64(dimensions)
            )
        }
        self.metric = metric
        self.dimensions = dimensions
        var configuration = IndexConfiguration.default
        configuration.metric = metric.toMetalANNSMetric()
        self.configuration = configuration
    }

    package static func load(from wax: Wax, metric: VectorMetric, dimensions: Int) async throws -> MetalANNSVectorEngine {
        let engine = try MetalANNSVectorEngine(metric: metric, dimensions: dimensions)
        if let staged = await wax.readStagedVecIndexBytes() {
            try await engine.deserialize(staged.bytes)
        } else if let bytes = try await wax.readCommittedVecIndexBytes() {
            try await engine.deserialize(bytes)
        }
        let pending = await wax.pendingEmbeddingMutations(since: nil)
        if !pending.embeddings.isEmpty {
            try await engine.addBatch(
                frameIds: pending.embeddings.map(\.frameId),
                vectors: pending.embeddings.map(\.vector)
            )
        }
        return engine
    }

    package func add(frameId: UInt64, vector: [Float]) async throws {
        try validate(vector)
        let stored = preparedVector(vector)
        let record = VectorRecord(id: frameId, vector: stored)

        if let existingIndex = positions[frameId] {
            overwriteVector(at: existingIndex, with: stored)
            if let index {
                try await index.delete(id: frameId)
                try await index.insert(record)
            } else {
                try await rebuildIndex()
            }
        } else {
            let newIndex = frameIds.count
            frameIds.append(frameId)
            positions[frameId] = newIndex
            vectors.append(contentsOf: stored)
            if let index {
                try await index.insert(record)
            } else {
                try await rebuildIndex()
            }
        }
        dirty = true
    }

    package func addBatch(frameIds: [UInt64], vectors newVectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == newVectors.count else {
            throw WaxError.encodingError(reason: "addBatch: frameIds.count != vectors.count")
        }
        for vector in newVectors {
            try validate(vector)
        }

        var recordsToInsert: [VectorRecord<UInt64>] = []
        recordsToInsert.reserveCapacity(frameIds.count)
        let hadIndex = index != nil

        for (frameId, vector) in zip(frameIds, newVectors) {
            let stored = preparedVector(vector)
            if let existingIndex = positions[frameId] {
                overwriteVector(at: existingIndex, with: stored)
                if let index {
                    try await index.delete(id: frameId)
                    recordsToInsert.append(VectorRecord(id: frameId, vector: stored))
                }
            } else {
                let newIndex = self.frameIds.count
                self.frameIds.append(frameId)
                positions[frameId] = newIndex
                self.vectors.append(contentsOf: stored)
                recordsToInsert.append(VectorRecord(id: frameId, vector: stored))
            }
        }

        if hadIndex, let index, !recordsToInsert.isEmpty {
            if recordsToInsert.count == 1, let record = recordsToInsert.first {
                try await index.insert(record)
            } else {
                try await index.batchInsert(recordsToInsert)
            }
        } else {
            try await rebuildIndex()
        }

        dirty = true
    }

    package func remove(frameId: UInt64) async throws {
        guard let indexToRemove = positions.removeValue(forKey: frameId) else { return }
        let lastIndex = frameIds.count - 1
        if indexToRemove != lastIndex {
            let movedFrameId = frameIds[lastIndex]
            overwriteVector(at: indexToRemove, withSliceFrom: lastIndex)
            frameIds[indexToRemove] = movedFrameId
            positions[movedFrameId] = indexToRemove
        }
        frameIds.removeLast()
        vectors.removeLast(dimensions)
        if frameIds.isEmpty {
            index = nil
        } else if let index {
            try await index.delete(id: frameId)
        }
        dirty = true
    }

    package func search(vector query: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        try validate(query)
        guard !frameIds.isEmpty else { return [] }
        try await ensureIndex()
        guard let index else { return [] }
        let results = try await index.search(query: preparedVector(query), topK: topK)
        return results.map { (frameId: $0.id, score: $0.score) }
    }

    package func stageForCommit(into wax: Wax) async throws {
        guard dirty else { return }
        let blob = try VectorSerializer.serializeFlatVectors(
            vectors,
            frameIds: frameIds,
            metric: metric,
            dimensions: dimensions
        )
        try await wax.stageVecIndexForNextCommit(
            bytes: blob,
            vectorCount: UInt64(frameIds.count),
            dimension: UInt32(dimensions),
            similarity: metric.toVecSimilarity()
        )
        dirty = false
    }

    private func deserialize(_ data: Data) async throws {
        let decoded = try VectorSerializer.decodeVecSegment(from: data)
        switch decoded {
        case .uSearch:
            throw WaxError.invalidToc(reason: "MetalANNSVectorEngine cannot deserialize usearch payloads")
        case .metal(let info, let decodedVectors, let decodedFrameIds):
            guard info.dimension == UInt32(dimensions) else {
                throw WaxError.invalidToc(reason: "vec dimension mismatch: expected \(dimensions), got \(info.dimension)")
            }
            guard info.similarity == metric.toVecSimilarity() else {
                throw WaxError.invalidToc(
                    reason: "vec similarity mismatch: expected \(metric.toVecSimilarity()), got \(info.similarity)"
                )
            }
            guard decodedVectors.count == Int(info.vectorCount) * dimensions else {
                throw WaxError.invalidToc(reason: "vec vector count mismatch")
            }
            guard decodedFrameIds.count == Int(info.vectorCount) else {
                throw WaxError.invalidToc(reason: "vec frameId count mismatch")
            }
            frameIds = decodedFrameIds
            vectors = decodedVectors
            positions.removeAll(keepingCapacity: true)
            positions.reserveCapacity(decodedFrameIds.count)
            for (index, frameId) in decodedFrameIds.enumerated() {
                positions[frameId] = index
            }
            try await rebuildIndex()
            dirty = false
        }
    }

    private func ensureIndex() async throws {
        if index == nil, !frameIds.isEmpty {
            try await rebuildIndex()
        }
    }

    private func rebuildIndex() async throws {
        guard !frameIds.isEmpty else {
            index = nil
            return
        }
        let builder = VectorIndex<UInt64, VectorIndexState.Unbuilt>(configuration: configuration)
        index = try await builder.build(vectors: matrixVectors(), ids: frameIds)
    }

    private func matrixVectors() -> [[Float]] {
        guard !frameIds.isEmpty else { return [] }
        var rows: [[Float]] = []
        rows.reserveCapacity(frameIds.count)
        for index in frameIds.indices {
            let start = index * dimensions
            rows.append(Array(vectors[start..<(start + dimensions)]))
        }
        return rows
    }

    private func overwriteVector(at index: Int, with vector: [Float]) {
        let start = index * dimensions
        for dim in 0..<dimensions {
            vectors[start + dim] = vector[dim]
        }
    }

    private func overwriteVector(at index: Int, withSliceFrom sourceIndex: Int) {
        guard index != sourceIndex else { return }
        let sourceStart = sourceIndex * dimensions
        let targetStart = index * dimensions
        for dim in 0..<dimensions {
            vectors[targetStart + dim] = vectors[sourceStart + dim]
        }
    }

    private func preparedVector(_ vector: [Float]) -> [Float] {
        guard metric == .cosine, !vector.isEmpty else { return vector }
        let norm = sqrt(vector.reduce(into: Float.zero) { partial, value in
            partial += value * value
        })
        guard norm > 0 else { return vector }
        if abs(norm - 1) < 0.001 { return vector }
        return vector.map { value in value / norm }
    }

    private func validate(_ vector: [Float]) throws {
        try VectorValidation.validate(vector, dimensions: dimensions)
    }
}

private extension VectorMetric {
    func toMetalANNSMetric() -> Metric {
        switch self {
        case .cosine:
            return .cosine
        case .dot:
            return .innerProduct
        case .l2:
            return .l2
        }
    }
}
#endif
