import Foundation
import WaxCore
#if canImport(Accelerate)
import Accelerate
#endif

package actor AccelerateVectorEngine: VectorSearchEngine {
    private static let maxResults = 10_000

    private let metric: VectorMetric
    package let dimensions: Int

    private var frameIds: [UInt64] = []
    private var positions: [UInt64: Int] = [:]
    private var vectors: [Float] = []
    private var squaredNorms: [Float] = []
    private var dirty = false

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
    }

    package static func load(from wax: Wax, metric: VectorMetric, dimensions: Int) async throws -> AccelerateVectorEngine {
        let engine = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
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
        let storedVector = preparedVector(vector)
        let storedNorm = squaredNorm(of: storedVector)

        if let index = positions[frameId] {
            overwriteVector(at: index, with: storedVector)
            squaredNorms[index] = storedNorm
        } else {
            let index = frameIds.count
            frameIds.append(frameId)
            positions[frameId] = index
            vectors.append(contentsOf: storedVector)
            squaredNorms.append(storedNorm)
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
        for (frameId, vector) in zip(frameIds, newVectors) {
            let storedVector = preparedVector(vector)
            let storedNorm = squaredNorm(of: storedVector)
            if let index = positions[frameId] {
                overwriteVector(at: index, with: storedVector)
                squaredNorms[index] = storedNorm
            } else {
                let index = self.frameIds.count
                self.frameIds.append(frameId)
                positions[frameId] = index
                self.vectors.append(contentsOf: storedVector)
                squaredNorms.append(storedNorm)
            }
        }
        dirty = true
    }

    package func remove(frameId: UInt64) async throws {
        guard let index = positions.removeValue(forKey: frameId) else { return }
        let lastIndex = frameIds.count - 1
        if index != lastIndex {
            let movedFrameId = frameIds[lastIndex]
            overwriteVector(at: index, withSliceFrom: lastIndex)
            frameIds[index] = movedFrameId
            squaredNorms[index] = squaredNorms[lastIndex]
            positions[movedFrameId] = index
        }
        frameIds.removeLast()
        squaredNorms.removeLast()
        vectors.removeLast(dimensions)
        dirty = true
    }

    package func search(vector query: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        guard !frameIds.isEmpty else { return [] }
        try validate(query)

        let limit = min(Self.clampTopK(topK), frameIds.count)
        let preparedQuery = preparedVector(query)
        var scores = [Float](repeating: 0, count: frameIds.count)

        #if canImport(Accelerate)
        vectors.withUnsafeBufferPointer { matrixBuffer in
            preparedQuery.withUnsafeBufferPointer { queryBuffer in
                scores.withUnsafeMutableBufferPointer { scoreBuffer in
                    cblas_sgemv(
                        CblasRowMajor,
                        CblasNoTrans,
                        Int32(frameIds.count),
                        Int32(dimensions),
                        1,
                        matrixBuffer.baseAddress,
                        Int32(dimensions),
                        queryBuffer.baseAddress,
                        1,
                        0,
                        scoreBuffer.baseAddress,
                        1
                    )
                }
            }
        }
        #else
        for index in frameIds.indices {
            let start = index * dimensions
            var dot: Float = 0
            for dim in 0..<dimensions {
                dot += vectors[start + dim] * preparedQuery[dim]
            }
            scores[index] = dot
        }
        #endif

        if metric == .l2 {
            let queryNorm = squaredNorm(of: preparedQuery)
            for index in scores.indices {
                scores[index] = -(squaredNorms[index] + queryNorm - (2 * scores[index]))
            }
        }

        var results: [(frameId: UInt64, score: Float)] = []
        results.reserveCapacity(frameIds.count)
        for index in frameIds.indices {
            results.append((frameIds[index], scores[index]))
        }
        results.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.frameId < rhs.frameId }
            return lhs.score > rhs.score
        }
        if results.count > limit {
            results.removeLast(results.count - limit)
        }
        return results
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
            throw WaxError.invalidToc(reason: "AccelerateVectorEngine cannot deserialize usearch payloads")
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
            squaredNorms.removeAll(keepingCapacity: true)
            squaredNorms.reserveCapacity(decodedFrameIds.count)
            for (index, frameId) in decodedFrameIds.enumerated() {
                positions[frameId] = index
                let start = index * dimensions
                squaredNorms.append(squaredNorm(ofSliceStartingAt: start))
            }
            dirty = false
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

    private func squaredNorm(of vector: [Float]) -> Float {
        var total: Float = 0
        for value in vector {
            total += value * value
        }
        return total
    }

    private func squaredNorm(ofSliceStartingAt start: Int) -> Float {
        var total: Float = 0
        for dim in 0..<dimensions {
            let value = vectors[start + dim]
            total += value * value
        }
        return total
    }

    private func validate(_ vector: [Float]) throws {
        guard vector.count == dimensions else {
            throw WaxError.encodingError(reason: "vector dimension mismatch: expected \(dimensions), got \(vector.count)")
        }
        guard vector.count <= Constants.maxEmbeddingDimensions else {
            throw WaxError.capacityExceeded(
                limit: UInt64(Constants.maxEmbeddingDimensions),
                requested: UInt64(vector.count)
            )
        }
    }

    private static func clampTopK(_ topK: Int) -> Int {
        if topK < 1 { return 1 }
        if topK > maxResults { return maxResults }
        return topK
    }
}
