import Foundation
import Testing
@testable import WaxCore

private func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
}

/// Search text lives in each frame's TOC entry, so a long search text grows the TOC directly.
@Test func commitRefusesATocOverTheReaderLimitAndKeepsTheStoreOpenable() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("committed".utf8))
    try await wax.commit()

    let tocLimit: UInt64 = 64 * 1024
    await wax.setTocByteLimitForTesting(tocLimit)
    _ = try await wax.put(
        Data("big".utf8),
        options: FrameMetaSubset(searchText: String(repeating: "a", count: Int(tocLimit) * 2))
    )
    try await wax.stageLexIndexForNextCommit(bytes: Data(repeating: 7, count: 4096), docCount: 1)
    let sizeBefore = try fileSize(url)
    do {
        try await wax.commit()
        Issue.record("commit must refuse a TOC over the reader's limit")
    } catch WaxError.capacityExceeded(let limit, let requested) {
        #expect(limit == tocLimit)
        #expect(requested > tocLimit)
    }
    #expect(try fileSize(url) == sizeBefore, "a refused commit must not write any of its bytes")
    #expect(await wax.stats().frameCount == 1)
    #expect(await wax.stats().pendingFrames == 1)
    #expect(await wax.stats().generation == 1)
    // Refused again from the same state; the handle still reads the last commit.
    await #expect(throws: WaxError.self) { try await wax.commit() }
    #expect(try await wax.frameContent(frameId: 0) == Data("committed".utf8))
    await #expect(throws: WaxError.self) { try await wax.close() }

    let reopened = try await Wax.open(at: url)
    #expect(await reopened.frameMetas().map(\.id) == [0])
    #expect(try await reopened.frameContent(frameId: 0) == Data("committed".utf8))
    #expect(await reopened.committedLexIndexManifest() == nil)
    try await reopened.close()
}

/// About 55 MB of search text used to make a TOC the reader refused. Five frames of 14 MiB make
/// a TOC of about 70 MiB, past the old 64 MiB limit, that must commit and reopen intact.
@Test func storeWithATocOverSixtyFourMiBCommitsAndReopens() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let textBytes = 14 * 1024 * 1024
    let texts: [String] = (0..<5).map { index in
        String(repeating: Character(UnicodeScalar(UInt8(0x61 + index))), count: textBytes)
    }

    do {
        let wax = try await Wax.create(at: url, walSize: 80 * 1024 * 1024)
        for (index, text) in texts.enumerated() {
            _ = try await wax.put(Data("big-\(index)".utf8), options: FrameMetaSubset(searchText: text))
        }
        try await wax.commit()
        try await wax.close()
    }

    let footer = try #require(try FooterScanner.findLastValidFooter(in: url)).footer
    #expect(footer.tocLen > 64 * 1024 * 1024)

    let reopened = try await Wax.open(at: url)
    let frames = await reopened.frameMetas()
    #expect(frames.map(\.id) == [0, 1, 2, 3, 4])
    #expect(frames.map(\.searchText) == texts)
    #expect(try await reopened.frameContent(frameId: 4) == Data("big-4".utf8))
    try await reopened.close()
}
