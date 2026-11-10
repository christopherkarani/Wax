import Foundation
import Testing
@testable import WaxCore

/// A commit writes its payloads, TOC and footer before its first fsync. After power loss the
/// header can still name the previous footer while the newer footer's pages reached disk and
/// some of its payload pages did not.
private struct UnsyncedCommitFixture {
    /// The file as power loss can leave it: the header pages from before the second commit.
    var crashed: Data
    /// Payload range of each frame the second commit added, by frame id.
    var payloadRanges: [UInt64: Range<Int>]
    /// The lex index segment the second commit wrote, when it staged one.
    var lexRange: Range<Int>?
}

private let secondCommitContents = [Data("second-1".utf8), Data("second-2".utf8), Data("second-3".utf8)]

private func makeUnsyncedCommitFixture(at url: URL, stagesLexIndex: Bool = false) async throws -> UnsyncedCommitFixture {
    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("committed-0".utf8))
    try await wax.commit()

    var ids: [UInt64] = []
    for content in secondCommitContents {
        ids.append(try await wax.put(content))
    }
    let headerRegion = Int(Constants.headerRegionSize)
    let headersBeforeCommit = try Data(contentsOf: url).prefix(headerRegion)
    let metas = await wax.frameMetasIncludingPending(frameIds: ids)
    if stagesLexIndex {
        try await wax.stageLexIndexForNextCommit(bytes: Data(repeating: 0x4C, count: 4096), docCount: 3)
    }
    try await wax.commit()
    let lexRange = await wax.committedLexIndexManifest().map { manifest in
        Int(manifest.bytesOffset)..<Int(manifest.bytesOffset + manifest.bytesLength)
    }
    try await wax.close()

    var crashed = try Data(contentsOf: url)
    crashed.replaceSubrange(0..<headerRegion, with: headersBeforeCommit)
    var payloadRanges: [UInt64: Range<Int>] = [:]
    for id in ids {
        let meta = try #require(metas[id])
        let start = Int(meta.payloadOffset)
        payloadRanges[id] = start..<start + Int(meta.payloadLength)
    }
    return UnsyncedCommitFixture(crashed: crashed, payloadRanges: payloadRanges, lexRange: lexRange)
}

private func withCrashCopy(_ bytes: Data, _ body: (URL) async throws -> Void) async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try bytes.write(to: url)
    try await body(url)
}

/// Frame 2's payload never reached disk. Open must not count the second commit's frames as
/// committed; it falls back to the header's footer and pending replay keeps the intact frames
/// up to the first damaged one (frame 1), as for any torn pending tail.
@Test func openRejectsANewerFooterWhosePayloadNeverReachedDisk() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    var fixture = try await makeUnsyncedCommitFixture(at: url)
    let lost = try #require(fixture.payloadRanges[2])
    fixture.crashed.replaceSubrange(lost, with: Data(count: lost.count))

    try await withCrashCopy(fixture.crashed) { crashURL in
        do {
            let recovered = try await Wax.open(at: crashURL)
            #expect(await recovered.frameMetas().map(\.id) == [0])
            #expect(await recovered.frameMetasIncludingPending().map(\.id) == [0, 1])
            #expect(try await recovered.frameContentIncludingPending(frameId: 1) == secondCommitContents[0])
            #expect(await recovered.walStats().replayTruncationCount == 1)
            try await recovered.commit()
            try await recovered.close()
        }

        let verified = try await Wax.open(at: crashURL)
        #expect(await verified.frameMetas().map(\.id) == [0, 1])
        #expect(try await verified.frameContent(frameId: 0) == Data("committed-0".utf8))
        #expect(try await verified.frameContent(frameId: 1) == secondCommitContents[0])
        try await verified.verify(deep: true)
        try await verified.close()
    }
}

/// The same crash with every payload on disk: open still adopts the newer footer.
@Test func openAdoptsANewerFooterWhosePayloadsAreIntact() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let fixture = try await makeUnsyncedCommitFixture(at: url)

    try await withCrashCopy(fixture.crashed) { crashURL in
        let recovered = try await Wax.open(at: crashURL)
        #expect(await recovered.frameMetas().map(\.id) == [0, 1, 2, 3])
        #expect(await recovered.stats().pendingFrames == 0)
        #expect(await recovered.stats().generation == 2)
        for (index, content) in secondCommitContents.enumerated() {
            #expect(try await recovered.frameContent(frameId: UInt64(index + 1)) == content)
        }
        #expect(await recovered.walStats().replayTruncationCount == 0)
        try await recovered.close()
    }
}

/// An index segment the newer footer adds is checked too: with its pages lost, open keeps the
/// header's footer, and every frame (all intact) comes back as pending.
@Test func openRejectsANewerFooterWhoseIndexSegmentNeverReachedDisk() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    var fixture = try await makeUnsyncedCommitFixture(at: url, stagesLexIndex: true)
    let lost = try #require(fixture.lexRange)
    fixture.crashed.replaceSubrange(lost, with: Data(count: lost.count))

    try await withCrashCopy(fixture.crashed) { crashURL in
        let recovered = try await Wax.open(at: crashURL)
        #expect(await recovered.frameMetas().map(\.id) == [0])
        #expect(await recovered.frameMetasIncludingPending().map(\.id) == [0, 1, 2, 3])
        #expect(await recovered.committedLexIndexManifest() == nil)
        #expect(await recovered.walStats().replayTruncationCount == 0)
        try await recovered.commit()
        try await recovered.verify(deep: true)
        try await recovered.close()
    }
}
