import Foundation
import Testing
@testable import WaxCore

// MARK: - In-memory buffer scanning

@Test func footerScannerFindsNothingInEmptyBuffer() {
    let result = FooterScanner.findLastValidFooter(in: Data())
    #expect(result == nil)
}

@Test func footerScannerFindsNothingInShortBuffer() {
    // Less than one footer-size worth of bytes
    let tinyBuffer = Data(repeating: 0x00, count: 4)
    let result = FooterScanner.findLastValidFooter(in: tinyBuffer)
    #expect(result == nil)
}

@Test func footerScannerFindsNothingInAllZeroBuffer() {
    let zeros = Data(repeating: 0x00, count: 4096)
    let result = FooterScanner.findLastValidFooter(in: zeros)
    #expect(result == nil)
}

@Test func footerScannerSkipsFooterWithHashMismatch() throws {
    // Build a valid TOC+footer structure, then corrupt the hash
    var toc = MV2STOC.emptyV1()
    let tocBytes = try toc.encode()

    // Build a footer with a deliberately wrong hash
    let badHash = Data(repeating: 0xAB, count: 32)
    let footer = MV2SFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: badHash,
        generation: 1,
        walCommittedSeq: 0
    )
    let footerBytes = try footer.encode()

    var buffer = tocBytes
    buffer.append(footerBytes)

    // Scanner must reject this because the stored toc_hash is corrupt
    let result = FooterScanner.findLastValidFooter(in: buffer)
    #expect(result == nil)
}

@Test func footerScannerSelectsHigherGenerationFooter() throws {
    // Build two valid TOC/footer pairs with different generations
    var toc = MV2STOC.emptyV1()
    let tocBytes = try toc.encode()
    let tocHash = Data(tocBytes.suffix(32))

    let footer0 = MV2SFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocHash,
        generation: 0,
        walCommittedSeq: 0
    )
    let footer1 = MV2SFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocHash,
        generation: 1,
        walCommittedSeq: 0
    )

    let footerBytes0 = try footer0.encode()
    let footerBytes1 = try footer1.encode()

    // Layout: [toc][footer0][toc][footer1]
    var buffer = Data()
    buffer.append(tocBytes)
    buffer.append(footerBytes0)
    buffer.append(tocBytes)
    buffer.append(footerBytes1)

    let result = FooterScanner.findLastValidFooter(in: buffer)
    #expect(result != nil)
    #expect(result?.footer.generation == 1)
}

@Test func footerScannerRespectsMaxFooterScanBytes() throws {
    // Put a valid footer at the very beginning of a larger buffer,
    // then set maxFooterScanBytes so small that it cannot reach the footer.
    var toc = MV2STOC.emptyV1()
    let tocBytes = try toc.encode()
    let tocHash = Data(tocBytes.suffix(32))

    let footer = MV2SFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocHash,
        generation: 42,
        walCommittedSeq: 0
    )
    let footerBytes = try footer.encode()

    // Place the valid footer very early, then pad heavily after it
    var buffer = Data()
    buffer.append(tocBytes)
    buffer.append(footerBytes)
    let padding = Data(repeating: 0xFF, count: 8192)
    buffer.append(padding)

    // With a tiny scan window the footer should NOT be found
    var tinyLimits = FooterScanner.Limits()
    tinyLimits.maxFooterScanBytes = 16
    let missResult = FooterScanner.findLastValidFooter(in: buffer, limits: tinyLimits)
    #expect(missResult == nil)

    // With a full scan window it should be found
    let fullResult = FooterScanner.findLastValidFooter(in: buffer)
    #expect(fullResult != nil)
    #expect(fullResult?.footer.generation == 42)
}

@Test func footerScannerSameGenerationPreferHigherOffset() throws {
    var toc = MV2STOC.emptyV1()
    let tocBytes = try toc.encode()
    let tocHash = Data(tocBytes.suffix(32))

    // Both footers carry generation=5; the one at the higher file offset wins
    let footer = MV2SFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocHash,
        generation: 5,
        walCommittedSeq: 0
    )
    let footerBytes = try footer.encode()

    // Layout: [toc][footer][toc][footer] — second footer is at higher offset
    var buffer = Data()
    buffer.append(tocBytes)
    buffer.append(footerBytes)
    buffer.append(tocBytes)
    let secondFooterOffset = buffer.count
    buffer.append(footerBytes)

    let result = FooterScanner.findLastValidFooter(in: buffer)
    #expect(result != nil)
    #expect(result?.footerOffset == UInt64(secondFooterOffset))
}

// MARK: - File-based scanning

@Test func footerScannerFileScanMatchesInMemory() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("hello".utf8))
    try await wax.commit()
    try await wax.close()

    let fileResult = try FooterScanner.findLastValidFooter(in: url)
    #expect(fileResult != nil)

    let fileData = try Data(contentsOf: url)
    let memResult = FooterScanner.findLastValidFooter(in: fileData)
    #expect(memResult != nil)

    #expect(fileResult?.footer.generation == memResult?.footer.generation)
    #expect(fileResult?.footer.tocHash == memResult?.footer.tocHash)
    #expect(fileResult?.footerOffset == memResult?.footerOffset)
}

@Test func footerScannerFindFooterAtExactOffsetSucceeds() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.commit()
    try await wax.close()

    // Retrieve the footer offset from the header
    let file = try FDFile.openReadOnly(at: url)
    defer { try? file.close() }
    let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
    let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
    let selected = try #require(MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB))
    let footerOffset = selected.page.footerOffset

    let footerSlice = try FooterScanner.findFooter(at: footerOffset, in: url)
    #expect(footerSlice != nil)
    #expect(footerSlice?.footerOffset == footerOffset)
}

@Test func footerScannerFindFooterAtInvalidOffsetReturnsNil() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.close()

    // Offset beyond end of file → should return nil, not throw
    let fileSize = try {
        let f = try FDFile.openReadOnly(at: url)
        defer { try? f.close() }
        return try f.size()
    }()

    let result = try FooterScanner.findFooter(at: fileSize + 1024, in: url)
    #expect(result == nil)
}

@Test func footerScannerMaxTocBytesTruncatesLargeEntry() throws {
    var toc = MV2STOC.emptyV1()
    let tocBytes = try toc.encode()
    let tocHash = Data(tocBytes.suffix(32))

    let footer = MV2SFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocHash,
        generation: 7,
        walCommittedSeq: 0
    )
    let footerBytes = try footer.encode()

    var buffer = Data()
    buffer.append(tocBytes)
    buffer.append(footerBytes)

    // Restrict maxTocBytes so the valid toc is too large to accept
    var limits = FooterScanner.Limits()
    limits.maxTocBytes = UInt64(tocBytes.count) - 1
    let result = FooterScanner.findLastValidFooter(in: buffer, limits: limits)
    #expect(result == nil)
}

@Test func footerScannerIgnoresFooterWhoseTocExceedsBlobStart() throws {
    // A footer claiming tocLen > its own offset must be rejected
    var toc = MV2STOC.emptyV1()
    let tocBytes = try toc.encode()
    let tocHash = Data(tocBytes.suffix(32))

    // Footer claims toc is enormous — more bytes than exist before it
    let hugeTocLen = UInt64(tocBytes.count) + 999_999
    let footer = MV2SFooter(
        tocLen: hugeTocLen,
        tocHash: tocHash,
        generation: 0,
        walCommittedSeq: 0
    )
    let footerBytes = try footer.encode()

    var buffer = Data()
    buffer.append(tocBytes)
    buffer.append(footerBytes)

    let result = FooterScanner.findLastValidFooter(in: buffer)
    #expect(result == nil)
}

@Test func footerScannerMultipleGenerationsPicksHighest() throws {
    var toc = MV2STOC.emptyV1()
    let tocBytes = try toc.encode()
    let tocHash = Data(tocBytes.suffix(32))

    var buffer = Data()
    var expectedOffset: Int = 0

    // Write 3 generations, each at incrementing generation numbers
    for gen in UInt64(0)..<3 {
        let footer = MV2SFooter(
            tocLen: UInt64(tocBytes.count),
            tocHash: tocHash,
            generation: gen,
            walCommittedSeq: gen
        )
        let footerBytes = try footer.encode()
        buffer.append(tocBytes)
        // Record offset of the highest-gen footer
        if gen == 2 {
            expectedOffset = buffer.count
        }
        buffer.append(footerBytes)
    }

    let result = FooterScanner.findLastValidFooter(in: buffer)
    #expect(result != nil)
    #expect(result?.footer.generation == 2)
    #expect(result?.footerOffset == UInt64(expectedOffset))
}
