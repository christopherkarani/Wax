import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTextSearch

/// The lex index is staged only by `WaxSession.commit`, but frames reach disk earlier: through
/// the WAL (replayed on open) and through store commits that do not stage the text index.
/// A crash in that window used to leave those frames out of text search for good.
private enum TextCatchUpFixture {
    static let textOnly: WaxSession.Config = {
        var config = WaxSession.Config()
        config.enableVectorSearch = false
        return config
    }()

    static func putIndexed(_ text: String, in session: WaxSession, role: FrameRole = .document) async throws -> UInt64 {
        let frameId = try await session.put(
            Data(text.utf8),
            options: FrameMetaSubset(role: role, searchText: text)
        )
        try await session.indexText(frameId: frameId, text: text)
        return frameId
    }

    static func textHits(_ query: String, at url: URL) async throws -> [UInt64] {
        let wax = try await Wax.open(at: url)
        let reader = try await wax.openSession(.readOnly, config: textOnly)
        let hits = try await reader.searchText(query: query, topK: 10).map(\.frameId)
        await reader.close()
        try await wax.close()
        return hits
    }

    /// Opens a writer, lets it run catch-up, commits, and returns the committed lex doc count.
    static func reopenCommitAndCountDocs(at url: URL) async throws -> UInt64? {
        let wax = try await Wax.open(at: url)
        let writer = try await wax.openSession(.readWrite(.fail), config: textOnly)
        try await writer.commit()
        await writer.close()
        let docCount = await wax.committedLexIndexManifest()?.docCount
        try await wax.close()
        return docCount
    }

    /// A byte copy of a live store: what a SIGKILL leaves on disk, WAL included.
    static func crashImage(of url: URL) throws -> URL {
        let image = url.deletingLastPathComponent()
            .appendingPathComponent("crash-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        try FileManager.default.copyItem(at: url, to: image)
        return image
    }
}

@Test func textIndexCatchesUpFramesCommittedWithoutLexIndex() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.fail), config: TextCatchUpFixture.textOnly)
        let alpha = try await TextCatchUpFixture.putIndexed("alpha orchard", in: session)
        try await session.commit()

        let bravo = try await TextCatchUpFixture.putIndexed("bravo harbor", in: session)
        // Frames become durable through a store commit that does not stage the lex index
        // (WAL auto-commit, or a close without a session commit); then the process dies.
        try await wax.commit()
        await session.close()
        try await wax.close()

        #expect(try await TextCatchUpFixture.textHits("alpha", at: url) == [alpha])
        #expect(try await TextCatchUpFixture.textHits("bravo", at: url) == [bravo])
    }
}

@Test func textIndexCatchesUpWALReplayedFramesAfterCrash() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.fail), config: TextCatchUpFixture.textOnly)
        let alpha = try await TextCatchUpFixture.putIndexed("alpha orchard", in: session)
        try await session.commit()
        let bravo = try await TextCatchUpFixture.putIndexed("bravo harbor", in: session)
        let charlie = try await TextCatchUpFixture.putIndexed("charlie harbor", in: session)

        // Only the WAL holds bravo and charlie when the process is killed.
        let image = try TextCatchUpFixture.crashImage(of: url)
        defer { try? FileManager.default.removeItem(at: image) }
        await session.close()
        try await wax.close()

        #expect(Set(try await TextCatchUpFixture.textHits("harbor", at: image)) == [bravo, charlie])

        // Catch-up is committed by the next writer, once, without duplicating rows.
        #expect(try await TextCatchUpFixture.reopenCommitAndCountDocs(at: image) == 3)
        #expect(try await TextCatchUpFixture.reopenCommitAndCountDocs(at: image) == 3)
        #expect(try await TextCatchUpFixture.textHits("alpha", at: image) == [alpha])
        #expect(Set(try await TextCatchUpFixture.textHits("harbor", at: image)) == [bravo, charlie])
    }
}

@Test func textIndexCatchUpSkipsFramesThatAreNotTextIndexed() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.fail), config: TextCatchUpFixture.textOnly)
        _ = try await TextCatchUpFixture.putIndexed("alpha orchard", in: session)
        try await session.commit()

        // System frames (enrichment keywords) carry searchText but are never text-indexed.
        _ = try await session.put(
            Data("system".utf8),
            options: FrameMetaSubset(role: .system, searchText: "sierra keyword")
        )
        let deleted = try await session.put(
            Data("deleted".utf8),
            options: FrameMetaSubset(role: .document, searchText: "delta removed")
        )
        try await wax.delete(frameId: deleted)
        let old = try await session.put(
            Data("old".utf8),
            options: FrameMetaSubset(role: .chunk, searchText: "echo stale")
        )
        let new = try await session.put(
            Data("new".utf8),
            options: FrameMetaSubset(role: .chunk, searchText: "echo fresh")
        )
        try await wax.supersede(supersededId: old, supersedingId: new)
        try await wax.commit()
        await session.close()
        try await wax.close()

        #expect(try await TextCatchUpFixture.textHits("sierra", at: url).isEmpty)
        #expect(try await TextCatchUpFixture.textHits("delta", at: url).isEmpty)
        #expect(try await TextCatchUpFixture.textHits("echo", at: url) == [new])
    }
}

@Test func textIndexCatchesUpFrameWhoseIndexTextMissedTheCommit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.fail), config: TextCatchUpFixture.textOnly)
        let alpha = try await TextCatchUpFixture.putIndexed("alpha orchard", in: session)
        // A commit lands between this put and its `indexText` call; then the process dies.
        let bravo = try await session.put(
            Data("bravo".utf8),
            options: FrameMetaSubset(role: .document, searchText: "bravo harbor")
        )
        let charlie = try await TextCatchUpFixture.putIndexed("charlie harbor", in: session)
        try await session.commit()
        await session.close()
        try await wax.close()

        #expect(try await TextCatchUpFixture.textHits("alpha", at: url) == [alpha])
        #expect(Set(try await TextCatchUpFixture.textHits("harbor", at: url)) == [bravo, charlie])
    }
}

private func catchUpMeta(_ id: UInt64, _ text: String) -> FrameMeta {
    FrameMeta(
        id: id,
        timestamp: 0,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(),
        canonicalEncoding: .plain,
        searchText: text
    )
}

@Test func textIndexCatchUpOnLegacyBlobOnlyIndexesAboveHighestIndexedFrame() async throws {
    let legacy = try FTS5SearchEngine.inMemory()
    try await legacy.index(frameId: 0, text: "alpha")
    try await legacy.index(frameId: 2, text: "charlie")
    // A blob written before the coverage watermark existed.
    let engine = try FTS5SearchEngine.deserialize(from: try await legacy.serialize())
    let metas = (0..<5).map { catchUpMeta(UInt64($0), "word\($0)") }

    #expect(try await engine.catchUpUnindexedFrames(metas) == 2)
    #expect(try await engine.catchUpUnindexedFrames(metas) == 0)
    #expect(try await engine.count() == 4)
    // Frame 1 sits below the highest indexed frame: its absence predates the watermark.
    #expect(try await engine.search(matchQuery: "word1", topK: 5).isEmpty)
    #expect(try await engine.search(matchQuery: "word4", topK: 5).map(\.frameId) == [4])
}
