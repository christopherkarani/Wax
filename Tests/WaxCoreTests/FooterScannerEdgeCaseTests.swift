import Foundation
import Testing
@testable import WaxCore

// MARK: - Helpers

/// Builds a well-formed TOC byte block whose embedded SHA-256 checksum matches
/// the Wax v1 scheme: SHA256(body + zero32) stamped into the final 32 bytes.
private func makeValidTocBytes(bodyContent: Data = Data("toc-body".utf8)) -> Data {
    // Pad body so that total length >= 32 (the checksum occupies the last 32 bytes).
    var body = bodyContent
    if body.count < 1 { body = Data(repeating: 0xAB, count: 1) }

    var hasher = SHA256Checksum()
    body.withUnsafeBytes { hasher.update($0) }
    hasher.update(Data(repeating: 0, count: 32))
    let checksum = hasher.finalize()

    var toc = Data()
    toc.append(body)
    toc.append(checksum)
    return toc
}

/// Builds a valid WaxFooter whose tocHash matches the supplied TOC bytes.
private func makeValidFooter(
    tocBytes: Data,
    generation: UInt64 = 1,
    walCommittedSeq: UInt64 = 0
) throws -> WaxFooter {
    // The footer's tocLen and tocHash must be consistent with the TOC block.
    let checksum = Data(tocBytes.suffix(32))
    return WaxFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: checksum,
        generation: generation,
        walCommittedSeq: walCommittedSeq
    )
}

/// Assembles a complete in-memory buffer:  <toc_bytes> <encoded_footer>
private func makeBuffer(tocBytes: Data, footer: WaxFooter) throws -> Data {
    var buf = Data()
    buf.append(tocBytes)
    buf.append(try footer.encode())
    return buf
}

// MARK: - In-memory scan (findLastValidFooter in bytes:)

@Test func footerScannerInMemoryNoValidFooter_tooSmall() {
    // Buffer smaller than a footer should return nil immediately.
    let tiny = Data(repeating: 0, count: WaxFooter.size - 1)
    let result = FooterScanner.findLastValidFooter(in: tiny)
    #expect(result == nil)
}

@Test func footerScannerInMemoryNoValidFooter_allZeroes() {
    // A correctly-sized buffer with no magic bytes should yield nil.
    let buf = Data(repeating: 0, count: WaxFooter.size * 4)
    let result = FooterScanner.findLastValidFooter(in: buf)
    #expect(result == nil)
}

@Test func footerScannerInMemoryRejectsTocTooShort() throws {
    // tocLen < 32 guard: create a footer that claims tocLen = 10.
    let fakeTocHash = Data(repeating: 0xAA, count: 32)
    let footer = WaxFooter(tocLen: 10, tocHash: fakeTocHash, generation: 1, walCommittedSeq: 0)
    var buf = Data(repeating: 0, count: 10)
    buf.append(try footer.encode())
    let result = FooterScanner.findLastValidFooter(in: buf)
    #expect(result == nil)
}

@Test func footerScannerInMemoryRejectsTocExceedingLimit() throws {
    // tocLen > maxTocBytes guard: craft a footer that claims an enormous TOC.
    let fakeTocHash = Data(repeating: 0xBB, count: 32)
    // We won't actually supply tocLen bytes; the magic will be found but
    // tocLen > limits.maxTocBytes should gate before we attempt any slice.
    let footer = WaxFooter(
        tocLen: Constants.maxTocBytes + 1,
        tocHash: fakeTocHash,
        generation: 1,
        walCommittedSeq: 0
    )
    // Buffer must be large enough to hold the footer itself.
    var buf = Data(repeating: 0, count: WaxFooter.size)
    // Overwrite the start with valid footer bytes so the magic is present at offset 0.
    let encoded = try footer.encode()
    buf.replaceSubrange(0..<encoded.count, with: encoded)
    let result = FooterScanner.findLastValidFooter(in: buf)
    #expect(result == nil)
}

@Test func footerScannerInMemoryRejectsTocLargerThanPosition() throws {
    // tocLen > pos guard: footer at position 0 but claims toc precedes it.
    let tocBytes = makeValidTocBytes()
    let footer = try makeValidFooter(tocBytes: tocBytes)
    // Build a buffer that has fewer leading bytes than tocLen.
    // Put the footer at the very start – there is no room for the TOC before it.
    let footerBytes = try footer.encode()
    // We need the magic at pos=0, but tocLen > 0 means tocOffset would be negative.
    let result = FooterScanner.findLastValidFooter(in: footerBytes)
    #expect(result == nil)
}

@Test func footerScannerInMemoryRejectsHashMismatch() throws {
    // Supply valid TOC bytes then tamper with the body before building the footer.
    let tocBytes = makeValidTocBytes()
    // Build footer with the correct checksum, then corrupt the TOC body.
    let footer = try makeValidFooter(tocBytes: tocBytes)
    var corruptedToc = tocBytes
    corruptedToc[0] ^= 0xFF // flip one byte – checksum will not match
    var buf = Data()
    buf.append(corruptedToc)
    buf.append(try footer.encode())
    let result = FooterScanner.findLastValidFooter(in: buf)
    #expect(result == nil)
}

@Test func footerScannerInMemoryHigherGenerationWins() throws {
    // Two valid footers: higher generation must win regardless of order.
    let toc1 = makeValidTocBytes(bodyContent: Data("toc-gen1".utf8))
    let footer1 = try makeValidFooter(tocBytes: toc1, generation: 1)
    let toc2 = makeValidTocBytes(bodyContent: Data("toc-gen2".utf8))
    let footer2 = try makeValidFooter(tocBytes: toc2, generation: 2)

    // Layout: [toc1][footer1][toc2][footer2]
    var buf = Data()
    buf.append(toc1)
    buf.append(try footer1.encode())
    buf.append(toc2)
    buf.append(try footer2.encode())

    let result = FooterScanner.findLastValidFooter(in: buf)
    let found = try #require(result)
    #expect(found.footer.generation == 2)
}

@Test func footerScannerInMemorySameGenerationHigherOffsetWins() throws {
    // Two valid footers with identical generation: the one at a higher offset wins.
    let toc1 = makeValidTocBytes(bodyContent: Data("toc-a".utf8))
    let footer1 = try makeValidFooter(tocBytes: toc1, generation: 5)
    let toc2 = makeValidTocBytes(bodyContent: Data("toc-b".utf8))
    let footer2 = try makeValidFooter(tocBytes: toc2, generation: 5)

    // footer2 appears later in the buffer, so it has a higher footerOffset.
    var buf = Data()
    buf.append(toc1)
    buf.append(try footer1.encode())
    buf.append(toc2)
    buf.append(try footer2.encode())

    let result = FooterScanner.findLastValidFooter(in: buf)
    let found = try #require(result)
    // The last footer (footer2) should win because it has a higher offset.
    let expectedOffset = UInt64(toc1.count + WaxFooter.size + toc2.count)
    #expect(found.footerOffset == expectedOffset)
    #expect(found.footer.generation == 5)
}

@Test func footerScannerInMemoryHappyPath() throws {
    // Single valid footer at the end of the buffer.
    let toc = makeValidTocBytes(bodyContent: Data("happy-toc".utf8))
    let footer = try makeValidFooter(tocBytes: toc, generation: 3, walCommittedSeq: 7)
    let buf = try makeBuffer(tocBytes: toc, footer: footer)

    let result = FooterScanner.findLastValidFooter(in: buf)
    let found = try #require(result)
    #expect(found.footer.generation == 3)
    #expect(found.footer.walCommittedSeq == 7)
    #expect(found.tocBytes == toc)
    #expect(found.tocOffset == 0)
    #expect(found.footerOffset == UInt64(toc.count))
}

@Test func footerScannerInMemoryCustomLimitsRespected() throws {
    // A valid footer exists but lies outside maxFooterScanBytes; it should not be found.
    let toc = makeValidTocBytes()
    let footer = try makeValidFooter(tocBytes: toc)
    var buf = try makeBuffer(tocBytes: toc, footer: footer)

    // Append enough trailing zeroes so the footer is now outside a tiny scan window.
    let padding = Data(repeating: 0, count: 256)
    buf.append(padding)

    var limits = FooterScanner.Limits()
    limits.maxFooterScanBytes = 16 // footer + toc together are more than 16 bytes
    let result = FooterScanner.findLastValidFooter(in: buf, limits: limits)
    // Footer is outside the scan window; result should be nil.
    #expect(result == nil)
}

// MARK: - File-based scan (findLastValidFooter in fileURL:)

@Test func footerScannerFileBasedHappyPath() throws {
    let toc = makeValidTocBytes(bodyContent: Data("file-toc".utf8))
    let footer = try makeValidFooter(tocBytes: toc, generation: 1, walCommittedSeq: 2)
    let buf = try makeBuffer(tocBytes: toc, footer: footer)

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        let result = try FooterScanner.findLastValidFooter(in: url)
        let found = try #require(result)
        #expect(found.footer.generation == 1)
        #expect(found.footer.walCommittedSeq == 2)
        #expect(found.tocBytes == toc)
    }
}

@Test func footerScannerFileBasedEmptyFile() throws {
    try TempFiles.withTempFile { url in
        // Create a file smaller than WaxFooter.size.
        try Data().write(to: url)
        let result = try FooterScanner.findLastValidFooter(in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFileBasedTooSmall() throws {
    try TempFiles.withTempFile { url in
        let tiny = Data(repeating: 0, count: WaxFooter.size - 1)
        try tiny.write(to: url)
        let result = try FooterScanner.findLastValidFooter(in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFileBasedNoValidFooter() throws {
    try TempFiles.withTempFile { url in
        // File large enough but contains no valid footer magic.
        let junk = Data(repeating: 0x42, count: 256)
        try junk.write(to: url)
        let result = try FooterScanner.findLastValidFooter(in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFileBasedHigherGenerationWins() throws {
    let toc1 = makeValidTocBytes(bodyContent: Data("f-toc1".utf8))
    let footer1 = try makeValidFooter(tocBytes: toc1, generation: 10)
    let toc2 = makeValidTocBytes(bodyContent: Data("f-toc2".utf8))
    let footer2 = try makeValidFooter(tocBytes: toc2, generation: 20)

    var buf = Data()
    buf.append(toc1)
    buf.append(try footer1.encode())
    buf.append(toc2)
    buf.append(try footer2.encode())

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        let result = try FooterScanner.findLastValidFooter(in: url)
        let found = try #require(result)
        #expect(found.footer.generation == 20)
    }
}

// MARK: - findFooter(at:in:) - direct offset lookup

@Test func footerScannerFindFooterAtOffsetHappyPath() throws {
    let toc = makeValidTocBytes(bodyContent: Data("at-offset".utf8))
    let footer = try makeValidFooter(tocBytes: toc, generation: 7, walCommittedSeq: 3)
    let buf = try makeBuffer(tocBytes: toc, footer: footer)
    let expectedFooterOffset = UInt64(toc.count)

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        let result = try FooterScanner.findFooter(at: expectedFooterOffset, in: url)
        let found = try #require(result)
        #expect(found.footerOffset == expectedFooterOffset)
        #expect(found.footer.generation == 7)
        #expect(found.footer.walCommittedSeq == 3)
        #expect(found.tocBytes == toc)
    }
}

@Test func footerScannerFindFooterAtOffsetPastEndOfFile() throws {
    let toc = makeValidTocBytes()
    let footer = try makeValidFooter(tocBytes: toc)
    let buf = try makeBuffer(tocBytes: toc, footer: footer)

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        // Offset past the end of file means footerOffset + footerSize > fileSize.
        let result = try FooterScanner.findFooter(at: UInt64(buf.count) + 100, in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFindFooterAtOffsetBadMagic() throws {
    // A buffer whose bytes at the target offset do not decode as a valid footer.
    let buf = Data(repeating: 0x00, count: WaxFooter.size * 2)

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        let result = try FooterScanner.findFooter(at: 0, in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFindFooterAtOffsetTocTooSmall() throws {
    // Footer decodes correctly but claims tocLen < 32; should return nil.
    let fakeTocHash = Data(repeating: 0xCC, count: 32)
    let footer = WaxFooter(tocLen: 10, tocHash: fakeTocHash, generation: 1, walCommittedSeq: 0)

    // Prefix with 10 placeholder bytes (the "toc"), then the footer.
    var buf = Data(repeating: 0x00, count: 10)
    buf.append(try footer.encode())

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        let footerOffset = UInt64(10)
        let result = try FooterScanner.findFooter(at: footerOffset, in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFindFooterAtOffsetTocExceedsMaxTocBytes() throws {
    let fakeTocHash = Data(repeating: 0xDD, count: 32)
    let footer = WaxFooter(
        tocLen: Constants.maxTocBytes + 1,
        tocHash: fakeTocHash,
        generation: 1,
        walCommittedSeq: 0
    )
    // We only need the footer bytes themselves to exist.
    let footerBytes = try footer.encode()
    // Prepend enough padding that footerOffset >= footer.tocLen is satisfied in theory,
    // but limits.maxTocBytes guard fires first.
    var buf = Data(repeating: 0x00, count: footerBytes.count)
    buf.append(footerBytes)

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        let result = try FooterScanner.findFooter(at: UInt64(footerBytes.count), in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFindFooterAtOffsetFooterOffsetLessThanTocLen() throws {
    // footerOffset < footer.tocLen: tocOffset would underflow; should return nil.
    let toc = makeValidTocBytes()
    let footer = try makeValidFooter(tocBytes: toc)
    // Place the footer at offset 0, but it claims tocLen = toc.count > 0 bytes precede it.
    let footerBytes = try footer.encode()

    try TempFiles.withTempFile { url in
        try footerBytes.write(to: url)
        let result = try FooterScanner.findFooter(at: 0, in: url)
        #expect(result == nil)
    }
}

@Test func footerScannerFindFooterAtOffsetHashMismatch() throws {
    // Footer bytes are valid but the TOC body has been corrupted.
    let toc = makeValidTocBytes(bodyContent: Data("legit".utf8))
    let footer = try makeValidFooter(tocBytes: toc)
    var buf = Data()
    buf.append(toc)
    buf.append(try footer.encode())

    // Corrupt the TOC body.
    buf[0] ^= 0xFF

    try TempFiles.withTempFile { url in
        try buf.write(to: url)
        let result = try FooterScanner.findFooter(at: UInt64(toc.count), in: url)
        #expect(result == nil)
    }
}
