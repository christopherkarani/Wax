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

/// Every commit stages the text index from the full merged list, so it is built without a
/// dictionary over every frame. It must match the per-id merge for deletes and supersedes on
/// committed and pending frames alike.
@Test func frameMetasIncludingPendingMatchesPerIdMergeAcrossMutations() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    for index in 0..<6 {
        _ = try await wax.put(Data("committed \(index)".utf8))
    }
    try await wax.supersede(supersededId: 0, supersedingId: 1)
    try await wax.commit()

    let pendingA = try await wax.put(Data("pending a".utf8))
    let pendingB = try await wax.put(Data("pending b".utf8))
    let pendingC = try await wax.put(Data("pending c".utf8))
    try await wax.delete(frameId: 2)
    try await wax.delete(frameId: pendingB)
    try await wax.supersede(supersededId: 3, supersedingId: pendingA)
    try await wax.supersede(supersededId: pendingA, supersedingId: pendingC)
    try await wax.supersede(supersededId: 4, supersedingId: 5)

    let merged = await wax.frameMetasIncludingPending()
    let allIds = Array(0...pendingC)
    let perId = await wax.frameMetasIncludingPending(frameIds: allIds)
    #expect(merged.map(\.id) == allIds)
    #expect(merged == allIds.compactMap { perId[$0] })
    #expect(merged[2].status == .deleted)
    #expect(merged[Int(pendingB)].status == .deleted)
    #expect(merged[3].supersededBy == pendingA)
    #expect(merged[Int(pendingA)].supersedes == 3)
    #expect(merged[Int(pendingA)].supersededBy == pendingC)
    #expect(merged[4].supersededBy == 5)
    #expect(merged[5].supersedes == 4)
    try await wax.close()
}
