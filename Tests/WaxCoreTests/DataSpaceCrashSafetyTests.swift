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

/// Reads the durable commit's TOC bytes and footer.
private func committedTocAndFooter(_ wax: Wax) async throws -> (toc: Data, footer: WaxFooter) {
    let range = await wax.dataSpace.committedTocRange
    let file = try FDFile.openReadOnly(at: await wax.fileURL())
    defer { try? file.close() }
    let tocLength = UInt64(range.count) - Constants.footerSize
    let toc = try file.readExactly(length: Int(tocLength), at: range.lowerBound)
    let footer = try WaxFooter.decode(
        from: try file.readExactly(length: Int(Constants.footerSize), at: range.lowerBound + tocLength)
    )
    return (toc, footer)
}

@Test func headerCommitWinsAGenerationTieWithAStaleFooter() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    try await wax.commit()
    let older = try await committedTocAndFooter(wax)
    try await putFrames(wax, 20..<21)
    try await wax.commit()
    let committed = await wax.stats().generation
    try await wax.close()

    // Footers synced before their headers in sessions that then crashed carry the generation
    // the next session commits under, because open cannot see them (they sit in free space
    // below the file end). One that survives at a higher offset than that commit, with an
    // older TOC, ties the header's commit when a later open scans.
    let file = try FDFile.open(at: url)
    let staleOffset = try file.size() + 4096
    try file.writeAll(older.toc, at: staleOffset)
    let stale = WaxFooter(
        tocLen: UInt64(older.toc.count),
        tocHash: older.footer.tocHash,
        generation: committed,
        walCommittedSeq: older.footer.walCommittedSeq
    )
    try file.writeAll(try stale.encode(), at: staleOffset + UInt64(older.toc.count))
    try file.fsync()
    try file.close()

    let reopened = try await Wax.open(at: url)
    #expect(await reopened.stats().frameCount == 21, "the header's commit wins the tie")
    #expect(await reopened.stats().generation == committed)
    try await reopened.verify(deep: true)
    try await reopened.close()
}

@Test func aDurableCommitFreesWhatItSupersededAtOnce() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 20, round: 1), docCount: 20)
    try await wax.commit()
    let g1Lex = try #require(await wax.toc.segmentCatalog.entries.first { $0.kind == .lex })
    let g1Toc = await wax.dataSpace.committedTocRange
    try await putFrames(wax, 20..<40)
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 40, round: 2), docCount: 40)
    try await wax.commit()

    // G2's header went to the page naming G1, and the page naming G2 is never rewritten in
    // place, so no recovery can select G1 again: its index and TOC are free for reuse.
    let free = await wax.dataSpace.free
    #expect(free.isFree(g1Lex.bytesOffset..<(g1Lex.bytesOffset + g1Lex.bytesLength)))
    #expect(free.isFree(g1Toc))
    try await wax.close()

    // Open does not hold G1 for the other header page either.
    let reopened = try await Wax.open(at: url)
    let reopenedFree = await reopened.dataSpace.free
    #expect(reopenedFree.isFree(g1Lex.bytesOffset..<(g1Lex.bytesOffset + g1Lex.bytesLength)))
    try await reopened.verify(deep: true)
    try await reopened.close()
}

@Test func tornHeaderWriteDuringTheNextCommitFallsBackToTheNewestCommit() async throws {
    let url = TempFiles.uniqueURL()
    var copy: URL?
    defer {
        try? FileManager.default.removeItem(at: url)
        if let copy { try? FileManager.default.removeItem(at: copy) }
    }
    let lex2 = lexBlob(docCount: 40, round: 2)

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    // G1's index is the largest, so G3's fits in the space G1 leaves.
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 80, round: 1), docCount: 80)
    try await wax.commit()
    try await putFrames(wax, 20..<40)
    try await wax.stageLexIndexForNextCommit(bytes: lex2, docCount: 40)
    try await wax.commit()
    let pagesAtG2 = try headerPages(url)
    let g2Page = try #require(WaxHeaderPage.selectValidPage(
        pageA: Data(pagesAtG2.prefix(Int(Constants.headerPageSize))),
        pageB: Data(pagesAtG2.suffix(Int(Constants.headerPageSize)))
    ))
    // G3 reuses the space G1 used; its header page write is then cut short.
    try await putFrames(wax, 40..<60)
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 60, round: 3), docCount: 60)
    try await wax.commit()
    copy = try crashCopy(of: url)
    try await wax.close()

    let crashed = try #require(copy)
    var pages = pagesAtG2
    let writtenPage = (1 - g2Page.pageIndex) * Int(Constants.headerPageSize)
    pages.replaceSubrange(writtenPage..<(writtenPage + 512), with: Data(repeating: 0, count: 512))
    try writeHeaderPages(pages, to: crashed)
    // Drop G3's TOC and footer so only the header pages can lead open to a commit.
    let file = try FDFile.open(at: crashed)
    let g2End = try #require(try FooterScanner.findFooter(at: g2Page.page.footerOffset, in: crashed))
    try file.truncate(to: g2End.footerOffset + Constants.footerSize)
    try file.fsync()
    try file.close()

    let reopened = try await Wax.open(at: crashed)
    try await reopened.verify(deep: true)
    #expect(try await reopened.readCommittedLexIndexBytes() == lex2)
    #expect(await reopened.stats().frameCount == 40)
    try await reopened.close()
}

/// A commit whose footer synced but whose header write failed leaves a valid footer in space
/// the next session cannot see and reuses. A later footer scan must not select it.
@Test func aFooterAnOpenPassedOverStaysDeadAfterItsSpaceIsReused() async throws {
    let url = TempFiles.uniqueURL()
    var copies: [URL] = []
    defer {
        try? FileManager.default.removeItem(at: url)
        for copy in copies { try? FileManager.default.removeItem(at: copy) }
    }
    let lex2 = lexBlob(docCount: 10, round: 2)

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 80, round: 1), docCount: 80)
    try await wax.commit()
    try await wax.stageLexIndexForNextCommit(bytes: lex2, docCount: 10)
    try await wax.commit()
    let g2 = await wax.stats().generation
    // G3 lands in the space G1 freed, below G2's footer; its header write fails after the
    // footer synced (a crash between the two leaves the same file).
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 79, round: 3), docCount: 79)
    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: [
        .shortWrite(maxBytes: .max), .shortWrite(maxBytes: .max), .shortWrite(maxBytes: .max), .eio,
    ]))
    await #expect(throws: (any Error).self) { try await wax.commit() }
    await wax.installFileFaultPlanForTesting(nil)
    copies.append(try crashCopy(of: url))
    try? await wax.close()

    // The file ends at G2's footer, so this open never sees G3. Its commit makes the fence
    // durable and then fails before writing a footer, so no newer commit outranks G3; the
    // next put reuses G3's bytes.
    let second = try await Wax.open(at: copies[0])
    #expect(await second.stats().generation == g2)
    try await putFrames(second, 20..<21)
    await second.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: [.shortWrite(maxBytes: .max), .eio]))
    await #expect(throws: (any Error).self) { try await second.commit() }
    await second.installFileFaultPlanForTesting(nil)
    #expect(await second.dataSpace.recoveryFenceDurable)
    _ = try await second.put(Data(repeating: 0xEE, count: 1000))
    _ = try await second.put(noise(byteCount: 200_000, seed: 7))
    copies.append(try crashCopy(of: copies[0]))
    try? await second.close()

    // The file no longer ends at the durable footer, so this open scans and finds G3's footer.
    let third = try await Wax.open(at: copies[1])
    #expect(await third.stats().generation == g2)
    #expect(try await third.readCommittedLexIndexBytes() == lex2)
    try await third.verify(deep: true)
    try await third.close()
}

/// Until a session's fence is durable it appends instead of reusing space, so a footer the
/// open passed over keeps its bytes and a later recovery may still select it intact.
@Test func anOpenThatHasNotCommittedLeavesFreeSpaceUntouched() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await putFrames(wax, 0..<20)
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 80, round: 1), docCount: 80)
    try await wax.commit()
    try await wax.stageLexIndexForNextCommit(bytes: lexBlob(docCount: 10, round: 2), docCount: 10)
    try await wax.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    let freeBefore = await reopened.dataSpace.free
    #expect(freeBefore.freeBytes > 0, "G1's index is free space")
    _ = try await reopened.put(Data(repeating: 0xEE, count: 1000))
    #expect(await reopened.dataSpace.free == freeBefore)
    try await reopened.commit()
    #expect(await reopened.dataSpace.recoveryFenceDurable)
    try await reopened.close()
}

// MARK: - Vector runs

// A commit writes the vectors added since the last commit as a run in free space. A footer a
// scan finds counts only when its runs are whole, and runs a merge superseded stay intact
// until a header page names the merged commit.

private let runDimension = 64

private func runVector(_ frame: Int, version: Int = 0) -> [Float] {
    (0..<runDimension).map { Float(frame + 1) * 0.01 + Float($0) * 0.001 + Float(version) }
}

private func committedVectorMap(_ wax: Wax) async throws -> [UInt64: [Float]] {
    guard let committed = try await wax.readCommittedVectors() else { return [:] }
    let dimension = Int(committed.dimension)
    return Dictionary(uniqueKeysWithValues: committed.frameIds.enumerated().map { row, frameId in
        (frameId, Array(committed.vectors[(row * dimension)..<((row + 1) * dimension)]))
    })
}

/// Puts frames `range` with their vectors.
private func putEmbeddedFrames(_ wax: Wax, _ range: Range<Int>) async throws {
    try await putFrames(wax, range)
    try await wax.putEmbeddingBatch(
        frameIds: range.map(UInt64.init),
        vectors: range.map { runVector($0) }
    )
}

private func expectedVectors(_ range: Range<Int>) -> [UInt64: [Float]] {
    Dictionary(uniqueKeysWithValues: range.map { (UInt64($0), runVector($0)) })
}

/// The runs the durable commit wrote.
private func runsOfTheLastCommit(_ wax: Wax) async throws -> [VecRunManifest] {
    let generation = await wax.stats().generation
    let manifest = try #require(await wax.committedVecIndexManifest())
    return manifest.runs.filter { $0.addedGeneration == generation }
}

private func flipByte(in run: VecRunManifest, of url: URL) throws {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    let offset = run.bytesOffset + run.bytesLength / 2
    var byte = try file.readExactly(length: 1, at: offset)
    byte[0] ^= 0xFF
    try file.writeAll(byte, at: offset)
    try file.fsync()
}

/// The number of `pwrite`s a commit issues before it writes a header page.
private func writesBeforeTheHeader(_ operations: [FDFileOperation]) -> Int {
    var writes = 0
    for operation in operations {
        guard case .pwrite(let offset, _) = operation else { continue }
        if offset < Constants.headerRegionSize { return writes }
        writes += 1
    }
    return writes
}

/// G2's footer synced but its header write was lost, so only a footer scan finds G2. When a
/// run G2 wrote is torn, open falls back to G1 and replays G2's records as pending.
@Test(arguments: [false, true])
func aFooterOnlyAScanFindsCountsOnlyWhenItsVectorRunsAreWhole(tornRun: Bool) async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await wax.setVectorIndexConfiguration(dimension: UInt32(runDimension), similarity: .cosine)
    try await putEmbeddedFrames(wax, 0..<20)
    try await wax.commit()
    try await wax.close()
    let headersAtG1 = try headerPages(url)

    let second = try await Wax.open(at: url)
    try await putEmbeddedFrames(second, 20..<30)
    try await second.putEmbedding(frameId: 3, vector: runVector(3, version: 1))
    try await second.removeEmbedding(frameId: 4)
    try await second.commit()
    let g2Runs = try await runsOfTheLastCommit(second)
    try #require(g2Runs.count == 1)
    try await second.close()
    try writeHeaderPages(headersAtG1, to: url)
    if tornRun {
        try flipByte(in: g2Runs[0], of: url)
    }

    var g2Vectors = expectedVectors(0..<30)
    g2Vectors[3] = runVector(3, version: 1)
    g2Vectors[4] = nil

    let recovered = try await Wax.open(at: url)
    if tornRun {
        #expect(await recovered.stats().frameCount == 20, "the torn commit is passed over")
        #expect(try await committedVectorMap(recovered) == expectedVectors(0..<20))
        let pending = await recovered.pendingEmbeddingMutations(since: nil)
        let pendingIds: Set<UInt64> = Set(pending.embeddings.map(\.frameId))
        var expectedPending: Set<UInt64> = Set((20..<30).map { UInt64($0) })
        expectedPending.insert(3)
        #expect(pendingIds == expectedPending)
        #expect(pending.removedFrameIds == [4])
        try await recovered.commit()
    } else {
        #expect(await recovered.stats().frameCount == 30, "the scan recovers G2")
    }
    #expect(try await committedVectorMap(recovered) == g2Vectors)
    try await recovered.verify(deep: true)
    try await recovered.close()

    let reopened = try await Wax.open(at: url)
    #expect(try await committedVectorMap(reopened) == g2Vectors)
    try await reopened.verify(deep: true)
    try await reopened.close()
}

/// The single sync before the header write must cover the runs, so a commit writes them
/// before its first sync.
@Test func aCommitWritesItsVectorRunsBeforeTheSyncThatPrecedesItsHeader() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await wax.setVectorIndexConfiguration(dimension: UInt32(runDimension), similarity: .cosine)
    try await putEmbeddedFrames(wax, 0..<10)
    try await wax.commit()
    try await putEmbeddedFrames(wax, 10..<20)

    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(recordsOperations: true))
    try await wax.commit()
    let operations = await wax.recordedFileOperationsForTesting()
    await wax.installFileFaultPlanForTesting(nil)

    let run = try #require(try await runsOfTheLastCommit(wax).first)
    let runWrite = try #require(operations.firstIndex(of: .pwrite(offset: run.bytesOffset, length: Int(run.bytesLength))))
    let firstSync = try #require(operations.firstIndex(of: .fsync))
    let headerWrite = try #require(operations.firstIndex {
        if case .pwrite(let offset, _) = $0 { return offset < Constants.headerRegionSize }
        return false
    })
    #expect(runWrite < firstSync)
    #expect(firstSync < headerWrite)
    try await wax.close()
}

/// A commit that fails after writing its run leaves the run unreferenced: the committed
/// vectors stay as they were, the same session commits the changes again, and a crash at
/// that point recovers the previous commit with the changes pending.
@Test func aCommitThatFailsAfterWritingItsVectorRunLeavesTheCommittedVectorsIntact() async throws {
    let url = TempFiles.uniqueURL()
    var copy: URL?
    defer {
        try? FileManager.default.removeItem(at: url)
        if let copy { try? FileManager.default.removeItem(at: copy) }
    }
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await wax.setVectorIndexConfiguration(dimension: UInt32(runDimension), similarity: .cosine)
    try await putEmbeddedFrames(wax, 0..<10)
    try await wax.commit()
    let g1 = await wax.stats().generation
    try await putEmbeddedFrames(wax, 10..<20)

    // The run write goes through; the TOC write after it fails.
    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(pwrite: [.shortWrite(maxBytes: .max), .eio]))
    await #expect(throws: (any Error).self) { try await wax.commit() }
    await wax.installFileFaultPlanForTesting(nil)
    #expect(await wax.stats().generation == g1)
    #expect(try await committedVectorMap(wax) == expectedVectors(0..<10))
    copy = try crashCopy(of: url)

    try await wax.commit()
    #expect(try await committedVectorMap(wax) == expectedVectors(0..<20))
    try await wax.close()
    let reopened = try await Wax.open(at: url)
    #expect(try await committedVectorMap(reopened) == expectedVectors(0..<20))
    try await reopened.verify(deep: true)
    try await reopened.close()

    let crashed = try await Wax.open(at: try #require(copy))
    #expect(await crashed.stats().generation == g1)
    #expect(try await committedVectorMap(crashed) == expectedVectors(0..<10))
    try await crashed.commit()
    #expect(try await committedVectorMap(crashed) == expectedVectors(0..<20))
    try await crashed.verify(deep: true)
    try await crashed.close()
}

/// A merge commit whose header write fails after its footer synced: later writes in the
/// session must land on neither the merged run (a scan can select its commit) nor the runs
/// it superseded (the header's commit still names them, and open falls back to that commit
/// when the merged run is torn).
@Test func aMergeWhoseHeaderWriteFailsKeepsTheRunsItSupersededIntact() async throws {
    let url = TempFiles.uniqueURL()
    var copies: [URL] = []
    defer {
        try? FileManager.default.removeItem(at: url)
        for copy in copies { try? FileManager.default.removeItem(at: copy) }
    }
    let runsBeforeMerge = Wax.vecRunMergeFanout - 1

    /// Commits `runsBeforeMerge` one-frame runs, then puts the frame whose commit merges.
    func prepare(_ wax: Wax) async throws {
        try await wax.setVectorIndexConfiguration(dimension: UInt32(runDimension), similarity: .cosine)
        for frame in 0..<runsBeforeMerge {
            try await putEmbeddedFrames(wax, frame..<(frame + 1))
            try await wax.commit()
        }
        try await putEmbeddedFrames(wax, runsBeforeMerge..<(runsBeforeMerge + 1))
    }

    // Count the merge commit's writes before its header on a store built the same way.
    let probeURL = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: probeURL) }
    let probe = try await Wax.create(at: probeURL, walSize: 256 * 1024)
    try await prepare(probe)
    await probe.installFileFaultPlanForTesting(FDFileFaultPlan(recordsOperations: true))
    try await probe.commit()
    let writes = writesBeforeTheHeader(await probe.recordedFileOperationsForTesting())
    #expect(try #require(await probe.committedVecIndexManifest()).runs.count == 1, "the commit merges")
    try await probe.close()

    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    try await prepare(wax)
    let headerCommit = await wax.stats().generation
    await wax.installFileFaultPlanForTesting(FDFileFaultPlan(
        pwrite: Array(repeating: .shortWrite(maxBytes: .max), count: writes) + [.eio]
    ))
    await #expect(throws: (any Error).self) { try await wax.commit() }
    await wax.installFileFaultPlanForTesting(nil)
    // Small payloads, so they fit the holes a freed run would leave.
    for index in 0..<64 {
        _ = try await wax.put(noise(byteCount: 64 * runDimension / 16, seed: UInt64(index + 1)))
    }
    copies.append(try crashCopy(of: url))
    copies.append(try crashCopy(of: url))
    try? await wax.close()

    // The scan selects the merge commit: its runs are whole.
    let merged = try await Wax.open(at: copies[0])
    #expect(await merged.stats().generation == headerCommit + 1)
    #expect(try await committedVectorMap(merged) == expectedVectors(0..<(runsBeforeMerge + 1)))
    let mergedRuns = try await runsOfTheLastCommit(merged)
    try #require(!mergedRuns.isEmpty)
    try await merged.verify(deep: true)
    try await merged.close()

    // With the merged run torn, open falls back to the header's commit, whose runs must
    // still hold their vectors.
    for run in mergedRuns {
        try flipByte(in: run, of: copies[1])
    }
    let fallback = try await Wax.open(at: copies[1])
    #expect(await fallback.stats().generation == headerCommit)
    #expect(try await committedVectorMap(fallback) == expectedVectors(0..<runsBeforeMerge))
    try await fallback.verify(deep: true)
    try await fallback.commit()
    #expect(try await committedVectorMap(fallback) == expectedVectors(0..<(runsBeforeMerge + 1)))
    try await fallback.close()
}
