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
    /// Rows dropped from the last loaded segment because they held non-finite values.
    package private(set) var droppedNonFiniteRowCount = 0

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
        try await load(
            from: wax,
            committed: try await wax.readCommittedVectors(),
            metric: metric,
            dimensions: dimensions
        )
    }

    /// Loads `committed` (what ``Wax/readCommittedVectors()`` returned) plus the store's
    /// pending vector changes.
    package static func load(
        from wax: Wax,
        committed: CommittedVectors?,
        metric: VectorMetric,
        dimensions: Int
    ) async throws -> AccelerateVectorEngine {
        let engine = try AccelerateVectorEngine(metric: metric, dimensions: dimensions)
        if let committed {
            try await engine.loadCommitted(committed)
        }
        let pending = await wax.pendingEmbeddingMutations(since: nil)
        if !pending.embeddings.isEmpty {
            try await engine.addBatch(
                frameIds: pending.embeddings.map(\.frameId),
                vectors: pending.embeddings.map(\.vector)
            )
        }
        for frameId in pending.removedFrameIds {
            try await engine.remove(frameId: frameId)
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

    /// Frame IDs that currently have a vector here.
    package func storedFrameIds() -> Set<UInt64> {
        Set(frameIds)
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
        try validate(query)
        guard !frameIds.isEmpty else { return [] }

        let limit = min(Self.clampTopK(topK), frameIds.count)
        let preparedQuery = preparedVector(query)
        var scores = [Float](repeating: 0, count: frameIds.count)

        #if canImport(Accelerate)
        vectors.withUnsafeBufferPointer { matrixBuffer in
            preparedQuery.withUnsafeBufferPointer { queryBuffer in
                scores.withUnsafeMutableBufferPointer { scoreBuffer in
                    vDSP_mmul(
                        matrixBuffer.baseAddress!,
                        1,
                        queryBuffer.baseAddress!,
                        1,
                        scoreBuffer.baseAddress!,
                        1,
                        vDSP_Length(frameIds.count),
                        1,
                        vDSP_Length(dimensions)
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

        return VectorTopK.select(frameIds: frameIds, scores: scores, limit: limit)
    }

    /// Records the index's dimension and similarity for the commit; the commit writes the
    /// pending embeddings and removals themselves from the WAL.
    package func stageForCommit(into wax: Wax) async throws {
        try await wax.setVectorIndexConfiguration(dimension: UInt32(dimensions), similarity: metric.toVecSimilarity())
        dirty = false
    }

    private func loadCommitted(_ committed: CommittedVectors) throws {
        try VectorPreparation.validateCommitted(committed, dimensions: dimensions, metric: metric)
        frameIds = committed.frameIds
        vectors = VectorPreparation.preparedRows(committed.vectors, dimensions: dimensions, metric: metric)
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(frameIds.count)
        squaredNorms.removeAll(keepingCapacity: true)
        squaredNorms.reserveCapacity(frameIds.count)
        for (index, frameId) in frameIds.enumerated() {
            positions[frameId] = index
            squaredNorms.append(squaredNorm(ofSliceStartingAt: index * dimensions))
        }
        droppedNonFiniteRowCount = committed.droppedNonFiniteRowCount
        dirty = false
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
        // One mutation per row: per-element subscript writes cost a uniqueness check each, and
        // Swift 6.2 debug builds copied the whole store on every one of them.
        vectors.replaceSubrange(start..<(start + dimensions), with: vector)
    }

    private func overwriteVector(at index: Int, withSliceFrom sourceIndex: Int) {
        guard index != sourceIndex else { return }
        let sourceStart = sourceIndex * dimensions
        let targetStart = index * dimensions
        let dimensions = dimensions
        vectors.withUnsafeMutableBufferPointer { rows in
            for dim in 0..<dimensions {
                rows[targetStart + dim] = rows[sourceStart + dim]
            }
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
        try VectorValidation.validate(vector, dimensions: dimensions)
    }

    private static func clampTopK(_ topK: Int) -> Int {
        if topK < 1 { return 1 }
        if topK > maxResults { return maxResults }
        return topK
    }
}
