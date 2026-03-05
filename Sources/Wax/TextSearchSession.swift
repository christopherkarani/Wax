import Foundation
import WaxCore
import WaxTextSearch

package actor WaxTextSearchSession {
    package let wax: Wax
    package let engine: FTS5SearchEngine

    package init(wax: Wax) async throws {
        self.wax = wax
        self.engine = try await FTS5SearchEngine.load(from: wax)
    }

    package func index(frameId: UInt64, text: String) async throws {
        try await engine.index(frameId: frameId, text: text)
    }

    /// Batch index multiple frames in a single operation.
    package func indexBatch(frameIds: [UInt64], texts: [String]) async throws {
        try await engine.indexBatch(frameIds: frameIds, texts: texts)
    }

    package func remove(frameId: UInt64) async throws {
        try await engine.remove(frameId: frameId)
    }

    package func search(query: String, topK: Int) async throws -> [TextSearchResult] {
        try await engine.search(query: query, topK: topK)
    }

    package func stageForCommit(compact: Bool = false) async throws {
        try await engine.stageForCommit(into: wax, compact: compact)
    }

    package func commit(compact: Bool = false) async throws {
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

package extension Wax {
    @available(*, deprecated, message: "Use Wax.openSession(...)")
    func enableTextSearch() async throws -> WaxTextSearchSession {
        try await WaxTextSearchSession(wax: self)
    }
}
