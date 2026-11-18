import Foundation
import Testing
import WaxCore
@testable import WaxTextSearch

private func meta(_ id: UInt64, status: FrameStatus = .active, supersededBy: UInt64? = nil) -> FrameMeta {
    FrameMeta(
        id: id,
        timestamp: 0,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        status: status,
        supersededBy: supersededBy
    )
}

/// Every commit stages the text index, which removes deleted and superseded frames. It used to
/// delete the postings of every inactive frame on every commit, so a store with many updates
/// or deletes paid for all of them on each commit. Each inactive frame is now removed once.
@Test
func inactiveFramesAreRemovedFromTheTextIndexOnce() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "alpha harbor")
    try await engine.index(frameId: 1, text: "beta lantern")
    try await engine.index(frameId: 2, text: "gamma meadow")

    var metas = [meta(0, status: .deleted), meta(1), meta(2)]
    try await engine.removeInactiveFrames(metas)
    #expect(await engine.inactiveFrameRemovalsForTesting == 1)
    #expect(try await engine.count() == 2)

    try await engine.removeInactiveFrames(metas)
    #expect(await engine.inactiveFrameRemovalsForTesting == 1)

    metas[1] = meta(1, supersededBy: 2)
    try await engine.removeInactiveFrames(metas)
    #expect(await engine.inactiveFrameRemovalsForTesting == 2)
    #expect(try await engine.search(matchQuery: "\"lantern\"", topK: 10).isEmpty)
    #expect(try await engine.count() == 1)

    // A frame indexed again after its removal is removed again.
    try await engine.index(frameId: 0, text: "alpha harbor")
    try await engine.removeInactiveFrames(metas)
    #expect(await engine.inactiveFrameRemovalsForTesting == 3)
    #expect(try await engine.search(matchQuery: "\"harbor\"", topK: 10).isEmpty)
    #expect(try await engine.search(matchQuery: "\"meadow\"", topK: 10).map(\.frameId) == [2])
}
