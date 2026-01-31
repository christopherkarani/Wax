import Foundation
import WaxCore
import WaxTextSearch

public actor WaxTextSearchSession {
    public let wax: Wax
    public let engine: FTS5SearchEngine

    public init(wax: Wax) async throws {
        self.wax = wax
        self.engine = try await FTS5SearchEngine.load(from: wax)
    }

    public func index(frameId: UInt64, text: String) async throws {
        try await engine.index(frameId: frameId, text: text)
    }

    /// Batch index multiple frames in a single operation.
    public func indexBatch(frameIds: [UInt64], texts: [String]) async throws {
        try await engine.indexBatch(frameIds: frameIds, texts: texts)
    }

    public func remove(frameId: UInt64) async throws {
        try await engine.remove(frameId: frameId)
    }

    public func search(query: String, topK: Int) async throws -> [TextSearchResult] {
        try await engine.search(query: query, topK: topK)
    }

    public func stageForCommit(compact: Bool = false) async throws {
        try await engine.stageForCommit(into: wax, compact: compact)
    }

    public func commit(compact: Bool = false) async throws {
        try await stageForCommit(compact: compact)
        do {
            try await wax.commit()
        } catch let error as WaxError {
            if case .io(let message) = error,
               message == "vector index must be staged before committing embeddings" {
                // Defer commit until the vector index is staged.
                return
            }
            throw error
        }
    }
}

public extension Wax {
    @available(*, deprecated, message: "Use Wax.openSession(...)")
    func enableTextSearch() async throws -> WaxTextSearchSession {
        try await WaxTextSearchSession(wax: self)
    }
}
