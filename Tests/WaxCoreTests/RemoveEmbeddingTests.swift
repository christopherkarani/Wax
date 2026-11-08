import Foundation
import Testing
@testable import WaxCore

@Test func removeEmbeddingRoundtripsThroughTheWALCodec() throws {
    let encoded = try WALEntryCodec.encode(.removeEmbedding(RemoveEmbedding(frameId: 42)))
    #expect(encoded == Data([0x05, 42, 0, 0, 0, 0, 0, 0, 0]))
    #expect(try WALEntryCodec.decode(encoded, offset: 0) == .removeEmbedding(RemoveEmbedding(frameId: 42)))
}

@Test func pendingEmbeddingSnapshotReportsEachFramesLastVectorChange() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        for index in 0..<4 {
            _ = try await wax.put(Data("frame \(index)".utf8))
        }
        try await wax.putEmbedding(frameId: 0, vector: [1, 0])
        try await wax.putEmbedding(frameId: 1, vector: [0, 1])
        try await wax.removeEmbedding(frameId: 1)
        try await wax.removeEmbedding(frameId: 2)
        try await wax.putEmbedding(frameId: 2, vector: [1, 1])
        try await wax.removeEmbedding(frameId: 3)

        let snapshot = await wax.pendingEmbeddingMutations(since: nil)
        #expect(snapshot.embeddings.map(\.frameId) == [0, 2])
        #expect(snapshot.removedFrameIds == [1, 3])
        let latest = try #require(snapshot.latestSequence)

        // A window after the watermark holds only the changes since.
        try await wax.removeEmbedding(frameId: 0)
        let delta = await wax.pendingEmbeddingMutations(since: latest)
        #expect(delta.embeddings.isEmpty)
        #expect(delta.removedFrameIds == [0])
        #expect(try #require(delta.latestSequence) > latest)
        try await wax.setVectorIndexConfiguration(dimension: 2, similarity: .cosine)
        try await wax.close()
    }
}

@Test func pendingRemoveEmbeddingSurvivesReopenThroughWALReplay() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("frame".utf8))
        try await wax.commit()
        try await wax.putEmbedding(frameId: 0, vector: [1, 0])
        try await wax.removeEmbedding(frameId: 0)
        // A copy taken before `close()` commits: the removal lives only in the WAL.
        let copy = TempFiles.uniqueURL()
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: url, to: copy)
        try await wax.setVectorIndexConfiguration(dimension: 2, similarity: .cosine)
        try await wax.close()

        let reopened = try await Wax.open(at: copy)
        let snapshot = await reopened.pendingEmbeddingMutations(since: nil)
        #expect(snapshot.removedFrameIds == [0])
        #expect(snapshot.embeddings.isEmpty)
        #expect(snapshot.latestSequence != nil)
        try await reopened.close()
    }
}

@Test func removeEmbeddingRejectsAnUnknownFrame() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        await #expect(throws: WaxError.self) {
            try await wax.removeEmbedding(frameId: 0)
        }
        try await wax.close()
    }
}
