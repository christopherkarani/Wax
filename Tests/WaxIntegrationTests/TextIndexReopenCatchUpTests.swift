import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTextSearch

/// The lex index is staged only by `WaxSession.commit`, but frames reach disk earlier: through
/// the WAL (replayed on open) and through store commits that do not stage the text index.
/// A crash in that window used to leave those frames out of text search for good. The store's
/// owning writer now indexes them on open; brief and read-only opens leave the file alone.
private enum TextCatchUpFixture {
    static let textOnly: WaxSession.Config = {
        var config = WaxSession.Config()
        config.enableVectorSearch = false
        return config
    }()

    static let owner: WaxSession.Config = {
        var config = textOnly
        config.catchUpTextIndexOnOpen = true
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

    /// Opens the owning writer, lets it run catch-up, commits, and returns the committed lex
    /// doc count.
    @discardableResult
    static func reopenCommitAndCountDocs(at url: URL) async throws -> UInt64? {
        let wax = try await Wax.open(at: url)
        let writer = try await wax.openSession(.readWrite(.fail), config: owner)
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

        // Read-only sessions never catch up; the owning writer does.
        #expect(try await TextCatchUpFixture.textHits("bravo", at: url).isEmpty)
        try await TextCatchUpFixture.reopenCommitAndCountDocs(at: url)
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

        // Catch-up is committed by the next owning writer, once, without duplicating rows.
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

        try await TextCatchUpFixture.reopenCommitAndCountDocs(at: url)
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

        try await TextCatchUpFixture.reopenCommitAndCountDocs(at: url)
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

@Test func textIndexCatchUpOnLegacyBlobScansEveryFrameOnce() async throws {
    let legacy = try FTS5SearchEngine.inMemory()
    try await legacy.index(frameId: 0, text: "alpha")
    try await legacy.index(frameId: 2, text: "charlie")
    // A blob written before the coverage watermark existed: it vouches for no frame.
    let engine = try FTS5SearchEngine.deserialize(from: try await legacy.serialize())
    let metas = (0..<5).map { catchUpMeta(UInt64($0), "word\($0)") }

    #expect(try await engine.catchUpUnindexedFrames(metas) == 3)
    #expect(try await engine.catchUpUnindexedFrames(metas) == 0)
    #expect(try await engine.count() == 5)
    // Frame 1 sits below the highest indexed frame and is still caught up.
    #expect(try await engine.search(matchQuery: "word1", topK: 5).map(\.frameId) == [1])
    #expect(try await engine.search(matchQuery: "word4", topK: 5).map(\.frameId) == [4])
}

/// A store whose lex blob predates the watermark and misses a frame below its highest
/// indexed frame: the first owning-writer open indexes it and records the watermark.
@Test func textIndexCatchesUpGapBelowHighestIndexedFrameInOldFormatStore() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var ids: [UInt64] = []
        for word in ["alpha", "bravo", "charlie", "delta"] {
            let id = try await wax.put(
                Data(word.utf8),
                options: FrameMetaSubset(role: .document, searchText: "\(word) harbor")
            )
            ids.append(id)
        }
        let oldBlob = try FTS5SearchEngine.inMemory()
        try await oldBlob.index(frameId: ids[0], text: "alpha harbor")
        try await oldBlob.index(frameId: ids[2], text: "charlie harbor")
        try await wax.stageLexIndexForNextCommit(bytes: try await oldBlob.serialize(), docCount: 2)
        try await wax.commit()
        try await wax.close()
        #expect(Set(try await TextCatchUpFixture.textHits("harbor", at: url)) == [ids[0], ids[2]])

        #expect(try await TextCatchUpFixture.reopenCommitAndCountDocs(at: url) == 4)
        #expect(Set(try await TextCatchUpFixture.textHits("harbor", at: url)) == Set(ids))
        // The watermark is recorded: the next owner open finds nothing to do and writes nothing.
        let before = try await BriefOpenFixture.snapshot(at: url)
        #expect(try await TextCatchUpFixture.reopenCommitAndCountDocs(at: url) == 4)
        #expect(try await BriefOpenFixture.snapshot(at: url) == before)
    }
}

/// Opens that do not own the store must not write to it, even when its text index is behind.
private enum BriefOpenFixture {
    struct Snapshot: Equatable {
        var bytes: Data
        var generation: UInt64
    }

    static func snapshot(at url: URL) async throws -> Snapshot {
        let bytes = try Data(contentsOf: url)
        let wax = try await Wax.open(at: url)
        let generation = await wax.stats().generation
        try await wax.close()
        return Snapshot(bytes: bytes, generation: generation)
    }

    /// Raw puts committed without any text index, as another process or a crash leaves them.
    static func writeRawPutStore(at url: URL) async throws {
        let wax = try await Wax.create(at: url)
        for word in ["alpha", "bravo", "charlie"] {
            _ = try await wax.put(
                Data(word.utf8),
                options: FrameMetaSubset(role: .document, searchText: "\(word) harbor")
            )
        }
        try await wax.commit()
        try await wax.close()
    }

    static func openAndClose(at url: URL, config: OrchestratorConfig) async throws {
        let memory = try await MemoryOrchestrator(at: url, config: config)
        _ = try await memory.searchExecution(query: "harbor", mode: .textOnly, topK: 3)
        try await memory.close()
    }
}

@Test func briefOpensOfARawPutStoreLeaveItUntouched() async throws {
    try await TempFiles.withTempFile { url in
        try await BriefOpenFixture.writeRawPutStore(at: url)
        let before = try await BriefOpenFixture.snapshot(at: url)

        #expect(!OrchestratorConfig.default.catchUpTextIndexOnOpen)
        try await BriefOpenFixture.openAndClose(at: url, config: .default)
        try await BriefOpenFixture.openAndClose(
            at: url,
            config: BrokerCorpusStoreBuilder.memoryConfig(structuredMemoryEnabled: false)
        )
        try await BriefOpenFixture.openAndClose(at: url, config: AgentBrokerService.migrationVerificationConfig())
        _ = try await AgentBrokerService.frameCount(at: url)
        _ = try await AgentBrokerService.vectorIndexPresent(at: url)
        let endedSessions = DiskEndedSessionStore(
            sessionRootURL: url.deletingLastPathComponent(),
            noEmbedder: true,
            enableAccessStatsScoring: false,
            readiness: EmbeddingReadiness()
        )
        _ = try await endedSessions.withMemory(at: url) { memory in
            try await memory.searchExecution(query: "harbor", mode: .textOnly, topK: 3).hits.count
        }
        _ = try await TextCatchUpFixture.textHits("harbor", at: url)

        #expect(try await BriefOpenFixture.snapshot(at: url) == before)
    }
}

@Test func owningWriterOpenIndexesARawPutStore() async throws {
    try await TempFiles.withTempFile { url in
        try await BriefOpenFixture.writeRawPutStore(at: url)
        let before = try await BriefOpenFixture.snapshot(at: url)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.catchUpTextIndexOnOpen = true
        let memory = try await MemoryOrchestrator(at: url, config: config)
        let hits = try await memory.searchExecution(query: "harbor", mode: .textOnly, topK: 5).hits
        #expect(hits.count == 3)
        try await memory.close()

        #expect(try await BriefOpenFixture.snapshot(at: url).generation > before.generation)
        #expect(try await TextCatchUpFixture.textHits("harbor", at: url).count == 3)
    }
}
