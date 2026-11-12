import Foundation
import WaxCore

/// Preferred vector search backend: automatic selection, GPU-only, or CPU-only.
public enum VectorEnginePreference: Sendable, Equatable {
    case auto
    @available(*, deprecated, renamed: "auto")
    case metalPreferred
    case gpuOnly
    case cpuOnly
}

package protocol VectorSearchEngine: Sendable {
    var dimensions: Int { get }

    func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)]
    func add(frameId: UInt64, vector: [Float]) async throws
    func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws
    func remove(frameId: UInt64) async throws
    func stageForCommit(into wax: Wax) async throws
}

package enum VectorPreparation {
    /// `rows` with each row prepared the way the engines prepare one added vector: cosine
    /// rows scaled to unit length unless already within 0.001 of it. The arithmetic matches
    /// adding the rows one by one, so a store loaded from its runs holds the same floats as
    /// the engine that added them.
    package static func preparedRows(_ rows: [Float], dimensions: Int, metric: VectorMetric) -> [Float] {
        guard metric == .cosine, dimensions > 0, !rows.isEmpty else { return rows }
        // Embedders store unit rows, so usually nothing changes: find the first row that
        // needs dividing before copying the rows (100k x 384: 2 ms, against 21 ms to copy and
        // check every row in order).
        guard let firstRow = firstRowNeedingNormalization(rows, dimensions: dimensions) else {
            return rows
        }
        var prepared = rows
        prepared.withUnsafeMutableBufferPointer { buffer in
            var start = firstRow * dimensions
            while start < buffer.count {
                let row = UnsafeMutableBufferPointer(rebasing: buffer[start..<(start + dimensions)])
                let norm = exactNorm(UnsafeBufferPointer(row))
                if norm > 0, !(abs(norm - 1) < 0.001) {
                    for index in row.indices {
                        row[index] = row[index] / norm
                    }
                }
                start += dimensions
            }
        }
        return prepared
    }

    /// The norm summed in row order, which decides (and scales) every row that is divided.
    private static func exactNorm(_ row: UnsafeBufferPointer<Float>) -> Float {
        sqrt(row.reduce(into: Float.zero) { partial, value in
            partial += value * value
        })
    }

    /// The first row `preparedRows` divides, or `nil`. A SIMD sum of squares (reassociated,
    /// so a few ulps from the exact one) clears rows well inside the 0.001 band; any other row
    /// is decided by the exact norm, so the answer matches checking every row exactly.
    private static func firstRowNeedingNormalization(_ rows: [Float], dimensions: Int) -> Int? {
        rows.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<Float>) -> Int? in
            guard let base = buffer.baseAddress else { return nil }
            let raw = UnsafeRawPointer(base)
            var start = 0
            while start < buffer.count {
                var lanes = SIMD16<Float>()
                var index = start
                let end = start + dimensions
                while index + 16 <= end {
                    let values = raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride, as: SIMD16<Float>.self)
                    lanes += values * values
                    index += 16
                }
                var squaredNorm = lanes.sum()
                while index < end {
                    squaredNorm += buffer[index] * buffer[index]
                    index += 1
                }
                if !(abs(squaredNorm.squareRoot() - 1) < 0.0009) {
                    let norm = exactNorm(UnsafeBufferPointer(rebasing: buffer[start..<end]))
                    if norm > 0, !(abs(norm - 1) < 0.001) {
                        return start / dimensions
                    }
                }
                start = end
            }
            return nil
        }
    }

    package static func validateCommitted(
        _ committed: CommittedVectors,
        dimensions: Int,
        metric: VectorMetric
    ) throws {
        guard committed.dimension == UInt32(dimensions) else {
            throw WaxError.invalidToc(reason: "vec dimension mismatch: expected \(dimensions), got \(committed.dimension)")
        }
        guard committed.similarity == metric.toVecSimilarity() else {
            throw WaxError.invalidToc(
                reason: "vec similarity mismatch: expected \(metric.toVecSimilarity()), got \(committed.similarity)"
            )
        }
        guard committed.vectors.count == committed.frameIds.count * dimensions else {
            throw WaxError.invalidToc(reason: "vec vector count mismatch")
        }
    }
}

package enum VectorValidation {
    package static func validate(_ vector: [Float], dimensions: Int) throws {
        guard vector.count == dimensions else {
            throw WaxError.encodingError(reason: "vector dimension mismatch: expected \(dimensions), got \(vector.count)")
        }
        guard vector.count <= Constants.maxEmbeddingDimensions else {
            throw WaxError.capacityExceeded(
                limit: UInt64(Constants.maxEmbeddingDimensions),
                requested: UInt64(vector.count)
            )
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw WaxError.encodingError(reason: "vector contains non-finite values")
        }
    }
}
