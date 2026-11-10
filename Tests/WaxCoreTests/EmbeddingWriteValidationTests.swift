import Foundation
import Testing
@testable import WaxCore

/// An embedding the vector engines would reject must never reach the WAL: WAL replay feeds it
/// to the engine on every open, so one bad vector would make the store unopenable.

@Test func putEmbeddingRejectsNonFiniteVectorAndLeavesNothingPending() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    for vector: [Float] in [[.nan, 0], [0, .infinity], [-.infinity, 1]] {
        await #expect(throws: WaxError.self) {
            try await wax.putEmbedding(frameId: 0, vector: vector)
        }
    }
    #expect(await wax.pendingEmbeddingMutations().isEmpty)
    try await wax.close()
}

@Test func putEmbeddingBatchRejectsNonFiniteVectorAndLeavesNothingPending() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    await #expect(throws: WaxError.self) {
        try await wax.putEmbeddingBatch(frameIds: [0, 1], vectors: [[0.1, 0.2], [.nan, 0.2]])
    }
    #expect(await wax.pendingEmbeddingMutations().isEmpty)
    try await wax.close()
}

@Test func putEmbeddingRejectsDimensionThatDiffersFromPendingEmbeddings() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.putEmbedding(frameId: 0, vector: [0.1, 0.2])
    await #expect(throws: WaxError.self) {
        try await wax.putEmbedding(frameId: 1, vector: [0.1, 0.2, 0.3])
    }
    await #expect(throws: WaxError.self) {
        try await wax.putEmbeddingBatch(frameIds: [1], vectors: [[0.1, 0.2, 0.3]])
    }
    #expect(await wax.pendingEmbeddingMutations().map(\.frameId) == [0])
    // No vector index is staged for the valid pending embedding, so close cannot commit it.
    try? await wax.close()
}
