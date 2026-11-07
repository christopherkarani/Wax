import Foundation
import Testing
@testable import WaxCore

// Space reuse must never overwrite bytes a recovery path can still select: the commit either
// header page names, and the segments of a commit whose footer synced before its header write
// failed.

private func payload(_ index: Int) -> Data {
    Data("frame \(index) ".utf8) + Data(repeating: UInt8(truncatingIfNeeded: index), count: 200)
}

private func lexBlob(docCount: Int, round: Int) -> Data {
    Data((0..<(docCount * 600)).map { UInt8(truncatingIfNeeded: $0 &+ round) })
}

/// Incompressible bytes, so payloads keep their size on disk.
private func noise(byteCount: Int, seed: UInt64) -> Data {
    var state = seed
    var words = [UInt64](repeating: 0, count: byteCount / 8)
    for index in words.indices {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        words[index] = state
    }
    return words.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func putFrames(_ wax: Wax, _ range: Range<Int>) async throws {
    for index in range {
        _ = try await wax.put(payload(index))
    }
}

/// Writes more than the footer scan window past the newest footer, so a later open can only
/// find commits through the header pages.
private func pushNewestFooterOutOfScanWindow(_ wax: Wax) async throws {
    // One small put first: it takes the lowest free range.
    _ = try await wax.put(Data(repeating: 0xEE, count: 1000))
    let chunk = 4 << 20
    for index in 0..<(Int(Constants.maxFooterScanBytes) / chunk + 1) {
        _ = try await wax.put(noise(byteCount: chunk, seed: UInt64(index + 1)))
    }
}

private func headerPages(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    return try handle.read(upToCount: Int(Constants.headerRegionSize)) ?? Data()
}

private func writeHeaderPages(_ pages: Data, to url: URL) throws {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    try file.writeAll(pages, at: 0)
    try file.fsync()
}

/// A copy of the file as it is on disk now, standing in for a crash of the open handle.
private func crashCopy(of url: URL) throws -> URL {
    let copy = TempFiles.uniqueURL()
    try FileManager.default.copyItem(at: url, to: copy)
    return copy
}

@Test func openAfterFooterScanRecoveryKeepsTheHeaderCommitIntact() async throws {
    let url = TempFiles.uniqueURL()
    var copy: URL?
    defer {
        try? FileManager.default.removeItem(at: url)
        if let copy { try? FileManager.default.removeItem(at: copy) }
    }
    let lex1 = lexBlob(docCount: 20, round: 1)
    let lex2 = lexBlob(docCount: 40, round: 2)

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    try await wax.stageLexIndexForNextCommit(bytes: lex1, docCount: 20)
    try await wax.commit()
    try await wax.close()
    let headersAtG1 = try headerPages(url)

    let second = try await Wax.open(at: url)
    try await putFrames(second, 20..<40)
    try await second.stageLexIndexForNextCommit(bytes: lex2, docCount: 40)
    try await second.commit()
    try await second.close()
    // A crash after G2's footer synced but before its header was written.
    try writeHeaderPages(headersAtG1, to: url)

    let recovered = try await Wax.open(at: url)
    #expect(await recovered.stats().frameCount == 40, "the footer scan recovers G2")
    try await pushNewestFooterOutOfScanWindow(recovered)
    copy = try crashCopy(of: url)
    try await recovered.close()

    // Whatever commit the header pages lead to must still be intact.
    let reopened = try await Wax.open(at: try #require(copy))
    try await reopened.verify(deep: true)
    let lex = try await reopened.readCommittedLexIndexBytes()
    #expect(lex == lex2 || lex == lex1)
    #expect(await reopened.stats().frameCount >= 40, "G2 was durable once open recovered it")
    try await reopened.close()
}

@Test func tornNewestHeaderPageFallsBackToAnIntactCommit() async throws {
    let url = TempFiles.uniqueURL()
    var copy: URL?
    defer {
        try? FileManager.default.removeItem(at: url)
        if let copy { try? FileManager.default.removeItem(at: copy) }
    }
    let lex1 = lexBlob(docCount: 20, round: 1)
    let lex2 = lexBlob(docCount: 40, round: 2)

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    try await wax.stageLexIndexForNextCommit(bytes: lex1, docCount: 20)
    try await wax.commit()
    try await putFrames(wax, 20..<40)
    try await wax.stageLexIndexForNextCommit(bytes: lex2, docCount: 40)
    try await wax.commit()
    try await pushNewestFooterOutOfScanWindow(wax)
    copy = try crashCopy(of: url)
    try await wax.close()

    // The page naming G2 is torn (an in-place header rewrite cut short), so open falls back
    // to the other page, which names G1.
    let crashed = try #require(copy)
    let pages = try headerPages(crashed)
    let selected = try #require(WaxHeaderPage.selectValidPage(
        pageA: Data(pages.prefix(Int(Constants.headerPageSize))),
        pageB: Data(pages.suffix(Int(Constants.headerPageSize)))
    ))
    let file = try FDFile.open(at: crashed)
    try file.writeAll(Data(repeating: 0, count: 512), at: UInt64(selected.pageIndex) * Constants.headerPageSize)
    try file.fsync()
    try file.close()

    let reopened = try await Wax.open(at: crashed)
    #expect(await reopened.stats().frameCount == 20)
    try await reopened.verify(deep: true)
    #expect(try await reopened.readCommittedLexIndexBytes() == lex1)
    try await reopened.close()
}

@Test func failedHeaderWriteKeepsTheSyncedCommitIntact() async throws {
    let url = TempFiles.uniqueURL()
    var copy: URL?
    defer {
        try? FileManager.default.removeItem(at: url)
        if let copy { try? FileManager.default.removeItem(at: copy) }
    }
    let lex2 = lexBlob(docCount: 40, round: 2)

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 20, round: 1), docCount: 20)
    try await wax.commit()
    let committedGeneration = await wax.stats().generation
    try await putFrames(wax, 20..<40)
    try await wax.stageLexIndexForNextCommit(bytes: lex2, docCount: 40)
    // Lex, TOC and footer writes go through (a full-length "short" write is a plain write);
    // the header write fails after the footer synced.
    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: [
        .shortWrite(maxBytes: .max), .shortWrite(maxBytes: .max), .shortWrite(maxBytes: .max), .eio,
    ]))
    await #expect(throws: (any Error).self) { try await wax.commit() }
    await wax.installFileFaultPlanForTesting(nil)
    // Later writes must not land on the failed commit's segments: its footer is durable.
    for index in 40..<60 {
        _ = try await wax.put(noise(byteCount: 4096, seed: UInt64(index)))
    }
    copy = try crashCopy(of: url)
    try await wax.close()

    let reopened = try await Wax.open(at: try #require(copy))
    #expect(await reopened.stats().generation == committedGeneration + 1, "the scan recovers the synced commit")
    try await reopened.verify(deep: true)
    #expect(try await reopened.readCommittedLexIndexBytes() == lex2)
    try await reopened.close()
}
