import Foundation
import Testing
@testable import WaxCore

@Test func openRejectsCommittedTocWithInvalidPayloadRanges() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let walSize: UInt64 = 1024
    let walOffset = Constants.walOffset
    let dataStart = walOffset + walSize

    var toc = WaxTOC.emptyV1()
    toc.frames = [
        FrameMeta(
            id: 0,
            timestamp: 123,
            payloadOffset: 0, // invalid (below dataStart)
            payloadLength: 1,
            checksum: Data(repeating: 0xAA, count: 32),
            canonicalEncoding: .plain,
            canonicalLength: nil,
            storedChecksum: Data(repeating: 0xBB, count: 32)
        )
    ]

    let tocBytes = try toc.encode()
    let tocChecksum = Data(tocBytes.suffix(32))

    let tocOffset = dataStart
    let footerOffset = tocOffset + UInt64(tocBytes.count)
    let footer = WaxFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocChecksum,
        generation: 0,
        walCommittedSeq: 0
    )

    let file = try FDFile.create(at: url)
    defer { try? file.close() }

    try file.writeAll(tocBytes, at: tocOffset)
    try file.writeAll(try footer.encode(), at: footerOffset)
    try file.fsync()

    let headerA = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 0,
        footerOffset: footerOffset,
        walOffset: walOffset,
        walSize: walSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: tocChecksum
    )
    let pageABytes = try headerA.encodeWithChecksum()
    try file.writeAll(pageABytes, at: 0)

    var headerB = headerA
    headerB.headerPageGeneration = 0
    let pageBBytes = try headerB.encodeWithChecksum()
    try file.writeAll(pageBBytes, at: Constants.headerPageSize)
    try file.fsync()

    do {
        _ = try await Wax.open(at: url)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func openRejectsIndexManifestMissingSegmentCatalogEntry() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let walSize: UInt64 = 1024
    let walOffset = Constants.walOffset
    let dataStart = walOffset + walSize

    var toc = WaxTOC.emptyV1()
    toc.indexes.lex = LexIndexManifest(
        docCount: 0,
        bytesOffset: dataStart,
        bytesLength: 1,
        checksum: Data(repeating: 0xAA, count: 32),
        version: 1
    )
    toc.segmentCatalog = SegmentCatalog(entries: []) // missing matching lex segment entry

    let tocBytes = try toc.encode()
    let tocChecksum = Data(tocBytes.suffix(32))

    let tocOffset = dataStart
    let footerOffset = tocOffset + UInt64(tocBytes.count)
    let footer = WaxFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocChecksum,
        generation: 0,
        walCommittedSeq: 0
    )

    let file = try FDFile.create(at: url)
    defer { try? file.close() }

    try file.writeAll(tocBytes, at: tocOffset)
    try file.writeAll(try footer.encode(), at: footerOffset)
    try file.fsync()

    let headerA = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 0,
        footerOffset: footerOffset,
        walOffset: walOffset,
        walSize: walSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: tocChecksum
    )
    let pageABytes = try headerA.encodeWithChecksum()
    try file.writeAll(pageABytes, at: 0)

    var headerB = headerA
    headerB.headerPageGeneration = 0
    let pageBBytes = try headerB.encodeWithChecksum()
    try file.writeAll(pageBBytes, at: Constants.headerPageSize)
    try file.fsync()

    do {
        _ = try await Wax.open(at: url)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}
