import Foundation
import Testing
@testable import WaxCore

@Test func createWritesInitialFooterAndReopenWorks() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let stats0 = await wax.stats()
    #expect(stats0.frameCount == 0)
    #expect(stats0.generation == 0)
    try await wax.close()

    let slice = try FooterScanner.findLastValidFooter(in: url)
    #expect(slice != nil)
    #expect(slice?.footer.generation == 0)
    #expect(slice?.footer.walCommittedSeq == 0)

    let reopened = try await Wax.open(at: url)
    let stats1 = await reopened.stats()
    #expect(stats1.frameCount == 0)
    #expect(stats1.pendingFrames == 0)
    try await reopened.close()
}

@Test func putCommitReopenReadsBackPayload() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        let frameId = try await wax.put(Data("Hello, World!".utf8))
        #expect(frameId == 0)
        try await wax.commit()
        try await wax.close()
    }

    do {
        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == 1)
        #expect(stats.generation == 1)

        let content = try await wax.frameContent(frameId: 0)
        #expect(content == Data("Hello, World!".utf8))

        let preview = try await wax.framePreview(frameId: 0, maxBytes: 5)
        #expect(preview == Data("Hello".utf8))
        try await wax.close()
    }
}

@Test func emptyCommitIsNoOp() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let gen0 = await wax.stats().generation
    try await wax.commit()
    let gen1 = await wax.stats().generation
    #expect(gen0 == gen1)
    try await wax.close()
}

@Test func reopenAfterWalFullCommitAllowsFuturePuts() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let options = FrameMetaSubset()
    let dummyPut = PutFrame(
        frameId: 0,
        timestampMs: 0,
        options: options,
        payloadOffset: 0,
        payloadLength: 0,
        canonicalEncoding: .plain,
        canonicalLength: 0,
        canonicalChecksum: Data(repeating: 0xAA, count: 32),
        storedChecksum: Data(repeating: 0xBB, count: 32)
    )
    let walPayload = try WALEntryCodec.encode(.putFrame(dummyPut))
    let entrySize = UInt64(WALRecord.headerSize) + UInt64(walPayload.count)
    let walSize = entrySize * 2

    do {
        let wax = try await Wax.create(at: url, walSize: walSize)
        _ = try await wax.put(Data("a".utf8))
        _ = try await wax.put(Data("b".utf8))
        try await wax.commit()
        try await wax.close()
    }

    do {
        let wax = try await Wax.open(at: url)
        let frameId = try await wax.put(Data("c".utf8))
        #expect(frameId == 2)
        try await wax.close()
    }
}

@Test func closeCommitsPendingMutations() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("pending".utf8))
        try await wax.close()
    }

    do {
        let reopened = try await Wax.open(at: url)
        let stats = await reopened.stats()
        #expect(stats.frameCount == 1)
        let payload = try await reopened.frameContent(frameId: 0)
        #expect(payload == Data("pending".utf8))
        try await reopened.close()
    }
}
