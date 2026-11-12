import Foundation
import Testing
@testable import WaxCore

/// A TOC above the parallel-decode threshold, so the overlapped decode also fans out.
private func largeToc() -> WaxTOC {
    var toc = WaxTOC.emptyV1()
    var frames: [FrameMeta] = []
    for index in 0..<(WaxTOC.parallelFrameDecodeThreshold + 7) {
        let id = UInt64(index)
        let timestamp: Int64 = 1_700_000_000_000 + Int64(index)
        let payloadOffset: UInt64 = 9_216 + id * 16
        let checksum = Data(repeating: UInt8(index % 251), count: 32)
        let metadata = Metadata(["doc_id": String(index)])
        let frame = FrameMeta(
            id: id,
            timestamp: timestamp,
            payloadOffset: payloadOffset,
            payloadLength: 16,
            checksum: checksum,
            canonicalEncoding: .plain,
            storedChecksum: Data(repeating: 0xBB, count: 32),
            metadata: metadata,
            searchText: "passage \(index)"
        )
        frames.append(frame)
    }
    toc.frames = frames
    return toc
}

/// Writes `tocBytes` then a footer whose hash is `tocBytes`' stamped checksum, and returns the
/// footer offset.
private func writeTocAndFooter(_ tocBytes: Data, to url: URL) throws -> UInt64 {
    let footer = WaxFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: Data(tocBytes.suffix(32)),
        generation: 3,
        walCommittedSeq: 2
    )
    try (tocBytes + footer.encode()).write(to: url)
    return UInt64(tocBytes.count)
}

@Test func footerReadDecodingTheTocMatchesFindFooterThenDecode() throws {
    let toc = largeToc()
    try TempFiles.withTempFile { url in
        let footerOffset = try writeTocAndFooter(try toc.encode(), to: url)
        let plain = try #require(try FooterScanner.findFooter(at: footerOffset, in: url))
        let read = try #require(try FooterScanner.findFooterDecodingToc(at: footerOffset, in: url))
        #expect(read.slice == plain)
        #expect(read.toc == (try WaxTOC.decode(from: plain)))
        #expect(read.toc?.frames == toc.frames)
    }
}

@Test func footerReadDecodingTheTocRejectsATocItsHashDoesNotMatch() throws {
    var bytes = try largeToc().encode()
    let footerHash = Data(bytes.suffix(32))
    bytes[bytes.count / 2] ^= 0xFF // body changed, stamped checksum kept
    let footer = WaxFooter(tocLen: UInt64(bytes.count), tocHash: footerHash, generation: 3, walCommittedSeq: 2)
    try TempFiles.withTempFile { url in
        try (bytes + footer.encode()).write(to: url)
        let footerOffset = UInt64(bytes.count)
        #expect(try FooterScanner.findFooter(at: footerOffset, in: url) == nil)
        #expect(try FooterScanner.findFooterDecodingToc(at: footerOffset, in: url) == nil)
    }
}

/// A TOC whose hash matches but whose body does not decode comes back without a TOC, and
/// decoding its slice again throws the decode's error.
@Test func footerReadDecodingTheTocLeavesAnUndecodableTocToTheCaller() throws {
    var bytes = try WaxTOC.emptyV1().encode()
    bytes[0] = 2 // toc_version
    bytes.replaceSubrange((bytes.count - 32)..<bytes.count, with: WaxTOC.computeChecksum(for: bytes))
    try TempFiles.withTempFile { url in
        let footerOffset = try writeTocAndFooter(bytes, to: url)
        let read = try #require(try FooterScanner.findFooterDecodingToc(at: footerOffset, in: url))
        #expect(read.toc == nil)
        #expect(throws: WaxError.self) { try WaxTOC.decode(from: read.slice) }
    }
}

/// A store with more frames than the parallel-decode threshold reopens with every frame as
/// it committed them.
@Test func storeAboveTheParallelDecodeThresholdReopensWithItsFrames() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url, walSize: 64 * 1024)
        #expect(try await wax.beginFrameImport())
        let count = WaxTOC.parallelFrameDecodeThreshold + 300
        for lower in stride(from: 0, to: count, by: 1_000) {
            let batch = lower..<min(lower + 1_000, count)
            let options: [FrameMetaSubset] = batch.map { index in
                var option = FrameMetaSubset(role: .document, metadata: Metadata(["row": String(index)]))
                option.searchText = "imported frame \(index) ünïcode"
                return option
            }
            _ = try await wax.importFrames(batch.map { Data("payload \($0)".utf8) }, options: options)
        }
        try await wax.commitFrameImport()
        let committed = await wax.frameMetas()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let frames = await reopened.frameMetas()
        try await reopened.close()
        #expect(frames.count == count)
        #expect(frames == committed)
    }
}
