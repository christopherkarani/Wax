import Foundation
import WaxCore

package enum VectorEnginePreference: Sendable, Equatable {
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
