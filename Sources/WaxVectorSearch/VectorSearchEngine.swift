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
