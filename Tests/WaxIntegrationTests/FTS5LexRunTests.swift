import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTextSearch

/// Commits stage only the pages of the FTS5 database that changed (lex runs, see
/// `Wax+LexRuns.swift`). The image a reopen rebuilds from the runs must answer every query the
/// writer's database answered.
private enum LexRunFixture {
    static let textOnly: WaxSession.Config = {
        var config = WaxSession.Config()
        config.enableVectorSearch = false
        return config
    }()

    static let colors = ["amber", "cobalt", "crimson", "jade", "ochre", "violet", "silver"]

    static func text(_ index: Int) -> String {
        "passage \(index) mentions \(colors[index % colors.count]) lantern number\(index)"
    }

    /// Frames below `count` whose text mentions amber.
    static func amberFrames(below count: Int) -> [UInt64] {
        (0..<count).filter { (index: Int) -> Bool in index % colors.count == 0 }.map { (index: Int) -> UInt64 in UInt64(index) }
    }

    static let queries: [String] = ["amber", "cobalt lantern", "jade", "number3", "number45", "passage", "violet OR silver"]

    static func put(_ range: Range<Int>, in session: WaxSession) async throws {
        for index in range {
            let frameId = try await session.put(
                Data(text(index).utf8),
                options: FrameMetaSubset(searchText: text(index))
            )
            try await session.indexText(frameId: frameId, text: text(index))
        }
    }

    static func hits(_ session: WaxSession) async throws -> [String: [UInt64]] {
        var hits: [String: [UInt64]] = [:]
        for query in queries {
            hits[query] = try await session.searchText(query: query, topK: 100).map(\.frameId).sorted()
        }
        return hits
    }

    static func reopenedHits(at url: URL) async throws -> [String: [UInt64]] {
        let wax = try await Wax.open(at: url)
        let reader = try await wax.openSession(.readOnly, config: textOnly)
        let hits = try await hits(reader)
        await reader.close()
        try await wax.close()
        return hits
    }
}

@Test func sessionCommitsWriteLexDeltasThatReopenToTheSameIndex() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.fail), config: LexRunFixture.textOnly)
        try await LexRunFixture.put(0..<400, in: session)
        try await session.commit()
        let base = try #require(await wax.committedLexIndexManifest())
        #expect(base.runs.count == 1)

        try await LexRunFixture.put(400..<410, in: session)
        try await session.removeText(frameId: 3)
        try await session.commit()
        let manifest = try #require(await wax.committedLexIndexManifest())
        #expect(manifest.runs.count == 2, "the second commit writes a delta")
        #expect(manifest.runs[1].bytesLength * 4 < manifest.imageLength)
        #expect(manifest.docCount == 409)
        let written = try await LexRunFixture.hits(session)
        #expect(written["number3"] == [], "the removed frame is gone")
        #expect(written["number45"] == [45])
        await session.close()
        try await wax.verify(deep: true)
        try await wax.close()

        #expect(try await LexRunFixture.reopenedHits(at: url) == written)
    }
}

@Test func anInMemoryTextEngineStagesItsImageWithoutCopyingIt() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let engine = try FTS5SearchEngine.inMemory()
        try await engine.index(frameId: 0, text: "first lantern")
        try await engine.stageForCommit(into: wax)
        #expect(await engine.lastStagedImageWasBorrowedForTesting() == true)
        try await wax.commit()
        #expect(try await wax.readCommittedLexIndexBytes() == (try await engine.serialize()))

        // A reopened engine runs on a file and stages a copy.
        let bytes = try #require(try await wax.readCommittedLexIndexBytes())
        let reopened = try FTS5SearchEngine.deserialize(from: bytes)
        try await reopened.index(frameId: 1, text: "second lantern")
        try await reopened.stageForCommit(into: wax)
        #expect(await reopened.lastStagedImageWasBorrowedForTesting() == false)
        try await wax.commit()
        #expect(try #require(await wax.committedLexIndexManifest()).runs.count == 2)
        let committed = try #require(try await wax.readCommittedLexIndexBytes())
        let fresh = try FTS5SearchEngine.deserialize(from: committed)
        #expect(try await fresh.search(matchQuery: "lantern", topK: 10).map(\.frameId).sorted() == [0, 1])
        try await wax.close()
    }
}

@Test func aV2StoreWithALexBlobOpensAdoptsItAsTheBaseAndAddsDeltas() async throws {
    let url = try await copyLexMigrationFixture(named: "migration-v2-lex-blob")
    defer { try? FileManager.default.removeItem(at: url) }

    // Fixture (written by the build before lex runs): frames 0..<50 indexed with
    // `LexRunFixture.text`, committed in two session commits, frame 3's text removed.
    let wax = try await Wax.open(at: url)
    let adopted = try #require(await wax.committedLexIndexManifest())
    #expect(adopted.runs.count == 1)
    #expect(adopted.pageSize == 0)
    #expect(adopted.runs[0].addedGeneration == 0)
    try await wax.verify(deep: true)

    // A one-page change (SQLite's user_version, in page 1) is a delta on the adopted blob,
    // which stays in place as the base.
    var image = try #require(try await wax.readCommittedLexIndexBytes())
    #expect(image.count == Int(adopted.imageLength))
    image.replaceSubrange(60..<64, with: [0, 0, 0, 7])
    try await wax.stageLexIndexForNextCommit(bytes: image, docCount: adopted.docCount)
    try await wax.commit()
    let delta = try #require(await wax.committedLexIndexManifest())
    #expect(delta.runs.count == 2)
    #expect(delta.runs[0] == adopted.runs[0])
    #expect(delta.runs[1].bytesLength == 24 + 4 + 4096, "a run header and one page")
    #expect(delta.pageSize == 4096)
    #expect(try await wax.readCommittedLexIndexBytes() == image)
    try await wax.verify(deep: true)

    let session = try await wax.openSession(.readWrite(.fail), config: LexRunFixture.textOnly)
    let before = try await LexRunFixture.hits(session)
    #expect(before["number3"] == [])
    #expect(before["amber"] == LexRunFixture.amberFrames(below: 50))
    try await LexRunFixture.put(50..<55, in: session)
    try await session.commit()
    // Five passages change more than a quarter of this 35-page image, so the commit writes a
    // fresh base in place of the blob and its delta.
    let rebased = try #require(await wax.committedLexIndexManifest())
    #expect(rebased.runs.count == 1)
    #expect(rebased.runs[0].checksum != adopted.runs[0].checksum)
    #expect(rebased.pageSize == 4096)
    let after = try await LexRunFixture.hits(session)
    #expect(after["amber"] == LexRunFixture.amberFrames(below: 55))
    #expect(try await session.searchText(query: "number52", topK: 10).map(\.frameId) == [52])
    await session.close()
    try await wax.verify(deep: true)
    try await wax.close()

    #expect(try await LexRunFixture.reopenedHits(at: url) == after)
}

/// Expands a gzip fixture with gzip on a GCD thread, off the cooperative pool.
private func copyLexMigrationFixture(named name: String) async throws -> URL {
    try await BlockingWork.run {
        guard let bundled = Bundle.module.url(forResource: "\(name).wax", withExtension: "gz") else {
            throw WaxError.io("missing migration fixture \(name).wax.gz")
        }
        guard let gzip = ["/usr/bin/gzip", "/bin/gzip"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw WaxError.io("gzip executable not found")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wax")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzip)
        process.arguments = ["-dc", bundled.path]
        process.standardOutput = output
        try process.run()
        guard process.waitForExit(timeout: 120) == 0 else {
            throw WaxError.io("failed to expand migration fixture \(name).wax.gz")
        }
        return destination
    }
}
