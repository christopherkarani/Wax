import Foundation
import Testing
@testable import WaxCore

// MARK: - Helpers

private let pageSize = 4096

/// An image of `pages` pages, the last `tailBytes` long when given; page `index` holds bytes
/// derived from `index` and `versions[index]` (0 by default).
private func image(pages: Int, versions: [Int: Int] = [:], tailBytes: Int? = nil) -> Data {
    var data = Data(count: 0)
    data.reserveCapacity(pages * pageSize)
    for index in 0..<pages {
        let version = versions[index] ?? 0
        let length = index == pages - 1 ? (tailBytes ?? pageSize) : pageSize
        // A pointer loop: in debug builds a `for offset in 0..<length` subscript loop looks up
        // generic metadata on every byte, which made these images seconds of work on a
        // cooperative thread that never yields.
        let page = [UInt8](unsafeUninitializedCapacity: length) { bytes, initialized in
            var offset = 0
            while offset < length {
                bytes[offset] = UInt8(truncatingIfNeeded: index &* 31 &+ offset &* 7 &+ version &* 101)
                offset += 1
            }
            initialized = length
        }
        data.append(contentsOf: page)
    }
    return data
}

private func headerFormatVersions(_ url: URL) throws -> [UInt16] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let pages = try handle.read(upToCount: 8192) ?? Data()
    return [0, 4096].map { offset in
        UInt16(pages[offset + 4]) | (UInt16(pages[offset + 5]) << 8)
    }
}

private func lexCatalogEntries(_ wax: Wax) async -> [SegmentCatalogEntry] {
    await wax.segmentCatalogEntriesForTesting().filter { $0.kind == .lex }
}

private func flipByte(at offset: UInt64, of url: URL) throws {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    var byte = try file.readExactly(length: 1, at: offset)
    byte[0] ^= 0xFF
    try file.writeAll(byte, at: offset)
    try file.fsync()
}

/// Bytes of a delta run holding `pages` full pages.
private func deltaLength(pages: Int) -> UInt64 {
    UInt64(LexRunCodec.headerSize + pages * (4 + pageSize))
}

// MARK: - Codec

@Test func xxh64MatchesItsReferenceVectors() {
    func hash(_ text: String, seed: UInt64 = 0) -> UInt64 {
        Array(text.utf8).withUnsafeBytes { LexPageFingerprint.xxh64($0, seed: seed) }
    }
    #expect(hash("") == 0xEF46_DB37_51D8_E999)
    #expect(hash("a") == 0xD24E_C4F1_A98C_6E5B)
    #expect(hash("abc") == 0x44BC_2CF5_AD77_0999)
    #expect(hash("Nobody inspects the spammish repetition") == 0xFBCE_A83C_8A37_8BF1)
}

@Test func lexDeltaRunAppliesChangedGrownAndTruncatedPages() throws {
    let old = image(pages: 5, tailBytes: 100)
    let grown = image(pages: 7, versions: [1: 1], tailBytes: 300)
    let changed = [1, 4, 5, 6]
    let run = grown.withUnsafeBytes { raw in
        try? LexRunCodec.encode(pages: changed, of: raw, pageSize: pageSize)
    }
    let bytes = try #require(run)
    #expect(bytes.count == LexRunCodec.encodedLength(pages: changed, pageSize: pageSize, imageLength: grown.count))
    var applied = old
    try LexRunCodec.apply(bytes, to: &applied, pageSize: pageSize)
    #expect(applied == grown)

    let truncated = image(pages: 3, versions: [1: 1, 2: 3], tailBytes: 10)
    let shrink = try #require(truncated.withUnsafeBytes { raw in
        try? LexRunCodec.encode(pages: [2], of: raw, pageSize: pageSize)
    })
    try LexRunCodec.apply(shrink, to: &applied, pageSize: pageSize)
    #expect(applied == truncated)
}

@Test func lexDeltaRunThatGrowsItsImageWithoutTheNewPagesIsRejected() throws {
    let grown = image(pages: 4)
    let partial = try #require(grown.withUnsafeBytes { raw in
        try? LexRunCodec.encode(pages: [3], of: raw, pageSize: pageSize)
    })
    var target = image(pages: 2)
    #expect(throws: WaxError.self) { try LexRunCodec.apply(partial, to: &target, pageSize: pageSize) }
    var wrongSize = image(pages: 4)
    #expect(throws: WaxError.self) { try LexRunCodec.apply(partial, to: &wrongSize, pageSize: 8192) }
}

@Test func lexPageSizeComesFromTheSQLiteHeader() {
    var header = Data("SQLite format 3\u{0}".utf8)
    header.append(contentsOf: [0x20, 0x00])
    header.append(Data(count: 200))
    #expect(header.withUnsafeBytes { LexRunCodec.pageSize(of: $0, fallback: 4096) } == 8192)
    header[16] = 0x00
    header[17] = 0x01
    #expect(header.withUnsafeBytes { LexRunCodec.pageSize(of: $0, fallback: 4096) } == 65_536)
    #expect(Data(count: 200).withUnsafeBytes { LexRunCodec.pageSize(of: $0, fallback: 4096) } == 4096)
}

@Test func lexIndexManifestsRoundtripAndAdoptAV2BlobAsTheBase() throws {
    let lex = LexIndexManifest(
        docCount: 7,
        version: 1,
        pageSize: 4096,
        runs: [
            LexRunManifest(bytesOffset: 100, bytesLength: 8192, checksum: Data(repeating: 1, count: 32), addedGeneration: 3, imageLength: 8192),
            LexRunManifest(bytesOffset: 9000, bytesLength: 4124, checksum: Data(repeating: 2, count: 32), addedGeneration: 4, imageLength: 12_288),
        ]
    )
    var manifests = IndexManifests(lex: lex, vec: nil)
    var encoder = BinaryEncoder()
    try manifests.encode(to: &encoder)
    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try IndexManifests.decode(from: &decoder) == manifests)
    try decoder.finalize()

    // A v2 TOC: tag 1, then one blob's fields.
    var legacy = BinaryEncoder()
    legacy.encode(UInt8(1))
    legacy.encode(UInt64(5))
    legacy.encode(UInt64(2000))
    legacy.encode(UInt64(3000))
    legacy.encodeFixedBytes(Data(repeating: 0xAB, count: 32))
    legacy.encode(UInt32(1))
    legacy.encode(UInt8(0))
    legacy.encode(UInt8(0))
    var legacyDecoder = try BinaryDecoder(data: legacy.data)
    let adopted = try #require(try IndexManifests.decode(from: &legacyDecoder).lex)
    #expect(adopted == LexIndexManifest(
        docCount: 5,
        version: 1,
        pageSize: 0,
        runs: [LexRunManifest(bytesOffset: 2000, bytesLength: 3000, checksum: Data(repeating: 0xAB, count: 32), addedGeneration: 0, imageLength: 3000)]
    ))
}

// MARK: - Commits

@Test func aCommitWritesOnlyTheLexPagesThatChanged() async throws {
    try await TempFiles.withTempFile { url in
        let first = image(pages: 64)
        let second = image(pages: 65, versions: [3: 1, 40: 1])
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: first, docCount: 10)
        try await wax.commit()
        try await wax.stageLexIndexForNextCommit(bytes: second, docCount: 11)
        try await wax.commit()

        let manifest = try #require(await wax.committedLexIndexManifest())
        #expect(manifest.runs.count == 2)
        #expect(manifest.runs[0].bytesLength == UInt64(first.count))
        // Pages 3, 40 and the new page 64.
        #expect(manifest.runs[1].bytesLength == deltaLength(pages: 3))
        #expect(manifest.docCount == 11)
        #expect(manifest.pageSize == UInt32(pageSize))
        #expect(manifest.imageLength == UInt64(second.count))
        #expect(await lexCatalogEntries(wax).count == 2)
        #expect(try await wax.readCommittedLexIndexBytes() == second)
        try await wax.verify(deep: true)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        #expect(try await reopened.readCommittedLexIndexBytes() == second)
        try await reopened.verify(deep: true)
        try await reopened.close()
    }
}

@Test func stagingTwiceBeforeACommitWritesOneDeltaAgainstTheCommittedImage() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 32), docCount: 1)
        try await wax.commit()
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 32, versions: [1: 1]), docCount: 2)
        let latest = image(pages: 32, versions: [1: 2, 9: 1])
        try await wax.stageLexIndexForNextCommit(bytes: latest, docCount: 3)
        #expect(try await wax.readStagedLexIndexBytes() == latest)
        try await wax.commit()

        let manifest = try #require(await wax.committedLexIndexManifest())
        #expect(manifest.runs.map(\.bytesLength) == [UInt64(32 * pageSize), deltaLength(pages: 2)])
        #expect(try await wax.readCommittedLexIndexBytes() == latest)
        try await wax.close()
    }
}

@Test func aReopenedStoreStagesADeltaWithoutReadingTheImageFirst() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 16), docCount: 1)
        try await wax.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let next = image(pages: 15, versions: [2: 1])
        try await reopened.stageLexIndexForNextCommit(bytes: next, docCount: 2)
        try await reopened.commit()
        let manifest = try #require(await reopened.committedLexIndexManifest())
        #expect(manifest.runs.map(\.bytesLength) == [UInt64(16 * pageSize), deltaLength(pages: 1)])
        #expect(try await reopened.readCommittedLexIndexBytes() == next)
        try await reopened.verify(deep: true)
        try await reopened.close()
    }
}

@Test func deltasPastAQuarterOfTheImageAreReplacedByAFreshBase() async throws {
    try await TempFiles.withTempFile { url in
        let pages = 40
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: pages), docCount: 0)
        try await wax.commit()
        let firstBase = try #require(await wax.committedLexIndexManifest()?.runs.first)

        // Each commit changes 3 pages: three deltas hold 9 pages, under a quarter of 40; the
        // fourth would hold 12 and rebases.
        var versions: [Int: Int] = [:]
        var expected = Data()
        for round in 1...4 {
            for page in 0..<3 { versions[(round * 3 + page) % pages] = round }
            expected = image(pages: pages, versions: versions)
            try await wax.stageLexIndexForNextCommit(bytes: expected, docCount: UInt64(round))
            try await wax.commit()
            let manifest = try #require(await wax.committedLexIndexManifest())
            #expect(manifest.runs.count == (round < 4 ? round + 1 : 1), "round \(round)")
            #expect(await lexCatalogEntries(wax).count == manifest.runs.count)
        }
        let base = try #require(await wax.committedLexIndexManifest()?.runs.first)
        #expect(base.bytesLength == UInt64(pages * pageSize))
        #expect(base.bytesOffset != firstBase.bytesOffset)
        #expect(try await wax.readCommittedLexIndexBytes() == expected)
        // The replaced runs are free once the rebase is durable.
        let free = await wax.freeDataRangesForTesting()
        #expect(free.contains { $0.contains(firstBase.bytesOffset) })
        try await wax.verify(deep: true)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        #expect(try await reopened.readCommittedLexIndexBytes() == expected)
        try await reopened.close()
    }
}

@Test func theRunCountIsCapped() async throws {
    try await TempFiles.withTempFile { url in
        let pages = 4 * Wax.maxLexRuns + 8
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: pages), docCount: 0)
        try await wax.commit()
        var versions: [Int: Int] = [:]
        var counts: [Int] = []
        for round in 1...Wax.maxLexRuns {
            versions[0] = round
            try await wax.stageLexIndexForNextCommit(bytes: image(pages: pages, versions: versions), docCount: UInt64(round))
            try await wax.commit()
            counts.append(try #require(await wax.committedLexIndexManifest()).runs.count)
        }
        #expect(counts.max() == Wax.maxLexRuns)
        #expect(counts.last == 1)
        #expect(try await wax.readCommittedLexIndexBytes() == image(pages: pages, versions: versions))
        try await wax.close()
    }
}

@Test func anImageThatChangesEveryPageIsCommittedAsABase() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 8), docCount: 0)
        try await wax.commit()
        let next = image(pages: 8, versions: Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, 1) }))
        try await wax.stageLexIndexForNextCommit(bytes: next, docCount: 1)
        try await wax.commit()
        let manifest = try #require(await wax.committedLexIndexManifest())
        #expect(manifest.runs.count == 1)
        #expect(await lexCatalogEntries(wax).count == 1)
        #expect(try await wax.readCommittedLexIndexBytes() == next)
        try await wax.close()
    }
}

// MARK: - Verification

@Test func verifyCatchesACorruptLexDeltaRun() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 16), docCount: 0)
        try await wax.commit()
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 16, versions: [5: 1]), docCount: 1)
        try await wax.commit()
        let delta = try #require(await wax.committedLexIndexManifest()?.runs.last)
        try await wax.verify(deep: true)
        try await wax.close()

        try flipByte(at: delta.bytesOffset + delta.bytesLength - 1, of: url)
        let reopened = try await Wax.open(at: url)
        try await reopened.verify(deep: false)
        await #expect(throws: WaxError.self) { try await reopened.verify(deep: true) }
        await #expect(throws: WaxError.self) { _ = try await reopened.readCommittedLexIndexBytes() }
        // The next stage cannot read the committed image, so it writes a fresh base.
        let healed = image(pages: 16, versions: [5: 2])
        try await reopened.stageLexIndexForNextCommit(bytes: healed, docCount: 2)
        try await reopened.commit()
        #expect(try #require(await reopened.committedLexIndexManifest()).runs.count == 1)
        #expect(try await reopened.readCommittedLexIndexBytes() == healed)
        try await reopened.verify(deep: true)
        try await reopened.close()
    }
}

/// A stage that cannot read the committed runs writes a fresh base, which replaces them, and
/// records that it could not: a corrupt chain heals, but not silently.
@Test func aStageThatCannotReadACorruptBaseRecordsItAndWritesABase() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 16), docCount: 0)
        try await wax.commit()
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 16, versions: [5: 1]), docCount: 1)
        try await wax.commit()
        let base = try #require(await wax.committedLexIndexManifest()?.runs.first)
        try await wax.close()

        try flipByte(at: base.bytesOffset + 10, of: url)
        let reopened = try await Wax.open(at: url)
        await #expect(throws: WaxError.self) { try await reopened.verify(deep: true) }
        #expect(await reopened.committedLexReadFailuresForTesting() == 0)
        let healed = image(pages: 16, versions: [5: 2])
        try await reopened.stageLexIndexForNextCommit(bytes: healed, docCount: 2)
        #expect(await reopened.committedLexReadFailuresForTesting() == 1)
        try await reopened.commit()
        #expect(try #require(await reopened.committedLexIndexManifest()).runs.count == 1)
        #expect(try await reopened.readCommittedLexIndexBytes() == healed)
        try await reopened.verify(deep: true)
        try await reopened.close()
    }
}

/// Reading the committed image hashes its pages only when this handle has no fingerprints
/// for its runs; a commit hands over the fingerprints of the image it made committed.
@Test func readingTheCommittedImageHashesItOnlyForRunsItHasNotSeen() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 16), docCount: 0)
        try await wax.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        _ = try await reopened.readCommittedLexIndexBytes()
        _ = try await reopened.readCommittedLexIndexBytes()
        #expect(await reopened.lexFingerprintBuildsForTesting() == 1)
        let next = image(pages: 16, versions: [2: 1])
        try await reopened.stageLexIndexForNextCommit(bytes: next, docCount: 1)
        try await reopened.commit()
        #expect(try await reopened.readCommittedLexIndexBytes() == next)
        #expect(await reopened.lexFingerprintBuildsForTesting() == 1)
        try await reopened.close()
    }
}

/// The first delta on a base may change the page size (a v2 blob adopted without one, or a
/// base staged without a SQLite header); later deltas keep it, and an image with another
/// page size then needs a base.
@Test func theFirstDeltaOnABaseMayChangeThePageSize() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let base = image(pages: 32)
        var next = base
        next.replaceSubrange(0..<16, with: Data("SQLite format 3\u{0}".utf8))
        next.replaceSubrange(16..<18, with: [0x20, 0x00])
        next[5 * 8192 + 3] ^= 0xFF
        try await wax.stageLexIndexForNextCommit(bytes: base, docCount: 0)
        try await wax.commit()
        try await wax.stageLexIndexForNextCommit(bytes: next, docCount: 1)
        try await wax.commit()
        let manifest = try #require(await wax.committedLexIndexManifest())
        #expect(manifest.runs.count == 2)
        #expect(manifest.pageSize == 8192)
        #expect(manifest.runs[1].bytesLength == UInt64(LexRunCodec.headerSize + 2 * (4 + 8192)), "pages 0 and 5 of 8 KiB")
        #expect(try await wax.readCommittedLexIndexBytes() == next)
        try await wax.verify(deep: true)

        var third = next
        third[9 * 8192] ^= 0x01
        try await wax.stageLexIndexForNextCommit(bytes: third, docCount: 2)
        try await wax.commit()
        #expect(try #require(await wax.committedLexIndexManifest()).runs.count == 3)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        #expect(try await reopened.readCommittedLexIndexBytes() == third)
        try await reopened.verify(deep: true)
        try await reopened.stageLexIndexForNextCommit(bytes: base, docCount: 3)
        try await reopened.commit()
        let rebased = try #require(await reopened.committedLexIndexManifest())
        #expect(rebased.runs.count == 1)
        #expect(rebased.pageSize == 4096)
        #expect(try await reopened.readCommittedLexIndexBytes() == base)
        try await reopened.close()
    }
}

/// An image that loses whole pages from its end commits a delta of no pages, which only
/// truncates the image.
@Test func anImageThatShrinksToAPageBoundaryCommitsATruncatingDelta() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        try await wax.stageLexIndexForNextCommit(bytes: image(pages: 40), docCount: 0)
        try await wax.commit()
        let shrunk = image(pages: 32)
        try await wax.stageLexIndexForNextCommit(bytes: shrunk, docCount: 1)
        try await wax.commit()
        let manifest = try #require(await wax.committedLexIndexManifest())
        #expect(manifest.runs.count == 2)
        #expect(manifest.runs[1].bytesLength == UInt64(LexRunCodec.headerSize))
        #expect(manifest.imageLength == UInt64(32 * pageSize))
        #expect(try await wax.readCommittedLexIndexBytes() == shrunk)
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        #expect(try await reopened.readCommittedLexIndexBytes() == shrunk)
        try await reopened.verify(deep: true)
        try await reopened.close()
    }
}

// MARK: - Format version

@Test func aCommitMakesAV2StoreFormatThreePointOne() async throws {
    let url = try await copyMigrationFixture(named: "migration-n-1")
    defer { try? FileManager.default.removeItem(at: url) }
    let before = try headerFormatVersions(url)
    let wax = try await Wax.open(at: url)
    _ = try await wax.put(Data("next".utf8))
    try await wax.commit()
    try await wax.close()
    #expect(before != [0x0301, 0x0301])
    #expect(try headerFormatVersions(url) == [0x0301, 0x0301])
}
