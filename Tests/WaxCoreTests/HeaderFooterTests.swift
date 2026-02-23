import Foundation
import Testing
@testable import WaxCore

private let testFooterOffset: UInt64 = Constants.walOffset + Constants.defaultWalSize + 4096

@Test func headerPageEncodeDecodeWithChecksum() throws {
    let header = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 5,
        footerOffset: testFooterOffset,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 1024,
        walCheckpointPos: 512,
        walCommittedSeq: 42,
        tocChecksum: Data(repeating: 0xAB, count: 32)
    )

    let encoded = try header.encodeWithChecksum()
    #expect(encoded.count == WaxHeaderPage.size)

    let decoded = try WaxHeaderPage.decodeWithChecksumValidation(from: encoded)
    #expect(decoded.footerOffset == header.footerOffset)
    #expect(decoded.walSize == header.walSize)
    #expect(decoded.walCommittedSeq == header.walCommittedSeq)
    #expect(decoded.tocChecksum == header.tocChecksum)
}

@Test func headerReplaySnapshotRoundtrip() throws {
    let snapshot = WaxHeaderPage.WALReplaySnapshot(
        fileGeneration: 9,
        walCommittedSeq: 42,
        footerOffset: testFooterOffset,
        walWritePos: 1234,
        walCheckpointPos: 1234,
        walPendingBytes: 0,
        walLastSequence: 42
    )
    let header = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 9,
        footerOffset: testFooterOffset,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 1234,
        walCheckpointPos: 1234,
        walCommittedSeq: 42,
        walReplaySnapshot: snapshot,
        tocChecksum: Data(repeating: 0xAB, count: 32)
    )

    let encoded = try header.encodeWithChecksum()
    let decoded = try WaxHeaderPage.decodeWithChecksumValidation(from: encoded)
    #expect(decoded.walReplaySnapshot == snapshot)
}

@Test func headerChecksumDetectsCorruption() throws {
    let header = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 0,
        footerOffset: testFooterOffset,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: Data(repeating: 0x00, count: 32)
    )
    var encoded = try header.encodeWithChecksum()
    encoded[200] ^= 0xFF

    do {
        _ = try WaxHeaderPage.decodeWithChecksumValidation(from: encoded)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .checksumMismatch = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func rejectsInvalidMagic() throws {
    var data = Data(repeating: 0, count: WaxHeaderPage.size)
    data.replaceSubrange(0..<4, with: Data([0x42, 0x41, 0x44, 0x21])) // "BAD!"

    do {
        _ = try WaxHeaderPage.decodeWithChecksumValidation(from: data)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidHeader(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("magic"))
    }
}

@Test func rejectsUnsupportedFormatVersionOnEncode() throws {
    let header = WaxHeaderPage(
        formatVersion: 0x0101,
        specMajor: 1,
        specMinor: 1,
        headerPageGeneration: 1,
        fileGeneration: 0,
        footerOffset: testFooterOffset,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: Data(repeating: 0x00, count: 32)
    )

    do {
        _ = try header.encodeWithChecksum()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidHeader(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("format_version"))
    }
}

@Test func selectValidPageChoosesHigherGeneration() throws {
    let a = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 0,
        footerOffset: testFooterOffset,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: Data(repeating: 0x00, count: 32)
    )
    let b = WaxHeaderPage(
        headerPageGeneration: 2,
        fileGeneration: 0,
        footerOffset: testFooterOffset + 10_000,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: Data(repeating: 0x00, count: 32)
    )

    let pageA = try a.encodeWithChecksum()
    let pageB = try b.encodeWithChecksum()

    let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB)
    #expect(selected != nil)
    #expect(selected?.pageIndex == 1)
    #expect(selected?.page.footerOffset == testFooterOffset + 10_000)
}

@Test func footerRoundtrip() throws {
    let footer = WaxFooter(
        tocLen: 12345,
        tocHash: Data(repeating: 0xCD, count: 32),
        generation: 99,
        walCommittedSeq: 50
    )

    let encoded = try footer.encode()
    #expect(encoded.count == WaxFooter.size)
    #expect(Data(encoded[0..<8]) == Constants.footerMagic)

    let decoded = try WaxFooter.decode(from: encoded)
    #expect(decoded == footer)
}

@Test func footerTocHashValidation() throws {
    let tocBody = Data("Sample TOC content".utf8)
    let zero32 = Data(repeating: 0, count: 32)
    let tocChecksum = SHA256Checksum.digest(tocBody + zero32)

    var tocBytes = Data()
    tocBytes.append(tocBody)
    tocBytes.append(tocChecksum)

    let footer = WaxFooter(
        tocLen: UInt64(tocBytes.count),
        tocHash: tocChecksum,
        generation: 1,
        walCommittedSeq: 0
    )

    #expect(footer.hashMatches(tocBytes: tocBytes))

    var corrupted = tocBytes
    corrupted[0] ^= 0xFF
    #expect(!footer.hashMatches(tocBytes: corrupted))
}

@Test func rejectsInvalidFooterMagic() throws {
    var data = Data(count: WaxFooter.size)
    data.replaceSubrange(0..<8, with: Data("BADMAGIC".utf8))

    do {
        _ = try WaxFooter.decode(from: data)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidFooter(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("magic"))
    }
}

@Test func footerEncodingIsStable() throws {
    let footer = WaxFooter(
        tocLen: 0x1122334455667788,
        tocHash: Data(repeating: 0xAA, count: 32),
        generation: 0x0102030405060708,
        walCommittedSeq: 0x8877665544332211
    )

    var expected = Data()
    expected.append(Constants.footerMagic)
    expected.append(contentsOf: UInt64(0x1122334455667788).littleEndianBytes)
    expected.append(Data(repeating: 0xAA, count: 32))
    expected.append(contentsOf: UInt64(0x0102030405060708).littleEndianBytes)
    expected.append(contentsOf: UInt64(0x8877665544332211).littleEndianBytes)

    #expect(expected.count == WaxFooter.size)
    #expect(try footer.encode() == expected)
}

@Test func headerEncodingIsStable() throws {
    let header = WaxHeaderPage(
        headerPageGeneration: 0x0102030405060708,
        fileGeneration: 0x1112131415161718,
        footerOffset: 0x2122232425262728,
        walOffset: Constants.walOffset,
        walSize: 0x3132333435363738,
        walWritePos: 0x4142434445464748,
        walCheckpointPos: 0x5152535455565758,
        walCommittedSeq: 0x6162636465666768,
        tocChecksum: Data(repeating: 0xBB, count: 32)
    )

    var expected = Data(repeating: 0, count: WaxHeaderPage.size)
    expected.replaceSubrange(0..<4, with: Constants.magic)
    expected.replaceSubrange(4..<6, with: Data([0x00, 0x01])) // 0x0100 LE
    expected[6] = Constants.specMajor
    expected[7] = Constants.specMinor

    expected.replaceSubrange(8..<16, with: UInt64(0x0102030405060708).littleEndianData)
    expected.replaceSubrange(16..<24, with: UInt64(0x1112131415161718).littleEndianData)
    expected.replaceSubrange(24..<32, with: UInt64(0x2122232425262728).littleEndianData)
    expected.replaceSubrange(32..<40, with: UInt64(Constants.walOffset).littleEndianData)
    expected.replaceSubrange(40..<48, with: UInt64(0x3132333435363738).littleEndianData)
    expected.replaceSubrange(48..<56, with: UInt64(0x4142434445464748).littleEndianData)
    expected.replaceSubrange(56..<64, with: UInt64(0x5152535455565758).littleEndianData)
    expected.replaceSubrange(64..<72, with: UInt64(0x6162636465666768).littleEndianData)
    expected.replaceSubrange(72..<104, with: Data(repeating: 0xBB, count: 32))

    // header_checksum is SHA256 over the full 4096 bytes with checksum field zeroed.
    let checksum = SHA256Checksum.digest(expected)
    expected.replaceSubrange(104..<136, with: checksum)

    #expect(try header.encodeWithChecksum() == expected)
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian, Array.init)
    }
}

private extension UInt64 {
    var littleEndianData: Data {
        var le = self.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
}
