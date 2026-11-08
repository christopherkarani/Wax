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
        var prepared = rows
        prepared.withUnsafeMutableBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                let row = UnsafeMutableBufferPointer(rebasing: buffer[start..<(start + dimensions)])
                let norm = sqrt(row.reduce(into: Float.zero) { partial, value in
                    partial += value * value
                })
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
