import Foundation
import Testing
@testable import WaxCore

@Test func footerLookupByHeaderMatchesScan() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("warmup".utf8))
    try await wax.commit()
    try await wax.close()

    let file = try FDFile.openReadOnly(at: url)
    defer { try? file.close() }

    let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
    let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
    let selected = try #require(WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB))
    let header = selected.page

    let fastFooter = try FooterScanner.findFooter(at: header.footerOffset, in: url)
    let scannedFooter = try FooterScanner.findLastValidFooter(in: url)

    #expect(fastFooter != nil)
    #expect(scannedFooter != nil)
    #expect(fastFooter?.footerOffset == scannedFooter?.footerOffset)
    #expect(fastFooter?.footer.tocHash == scannedFooter?.footer.tocHash)
}
