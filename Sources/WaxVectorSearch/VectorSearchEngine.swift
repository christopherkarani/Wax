import Foundation
import WaxCore

public enum VectorEnginePreference: Sendable, Equatable {
    case auto
    case metalPreferred
    case cpuOnly
}

public protocol VectorSearchEngine: Sendable {
    var dimensions: Int { get }

    func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)]
    func add(frameId: UInt64, vector: [Float]) async throws
    func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws
    func remove(frameId: UInt64) async throws
    func stageForCommit(into wax: Wax) async throws
}

