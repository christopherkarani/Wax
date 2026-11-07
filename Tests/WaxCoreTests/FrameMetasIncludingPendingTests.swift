import Foundation
import Testing
@testable import WaxCore

/// Every open hands the text index `frameMetasIncludingPending()`, so with nothing pending it
/// returns the committed frames directly. Pending puts and deletes must still show.
@Test func frameMetasIncludingPendingMatchesCommittedFramesAndAppliesPendingWrites() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try await Wax.create(at: url)
    for index in 0..<4 {
        _ = try await writer.put(Data("committed frame \(index)".utf8))
    }
    try await writer.delete(frameId: 1)
    try await writer.commit()
    try await writer.close()

    let wax = try await Wax.open(at: url)
    let committed = await wax.frameMetas()
    #expect(committed.map(\.id) == [0, 1, 2, 3])
    #expect(await wax.frameMetasIncludingPending() == committed)

    let pendingId = try await wax.put(Data("pending frame".utf8))
    try await wax.delete(frameId: 2)
    let merged = await wax.frameMetasIncludingPending()
    #expect(merged.map(\.id) == [0, 1, 2, 3, pendingId])
    #expect(merged[1].status == .deleted)
    #expect(merged[2].status == .deleted)
    #expect(merged[3] == committed[3])
    try await wax.close()
}
