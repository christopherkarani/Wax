import Foundation
import Testing
@testable import WaxCore

// Commits that replace the lex index, the vector index and the TOC must reuse the space the
// previous versions held, so the file tracks the live data instead of growing by a full
// index snapshot per commit.

private func roundVector(frame: Int, dimension: Int, seed: Float) -> [Float] {
    (0..<dimension).map { Float((frame * dimension + $0) % 97) * 0.01 + seed }
}

/// Bytes the committed vectors take as one run: header, rows, key count and keys.
private func liveVectorBytes(count: Int, dimension: Int) -> Int {
    36 + count * (dimension * MemoryLayout<Float>.stride + MemoryLayout<UInt64>.stride) + 8
}

private func lexBlob(docCount: Int, round: Int) -> Data {
    Data((0..<(docCount * 600)).map { UInt8(truncatingIfNeeded: $0 &+ round) })
}

private func payload(_ index: Int) -> Data {
    Data("frame \(index) ".utf8) + Data(repeating: UInt8(truncatingIfNeeded: index), count: 280)
}

private func fileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
}

/// Runs `rounds` put-embed-commit cycles of `perRound` frames, each re-embedding every frame,
/// and returns the last lex blob and the committed vectors.
private func ingestRounds(
    _ wax: Wax,
    rounds: Range<Int>,
    perRound: Int,
    dimension: Int
) async throws -> (lex: Data, vec: [UInt64: [Float]]) {
    var lastLex = Data()
    var vectors: [UInt64: [Float]] = [:]
    try await wax.setVectorIndexConfiguration(dimension: UInt32(dimension), similarity: .cosine)
    for round in rounds {
        for offset in 0..<perRound {
            _ = try await wax.put(payload(round * perRound + offset), options: FrameMetaSubset(searchText: "doc \(round) \(offset)"))
        }
        let total = (round + 1) * perRound
        lastLex = lexBlob(docCount: total, round: round)
        let frameIds = (0..<UInt64(total)).map { $0 }
        let rows = frameIds.map { roundVector(frame: Int($0), dimension: dimension, seed: Float(round)) }
        try await wax.putEmbeddingBatch(frameIds: frameIds, vectors: rows)
        vectors = Dictionary(uniqueKeysWithValues: zip(frameIds, rows))
        try await wax.stageLexIndexForNextCommit(bytes: lastLex, docCount: UInt64(total))
        try await wax.commit()
    }
    return (lastLex, vectors)
}

private func committedVectorMap(_ wax: Wax) async throws -> [UInt64: [Float]] {
    guard let committed = try await wax.readCommittedVectors() else { return [:] }
    let dimension = Int(committed.dimension)
    return Dictionary(uniqueKeysWithValues: committed.frameIds.enumerated().map { row, frameId in
        (frameId, Array(committed.vectors[(row * dimension)..<((row + 1) * dimension)]))
    })
}

private func expectStoreIntact(_ wax: Wax, frameCount: Int, lex: Data, vec: [UInt64: [Float]]) async throws {
    try await wax.verify(deep: true)
    #expect(try await wax.readCommittedLexIndexBytes() == lex)
    #expect(try await committedVectorMap(wax) == vec)
    #expect(await wax.stats().frameCount == UInt64(frameCount))
    for frameId in stride(from: 0, to: frameCount, by: 37) {
        #expect(try await wax.frameContent(frameId: UInt64(frameId)) == payload(frameId))
    }
    #expect(try await wax.frameContent(frameId: UInt64(frameCount - 1)) == payload(frameCount - 1))
}

@Test func repeatedIndexCommitsReuseSupersededSpace() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let walSize: UInt64 = 256 * 1024
    let perRound = 25
    let rounds = 40
    let dimension = 32

    let wax = try await Wax.create(at: url, walSize: walSize)
    let (lex, vec) = try await ingestRounds(wax, rounds: 0..<rounds, perRound: perRound, dimension: dimension)
    try await wax.close()

    // Live data: payloads, the latest lex and vec segments, and the latest TOC. Without
    // reuse the file holds every superseded snapshot: about rounds / 2 times the indexes.
    let frames = rounds * perRound
    let payloadBytes = (0..<frames).reduce(0) { $0 + payload($1).count }
    let reopened = try await Wax.open(at: url)
    let tocBytes = try #require(await reopened.committedTocByteCount())
    let live = UInt64(payloadBytes + lex.count + liveVectorBytes(count: vec.count, dimension: dimension))
        + tocBytes + Constants.footerSize
    let dataBytes = try fileSize(url) - (Constants.headerRegionSize + walSize)
    #expect(dataBytes <= 3 * live, "data region \(dataBytes) B vs live \(live) B")
    try await expectStoreIntact(reopened, frameCount: frames, lex: lex, vec: vec)

    // Reuse continues after a reopen, and the result still verifies.
    let (lex2, vec2) = try await ingestRounds(reopened, rounds: rounds..<(rounds + 10), perRound: perRound, dimension: dimension)
    try await reopened.close()
    let again = try await Wax.open(at: url)
    try await expectStoreIntact(again, frameCount: (rounds + 10) * perRound, lex: lex2, vec: vec2)
    try await again.close()
}

@Test func commitLeavesItsFooterAtTheEndOfTheFile() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url, walSize: 64 * 1024)
    _ = try await ingestRounds(wax, rounds: 0..<12, perRound: 10, dimension: 8)
    try await wax.close()

    // The file ends at the newest footer, so open takes the fast path with no footer scan.
    let reopened = try await Wax.open(at: url, repair: false)
    #expect(await reopened.walStats().replayFooterScanCount == 0)
    try await reopened.close()
}

@Test func stagedLexIndexSurvivesAutoCommitInsidePut() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    // A tiny WAL: a put that does not fit commits first, inside the put.
    let wax = try await Wax.create(at: url, walSize: 2 * 1024)
    let lex = lexBlob(docCount: 2, round: 7)
    try await wax.stageLexIndexForNextCommit(bytes: lex, docCount: 2)
    var puts = 0
    while await wax.walStats().autoCommitCount == 0 {
        _ = try await wax.put(payload(puts), options: FrameMetaSubset(searchText: "p\(puts)"))
        puts += 1
        try #require(puts < 256)
    }
    try await wax.close()

    // The put that triggered the auto-commit must not write its payload over the segments
    // that commit placed.
    let reopened = try await Wax.open(at: url)
    try await reopened.verify(deep: true)
    #expect(try await reopened.readCommittedLexIndexBytes() == lex)
    for frameId in 0..<puts {
        #expect(try await reopened.frameContent(frameId: UInt64(frameId)) == payload(frameId))
    }
    try await reopened.close()
}

@Test func commitAfterReopenOutnumbersAFooterACrashLeftInFreeSpace() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url, walSize: 64 * 1024)
    let (lex, vec) = try await ingestRounds(wax, rounds: 0..<8, perRound: 10, dimension: 8)
    let committedGeneration = await wax.stats().generation
    let tocRange = await wax.dataSpace.committedTocRange
    let hole = try #require(await wax.dataSpace.free.extents.last { $0.count >= tocRange.count && $0.upperBound <= tocRange.lowerBound })
    try await wax.close()

    // A crash after a commit's footer was synced but before its header was leaves a valid
    // TOC and footer one generation ahead in a free hole. The file still ends at the
    // committed footer, so open takes the fast path and never sees it.
    let file = try FDFile.open(at: url)
    let tocLength = UInt64(tocRange.count) - Constants.footerSize
    let tocBytes = try file.readExactly(length: Int(tocLength), at: tocRange.lowerBound)
    let committedFooter = try WaxFooter.decode(
        from: try file.readExactly(length: Int(Constants.footerSize), at: tocRange.lowerBound + tocLength)
    )
    let staleFooter = WaxFooter(
        tocLen: tocLength,
        tocHash: committedFooter.tocHash,
        generation: committedGeneration + 1,
        walCommittedSeq: committedFooter.walCommittedSeq
    )
    try file.writeAll(tocBytes, at: hole.lowerBound)
    try file.writeAll(try staleFooter.encode(), at: hole.lowerBound + tocLength)
    try file.fsync()
    try file.close()

    let reopened = try await Wax.open(at: url)
    #expect(await reopened.stats().generation == committedGeneration)
    _ = try await reopened.put(payload(80), options: FrameMetaSubset(searchText: "after crash"))
    try await reopened.commit()
    let nextGeneration = await reopened.stats().generation
    try await reopened.close()

    // A torn tail makes the next open scan for footers. The new commit must win over the
    // stale footer, whose TOC no longer describes the file.
    #expect(nextGeneration > staleFooter.generation)
    let tail = try FDFile.open(at: url)
    try tail.writeAll(Data(repeating: 0xAB, count: 100), at: try tail.size())
    try tail.fsync()
    try tail.close()
    let scanned = try await Wax.open(at: url)
    #expect(await scanned.stats().generation == nextGeneration)
    try await expectStoreIntact(scanned, frameCount: 81, lex: lex, vec: vec)
    try await scanned.close()
}

// MARK: - FreeSpaceMap

@Test func freeSpaceMapIsTheComplementOfUsedRanges() {
    let map = FreeSpaceMap(start: 100, end: 200, used: [150..<160, 100..<110, 155..<170, 190..<250])
    #expect(map.extents == [110..<150, 170..<190])
    #expect(map.freeBytes == 60)
}

@Test func freeSpaceMapTakesTheLowestFitAtOrAboveTheFloor() {
    var map = FreeSpaceMap(start: 0, end: 100, used: [10..<20, 30..<60])
    #expect(map.takeFirstFit(length: 15) == 60)
    #expect(map.extents == [0..<10, 20..<30, 75..<100])
    #expect(map.takeFirstFit(length: 5, notBelow: 22) == 22)
    #expect(map.extents == [0..<10, 20..<22, 27..<30, 75..<100])
    #expect(map.takeFirstFit(length: 26) == nil)
    #expect(map.takeFirstFit(length: 0) == nil)
}

@Test func freeSpaceMapReleaseCoalescesNeighbours() {
    var map = FreeSpaceMap(start: 0, end: 100, used: [10..<20, 30..<40])
    map.release(20..<30)
    #expect(map.extents == [0..<10, 20..<30, 40..<100])
    map.release(10..<20)
    map.release(30..<40)
    #expect(map.extents == [0..<100])
    map.truncate(to: 64)
    #expect(map.extents == [0..<64])
    #expect(map.isFree(10..<64))
    #expect(!map.isFree(10..<65))
}
