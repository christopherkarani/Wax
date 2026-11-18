import Foundation
import Testing
@testable import WaxCore

// A commit that fails after applying its pending mutations must leave the handle's TOC and
// encoded frame cache exactly as they were, then commit the same mutations on retry.

private func payload(_ index: Int) -> Data {
    Data("rollback frame \(index) ".utf8) + Data(repeating: UInt8(truncatingIfNeeded: index), count: 64)
}

/// A store with `count` committed frames over two commits, so the second commit appended to
/// the encoded frame cache instead of building it.
private func storeWithCommittedFrames(_ url: URL, count: Int) async throws -> Wax {
    let wax = try await Wax.create(at: url)
    for index in 0..<(count - 1) {
        _ = try await wax.put(payload(index))
    }
    try await wax.commit()
    _ = try await wax.put(payload(count - 1))
    try await wax.commit()
    return wax
}

/// Fails the commit's first file write (the TOC write: no index is staged and replay
/// snapshots are off), after the commit applied its mutations and encoded its frames.
private func failNextCommit(_ wax: Wax) async {
    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: [.eio]))
    await #expect(throws: (any Error).self) { try await wax.commit() }
    await wax.installFileFaultPlanForTesting(nil)
}

@Test func failedAppendOnlyCommitRestoresTocAndFrameCache() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await storeWithCommittedFrames(url, count: 4)
    let tocBefore = await wax.toc
    let cacheBefore = try #require(await wax.encodedCommittedFramePayloadCache)

    _ = try await wax.put(payload(4))
    _ = try await wax.put(payload(5))
    await failNextCommit(wax)

    #expect(await wax.toc == tocBefore)
    #expect(await wax.encodedCommittedFramePayloadCache == cacheBefore)
    #expect(await wax.stats().pendingFrames == 2)

    try await wax.commit()
    #expect(await wax.stats().frameCount == 6)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    try await reopened.verify(deep: true)
    for index in 0..<6 {
        #expect(try await reopened.frameContent(frameId: UInt64(index)) == payload(index))
    }
    try await reopened.close()
}

@Test func failedCommitRestoresCommittedFramesItModified() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await storeWithCommittedFrames(url, count: 4)
    let tocBefore = await wax.toc
    let cacheBefore = try #require(await wax.encodedCommittedFramePayloadCache)

    _ = try await wax.put(payload(4))
    try await wax.delete(frameId: 0)
    try await wax.supersede(supersededId: 1, supersedingId: 4)
    try await wax.supersede(supersededId: 2, supersedingId: 3)
    await failNextCommit(wax)

    #expect(await wax.toc == tocBefore)
    #expect(await wax.encodedCommittedFramePayloadCache == cacheBefore)

    // A second failure after the first restore must restore the same state again.
    await failNextCommit(wax)
    #expect(await wax.toc == tocBefore)
    #expect(await wax.encodedCommittedFramePayloadCache == cacheBefore)

    try await wax.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    try await reopened.verify(deep: true)
    #expect(await reopened.stats().frameCount == 5)
    #expect(try await reopened.frameMeta(frameId: 0).status == .deleted)
    #expect(try await reopened.frameMeta(frameId: 1).supersededBy == 4)
    #expect(try await reopened.frameMeta(frameId: 4).supersedes == 1)
    #expect(try await reopened.frameMeta(frameId: 2).supersededBy == 3)
    #expect(try await reopened.frameMeta(frameId: 3).supersedes == 2)
    #expect(try await reopened.frameMeta(frameId: 3).status == .active)
    try await reopened.close()
}

@Test func commitAfterARestoredFailureEncodesTheSameTocAsAFreshEncode() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await storeWithCommittedFrames(url, count: 3)

    _ = try await wax.put(payload(3))
    await failNextCommit(wax)
    try await wax.delete(frameId: 1)
    _ = try await wax.put(payload(4))
    try await wax.commit()
    _ = try await wax.put(payload(5))
    try await wax.commit()

    // The TOC written from the cache must match an encode of the in-memory frames.
    let toc = await wax.toc
    let fromCache = try toc.encode(cachedFramesPayload: try #require(await wax.encodedCommittedFramePayloadCache))
    #expect(fromCache == (try toc.encode()))
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    try await reopened.verify(deep: true)
    #expect(await reopened.toc.frames == toc.frames)
    try await reopened.close()
}
