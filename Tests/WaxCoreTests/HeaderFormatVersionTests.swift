import Foundation
import Testing
@testable import WaxCore

private let checksumRange = 104..<136
private let futureFormatVersion = Constants.specVersion &+ 0x0100

/// Rewrites `page` with `formatVersion` (and matching spec major/minor) and a valid checksum,
/// as a different Wax version would have written it.
private func rewriteFormatVersion(_ page: Data, to formatVersion: UInt16) -> Data {
    var bytes = page
    bytes[bytes.startIndex + 4] = UInt8(truncatingIfNeeded: formatVersion)
    bytes[bytes.startIndex + 5] = UInt8(truncatingIfNeeded: formatVersion >> 8)
    bytes[bytes.startIndex + 6] = UInt8(truncatingIfNeeded: formatVersion >> 8)
    bytes[bytes.startIndex + 7] = UInt8(truncatingIfNeeded: formatVersion)
    bytes.replaceSubrange(checksumRange, with: Data(repeating: 0, count: checksumRange.count))
    let checksum = SHA256Checksum.digest(bytes)
    bytes.replaceSubrange(checksumRange, with: checksum)
    return bytes
}

private func makeHeaderPage() throws -> Data {
    let header = WaxHeaderPage(
        headerPageGeneration: 1,
        fileGeneration: 1,
        footerOffset: Constants.walOffset + Constants.defaultWalSize + 4096,
        walOffset: Constants.walOffset,
        walSize: Constants.defaultWalSize,
        walWritePos: 0,
        walCheckpointPos: 0,
        walCommittedSeq: 0,
        tocChecksum: Data(repeating: 0, count: 32)
    )
    return try header.encodeWithChecksum()
}

/// A committed store whose unselected header page is rewritten as a future format version,
/// while the selected page stays valid at this build's version.
private func makeStoreWithFutureFormatOtherPage() async throws -> URL {
    let url = TempFiles.uniqueURL()
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    _ = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
    try await wax.commit()
    try await wax.close()

    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
    let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
    let selected = try #require(try WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB))
    let otherIndex = 1 - selected.pageIndex
    let selectedBytes = selected.pageIndex == 0 ? pageA : pageB
    let future = rewriteFormatVersion(selectedBytes, to: futureFormatVersion)
    try file.writeAll(future, at: UInt64(otherIndex) * Constants.headerPageSize)
    try file.fsync()
    return url
}

@Test
func headerSelectionRejectsIntactPageWithUnsupportedFormatVersion() throws {
    #expect(!Constants.supportedSpecVersions.contains(futureFormatVersion))
    let current = try makeHeaderPage()
    let future = rewriteFormatVersion(current, to: futureFormatVersion)

    #expect(throws: WaxError.self) {
        _ = try WaxHeaderPage.selectValidPage(pageA: future, pageB: current)
    }
    #expect(throws: WaxError.self) {
        _ = try WaxHeaderPage.selectValidPage(pageA: current, pageB: future)
    }
}

@Test
func headerSelectionStillFallsBackFromTornPage() throws {
    let current = try makeHeaderPage()
    var torn = rewriteFormatVersion(current, to: futureFormatVersion)
    torn[torn.startIndex + checksumRange.lowerBound] ^= 0xFF

    let selected = try #require(try WaxHeaderPage.selectValidPage(pageA: torn, pageB: current))
    #expect(selected.pageIndex == 1)
}

@Test
func openRefusesStoreWhoseOtherHeaderPageHasFutureFormatVersion() async throws {
    let url = try await makeStoreWithFutureFormatOtherPage()
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: WaxError.self) {
        let wax = try await Wax.open(at: url)
        try await wax.close()
    }
}

@Test
func committedEmbeddingProbeRefusesStoreWhoseOtherHeaderPageHasFutureFormatVersion() async throws {
    let url = try await makeStoreWithFutureFormatOtherPage()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: WaxError.self) {
        _ = try Wax.committedEmbeddingState(at: url)
    }
}
